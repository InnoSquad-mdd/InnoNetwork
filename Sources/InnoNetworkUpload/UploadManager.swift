import Foundation
import InnoNetwork
import OSLog
import os

/// Manages file-backed foreground and background upload tasks.
public actor UploadManager {
    private static let logger = Logger(
        subsystem: "com.innosquad.innonetwork",
        category: "upload-manager"
    )
    private static let activeBackgroundSessionIdentifiers =
        OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private let configuration: UploadConfiguration
    private let session: any UploadURLSession
    private let delegate: UploadSessionDelegate?
    private let channel: UploadDelegateEventChannel
    private let backgroundCompletionStore: UploadBackgroundCompletionStore
    private let eventHub: TaskEventHub<UploadEvent>
    private let invalidationBarrier = UploadInvalidationBarrier()
    private let invalidationTimeout: Duration
    private let startPreparationHook: (@Sendable (String) async -> Void)?
    private nonisolated let consumerTask =
        OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private var tasks: [String: UploadTask] = [:]
    private var pendingStartIDs: Set<String> = []
    private var uploadTasks: [String: any UploadURLTask] = [:]
    private var logicalIDsBySystemIdentifier: [Int: String] = [:]
    /// URLSession identifiers whose logical attempt has already terminated.
    /// Late delegate callbacks for these attempts must never be adopted as a
    /// restored background upload.
    private var retiredSystemIdentifiers: Set<Int> = []
    private var responseBodies: [Int: Data] = [:]
    private var forcedFailures: [Int: UploadError] = [:]
    private var idempotencyKeys: [String: String] = [:]
    private var pendingDelegateEvents: [Int: [UploadDelegateEvent]] = [:]
    private var restorationCompleted = false
    private var isRestoring = false
    private var restorationWaiters: [CheckedContinuation<[UploadTask], Never>] = []
    private var restoredTaskIDs: Set<String> = []
    private var retryingTaskIDs: Set<String> = []
    private var terminalTaskOrder: [String] = []
    private var isShutdown = false
    private let ownsBackgroundSessionIdentifier: Bool

    /// Creates a manager for the supplied upload domain.
    public init(configuration: UploadConfiguration = .safeDefaults()) throws(UploadError) {
        let ownsIdentifier = try Self.claimBackgroundSessionIdentifier(for: configuration)
        let channel = UploadDelegateEventChannel(limits: configuration.resourcePolicy)
        let delegate = UploadSessionDelegate(channel: channel)
        let sessionConfiguration = configuration.makeURLSessionConfiguration()
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )

        self.configuration = configuration
        self.session = session
        self.delegate = delegate
        self.channel = channel
        self.backgroundCompletionStore = UploadBackgroundCompletionStore()
        self.invalidationTimeout = .seconds(5)
        self.startPreparationHook = nil
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .genericTask
        )
        self.ownsBackgroundSessionIdentifier = ownsIdentifier

        let task = Task { [weak self] in
            while let event = await channel.next() {
                guard let self else { return }
                await self.process(event)
            }
        }
        consumerTask.withLock { $0 = task }
    }

    package init(
        configuration: UploadConfiguration,
        session: any UploadURLSession,
        channel: UploadDelegateEventChannel,
        backgroundCompletionStore: UploadBackgroundCompletionStore = UploadBackgroundCompletionStore(),
        invalidationTimeout: Duration = .seconds(5),
        startPreparationHook: (@Sendable (String) async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.delegate = nil
        self.channel = channel
        self.backgroundCompletionStore = backgroundCompletionStore
        self.invalidationTimeout = invalidationTimeout
        self.startPreparationHook = startPreparationHook
        self.eventHub = TaskEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .genericTask
        )
        self.ownsBackgroundSessionIdentifier = false

        let task = Task { [weak self] in
            while let event = await channel.next() {
                guard let self else { return }
                await self.process(event)
            }
        }
        consumerTask.withLock { $0 = task }
    }

    deinit {
        channel.finish()
        consumerTask.withLock { $0?.cancel() }
        if ownsBackgroundSessionIdentifier,
            let identifier = configuration.sessionIdentifier
        {
            Self.releaseBackgroundSessionIdentifier(identifier)
        }
        if !isShutdown {
            session.invalidateAndCancel()
        }
        _ = delegate
    }

    /// Starts a file-backed upload and returns a pre-registered event stream.
    ///
    /// The source file must remain available and unchanged until a background
    /// transfer reaches a terminal state.
    public func upload(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws(UploadError) -> UploadOperation {
        guard !isShutdown else { throw .managerShutdown }
        if configuration.sessionMode == .background, !restorationCompleted {
            _ = await restoreTasks()
        }
        guard !isShutdown else { throw .managerShutdown }
        try Self.validate(request: request, fileURL: fileURL, configuration: configuration)

        guard let url = request.url else {
            throw .invalidRequest("Upload request URL disappeared after validation")
        }
        let method = request.httpMethod ?? "POST"
        let task = UploadTask(requestURL: url, method: method)
        guard reserveTrackedSlot(for: task.id) else {
            throw .resourceLimitExceeded(limit: configuration.resourcePolicy.maximumTrackedTasks)
        }
        defer { pendingStartIDs.remove(task.id) }

        await startPreparationHook?(task.id)
        if Task.isCancelled { throw .cancelled }
        guard !isShutdown else { throw .managerShutdown }

        let stream = await eventHub.stream(for: task.id)
        if Task.isCancelled {
            await eventHub.publishTerminalAndFinish(.failed(.cancelled), for: task.id)
            throw .cancelled
        }
        guard !isShutdown else {
            await eventHub.publishTerminalAndFinish(.failed(.managerShutdown), for: task.id)
            throw .managerShutdown
        }
        let urlTask = session.makeUploadTask(with: request, fromFile: fileURL)
        urlTask.taskDescription = UploadTaskDescription.active(id: task.id)

        commitTrackedTask(task)
        if let idempotencyKey = Self.idempotencyKey(in: request) {
            idempotencyKeys[task.id] = idempotencyKey
        }
        uploadTasks[task.id] = urlTask
        logicalIDsBySystemIdentifier[urlTask.taskIdentifier] = task.id
        responseBodies[urlTask.taskIdentifier] = Data()

        guard await task.begin() else {
            urlTask.cancel()
            removeRuntime(for: task.id)
            tasks.removeValue(forKey: task.id)
            idempotencyKeys.removeValue(forKey: task.id)
            await eventHub.publishTerminalAndFinish(.failed(.managerShutdown), for: task.id)
            throw .managerShutdown
        }
        if Task.isCancelled {
            urlTask.cancel()
            await task.fail(with: .cancelled)
            removeRuntime(for: task.id)
            tasks.removeValue(forKey: task.id)
            idempotencyKeys.removeValue(forKey: task.id)
            await eventHub.publishTerminalAndFinish(.failed(.cancelled), for: task.id)
            throw .cancelled
        }
        await eventHub.publish(.stateChanged(.uploading), for: task.id)
        guard !isShutdown else { throw .managerShutdown }
        urlTask.resume()
        return UploadOperation(task: task, events: stream)
    }

    /// Reattaches logical tasks to uploads owned by the configured background
    /// URLSession. Repeated calls return the same restored task set.
    public func restoreTasks() async -> [UploadTask] {
        guard !isShutdown, configuration.sessionMode == .background else { return [] }
        if restorationCompleted {
            return restoredTasksSnapshot()
        }
        if isRestoring {
            return await withCheckedContinuation { continuation in
                restorationWaiters.append(continuation)
            }
        }
        isRestoring = true
        defer {
            isRestoring = false
            let waiters = restorationWaiters
            restorationWaiters.removeAll()
            let snapshot = isShutdown ? [] : restoredTasksSnapshot()
            for waiter in waiters { waiter.resume(returning: snapshot) }
        }

        let systemTasks = await session.allUploadTasks()
        guard !isShutdown else { return [] }
        for urlTask in systemTasks {
            guard !isShutdown else { return [] }
            guard let request = urlTask.currentRequest ?? urlTask.originalRequest,
                let url = request.url
            else {
                urlTask.cancel()
                continue
            }

            let descriptor = UploadTaskDescription.decode(urlTask.taskDescription)
            let id = uniqueTaskID(descriptor.id)
            let existingTask = tasks[id]
            if existingTask == nil, !reserveTrackedSlot(for: id) {
                urlTask.cancel()
                continue
            }
            urlTask.taskDescription =
                descriptor.intent == .paused
                ? UploadTaskDescription.paused(id: id)
                : UploadTaskDescription.active(id: id)
            let progress = UploadProgress(
                bytesSent: 0,
                totalBytesSent: urlTask.countOfBytesSent,
                totalBytesExpectedToSend: urlTask.countOfBytesExpectedToSend
            )
            let state: UploadState =
                descriptor.intent == .paused
                ? .paused
                : (urlTask.state == .suspended ? .waiting : .uploading)
            let task =
                existingTask
                ?? UploadTask(
                    id: id,
                    requestURL: url,
                    method: request.httpMethod ?? "POST",
                    state: state,
                    progress: progress
                )

            do {
                try Self.validateRestored(request: request, configuration: configuration)
            } catch {
                urlTask.cancel()
                await task.fail(with: error)
            }

            guard !isShutdown else {
                pendingStartIDs.remove(id)
                return []
            }
            if existingTask == nil {
                commitTrackedTask(task)
            }
            if let idempotencyKey = Self.idempotencyKey(in: request) {
                idempotencyKeys[id] = idempotencyKey
            }
            uploadTasks[id] = urlTask
            logicalIDsBySystemIdentifier[urlTask.taskIdentifier] = id
            responseBodies[urlTask.taskIdentifier] = responseBodies[urlTask.taskIdentifier] ?? Data()
            restoredTaskIDs.insert(id)

            if await task.state.isTerminal {
                await eventHub.publishTerminalAndFinish(.failed((await task.error) ?? .cancelled), for: id)
                pendingDelegateEvents.removeValue(forKey: urlTask.taskIdentifier)
                removeRuntime(for: id)
                continue
            }
            guard !isShutdown else { return [] }

            let pending = pendingDelegateEvents.removeValue(forKey: urlTask.taskIdentifier) ?? []
            for event in pending {
                await process(event)
            }

            guard !(await task.state.isTerminal) else { continue }
            guard !isShutdown else { return [] }
            if descriptor.intent == .paused {
                if urlTask.state == .running {
                    urlTask.suspend()
                }
            } else if urlTask.state == .suspended {
                await task.begin()
                await eventHub.publish(.stateChanged(.uploading), for: id)
                guard !isShutdown else { return [] }
                urlTask.resume()
            }
        }

        restorationCompleted = true
        return restoredTasksSnapshot()
    }

    /// Returns all tasks known to this manager, including terminal tasks.
    public func allTasks() -> [UploadTask] {
        tasks.values.sorted { $0.id < $1.id }
    }

    /// Returns the logical task with the supplied identifier.
    public func task(withId id: String) -> UploadTask? {
        tasks[id]
    }

    /// Creates an event stream for an existing or restored task and replays
    /// its current observable state.
    public func events(for task: UploadTask) async -> AsyncStream<UploadEvent> {
        guard tasks[task.id] === task else {
            return AsyncStream { $0.finish() }
        }
        let stream = await eventHub.stream(for: task.id)
        if let terminal = await task.terminalEvent() {
            await eventHub.publishTerminalAndFinish(terminal, for: task.id)
        } else {
            await eventHub.publish(.stateChanged(await task.state), for: task.id)
            let progress = await task.progress
            if progress != .zero {
                await eventHub.publish(.progress(progress), for: task.id)
            }
        }
        return stream
    }

    /// Pauses an upload owned by this manager.
    ///
    /// Background tasks persist this user intent in `taskDescription`, so a
    /// later manager restoration keeps the task paused instead of interpreting
    /// Foundation's suspended state as a request to resume automatically.
    public func pause(_ task: UploadTask) async {
        guard !isShutdown, tasks[task.id] === task, let urlTask = uploadTasks[task.id] else { return }
        let state = await task.state
        guard !isShutdown else { return }
        guard state == .waiting || state == .uploading else { return }
        guard UploadTaskDescription.decode(urlTask.taskDescription).intent != .paused else { return }

        urlTask.taskDescription = UploadTaskDescription.paused(id: task.id)
        urlTask.suspend()
        guard await task.pause() else { return }
        guard uploadTasks[task.id]?.taskIdentifier == urlTask.taskIdentifier else { return }
        await eventHub.publish(.stateChanged(.paused), for: task.id)
    }

    /// Resumes a user-paused upload owned by this manager.
    public func resume(_ task: UploadTask) async {
        guard !isShutdown, tasks[task.id] === task, let urlTask = uploadTasks[task.id] else { return }
        guard await task.state == .paused else { return }
        guard !isShutdown else { return }
        guard UploadTaskDescription.decode(urlTask.taskDescription).intent == .paused else { return }

        // Persist active intent before resuming. If the process exits between
        // these two calls, restoration will complete the requested resume.
        urlTask.taskDescription = UploadTaskDescription.active(id: task.id)
        guard await task.begin() else { return }
        guard uploadTasks[task.id]?.taskIdentifier == urlTask.taskIdentifier else { return }
        await eventHub.publish(.stateChanged(.uploading), for: task.id)
        guard !isShutdown else { return }
        urlTask.resume()
    }

    /// Restarts a failed logical upload with an explicitly refreshed request
    /// and source file.
    ///
    /// The destination and method must match the original task, and the request
    /// must carry a non-empty application-owned `Idempotency-Key`. InnoNetwork
    /// does not retain credentials, request headers, or source-file URLs after
    /// an attempt, so callers must provide every retry input again.
    public func retry(
        _ task: UploadTask,
        with request: URLRequest,
        fromFile fileURL: URL
    ) async throws(UploadError) -> UploadOperation {
        guard !isShutdown else { throw .managerShutdown }
        guard !Task.isCancelled else { throw .cancelled }
        guard tasks[task.id] === task else {
            throw .invalidRequest("The upload task is not owned by this manager")
        }
        guard await task.state == .failed else {
            throw .invalidRequest("Only failed uploads can be retried")
        }
        guard !isShutdown else { throw .managerShutdown }
        guard !retryingTaskIDs.contains(task.id) else {
            throw .invalidRequest("An upload retry is already being prepared")
        }
        retryingTaskIDs.insert(task.id)
        defer { retryingTaskIDs.remove(task.id) }

        try Self.validate(request: request, fileURL: fileURL, configuration: configuration)
        guard let url = request.url,
            url == task.requestURL,
            (request.httpMethod ?? "POST") == task.method
        else {
            throw .invalidRequest("Retry destination and HTTP method must match the original upload")
        }
        guard let idempotencyKey = Self.idempotencyKey(in: request) else {
            throw .invalidRequest("Retry requires a stable application-owned Idempotency-Key header")
        }
        guard let originalIdempotencyKey = idempotencyKeys[task.id] else {
            throw .invalidRequest("The original upload did not carry an Idempotency-Key")
        }
        guard idempotencyKey == originalIdempotencyKey else {
            throw .invalidRequest("Retry must reuse the original upload's Idempotency-Key")
        }

        guard !Task.isCancelled else { throw .cancelled }
        guard !isShutdown else { throw .managerShutdown }
        guard await task.prepareForRetry() else {
            throw .invalidRequest("Only one retry can restart a failed upload")
        }
        terminalTaskOrder.removeAll { $0 == task.id }
        let stream = await eventHub.stream(for: task.id)
        if Task.isCancelled {
            await terminateRetry(task, with: .cancelled)
            throw .cancelled
        }
        guard !isShutdown else {
            // Shutdown may have observed a previously failed task before the
            // cross-actor retry transition changed it back to waiting.
            await terminateRetry(task, with: .managerShutdown)
            throw .managerShutdown
        }
        let urlTask = session.makeUploadTask(with: request, fromFile: fileURL)
        urlTask.taskDescription = UploadTaskDescription.active(id: task.id)
        uploadTasks[task.id] = urlTask
        logicalIDsBySystemIdentifier[urlTask.taskIdentifier] = task.id
        responseBodies[urlTask.taskIdentifier] = Data()

        guard await task.begin() else {
            urlTask.cancel()
            removeRuntime(for: task.id)
            await terminateRetry(task, with: .managerShutdown)
            throw .managerShutdown
        }
        if Task.isCancelled {
            urlTask.cancel()
            removeRuntime(for: task.id)
            await terminateRetry(task, with: .cancelled)
            throw .cancelled
        }
        await eventHub.publish(.stateChanged(.uploading), for: task.id)
        if Task.isCancelled {
            urlTask.cancel()
            removeRuntime(for: task.id)
            await terminateRetry(task, with: .cancelled)
            throw .cancelled
        }
        guard !isShutdown else {
            urlTask.cancel()
            removeRuntime(for: task.id)
            await terminateRetry(task, with: .managerShutdown)
            throw .managerShutdown
        }
        urlTask.resume()
        return UploadOperation(task: task, events: stream)
    }

    /// Cancels an active upload. The terminal cancellation event is published
    /// before this method returns.
    public func cancel(_ task: UploadTask) async {
        guard tasks[task.id] === task, !(await task.state.isTerminal) else { return }
        uploadTasks[task.id]?.cancel()
        guard await task.fail(with: .cancelled) else { return }
        await eventHub.publishTerminalAndFinish(.failed(.cancelled), for: task.id)
        recordTerminal(task.id)
        removeRuntime(for: task.id)
    }

    /// Installs the one-shot completion supplied by the application delegate
    /// for this background session.
    public nonisolated func handleBackgroundEvents(
        completion: @escaping @Sendable () -> Void
    ) {
        backgroundCompletionStore.set(completion)?()
    }

    /// Cancels active uploads and tears down the owned URLSession.
    public func shutdown() async {
        guard !isShutdown else {
            _ = await invalidationBarrier.wait(timeout: invalidationTimeout)
            return
        }
        isShutdown = true
        let waiters = restorationWaiters
        restorationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: []) }
        pendingDelegateEvents.removeAll()
        let active = Array(uploadTasks.values)
        for urlTask in active { urlTask.cancel() }
        for task in Array(tasks.values) where !(await task.state.isTerminal) {
            if await task.fail(with: .managerShutdown) {
                await eventHub.publishTerminalAndFinish(.failed(.managerShutdown), for: task.id)
                recordTerminal(task.id)
            }
        }
        uploadTasks.removeAll()
        logicalIDsBySystemIdentifier.removeAll()
        retiredSystemIdentifiers.removeAll()
        responseBodies.removeAll()
        forcedFailures.removeAll()
        idempotencyKeys.removeAll()
        pendingStartIDs.removeAll()
        retryingTaskIDs.removeAll()
        terminalTaskOrder.removeAll()
        session.invalidateAndCancel()
        let invalidated = await invalidationBarrier.wait(timeout: invalidationTimeout)
        if !invalidated {
            Self.logger.fault("upload URLSession invalidation exceeded the shutdown deadline")
        }
        channel.finish()
        let consumer = consumerTask.withLock { value -> Task<Void, Never>? in
            let result = value
            value = nil
            return result
        }
        await consumer?.value
        await eventHub.shutdown()
        releaseClaimedIdentifierIfNeeded()
    }

    private func process(_ event: UploadDelegateEvent) async {
        if isShutdown {
            // Only session-lifecycle acknowledgements are meaningful after
            // shutdown. Buffered transfer callbacks must not adopt new tasks
            // or rebuild pending response buffers while teardown is awaiting.
            switch event {
            case .invalidated:
                await invalidationBarrier.complete()
            case .backgroundEventsFinished:
                backgroundCompletionStore.markEventsFinished()?()
            default:
                break
            }
            return
        }
        switch event {
        case .invalidated:
            await invalidationBarrier.complete()
        case .backgroundEventsFinished:
            backgroundCompletionStore.markEventsFinished()?()
        case .overflow(let identifier, let byteLimit):
            guard !retiredSystemIdentifiers.contains(identifier) else { return }
            guard let task = task(forSystemIdentifier: identifier) else {
                bufferPending(event, for: identifier)
                return
            }
            uploadTasks[task.id]?.cancel()
            await fail(task, with: .delegateBufferExceeded(limit: byteLimit))
        case .progress(let identifier, let bytesSent, let totalBytesSent, let expected):
            guard !retiredSystemIdentifiers.contains(identifier) else { return }
            guard let task = task(forSystemIdentifier: identifier) else {
                bufferPending(event, for: identifier)
                return
            }
            guard !(await task.state.isTerminal) else { return }
            let progress = UploadProgress(
                bytesSent: bytesSent,
                totalBytesSent: totalBytesSent,
                totalBytesExpectedToSend: expected
            )
            await task.update(progress: progress)
            await eventHub.publish(.progress(progress), for: task.id)
        case .data(let identifier, let data):
            guard !retiredSystemIdentifiers.contains(identifier) else { return }
            guard logicalIDsBySystemIdentifier[identifier] != nil else {
                bufferPending(event, for: identifier)
                return
            }
            if let task = task(forSystemIdentifier: identifier), await task.state.isTerminal {
                return
            }
            var body = responseBodies[identifier] ?? Data()
            guard data.count <= configuration.maximumResponseBytes - body.count else {
                forcedFailures[identifier] = .responseTooLarge(limit: configuration.maximumResponseBytes)
                task(forSystemIdentifier: identifier).flatMap { uploadTasks[$0.id] }?.cancel()
                return
            }
            body.append(data)
            responseBodies[identifier] = body
        case .completed(
            let identifier,
            let taskDescription,
            let originalRequest,
            let currentRequest,
            let response,
            let underlying
        ):
            guard !retiredSystemIdentifiers.contains(identifier) else { return }
            if task(forSystemIdentifier: identifier) == nil {
                guard configuration.sessionMode == .background,
                    let request = currentRequest ?? originalRequest,
                    let url = request.url
                else {
                    bufferPending(event, for: identifier)
                    return
                }
                let id = uniqueTaskID(UploadTaskDescription.decode(taskDescription).id)
                guard reserveTrackedSlot(for: id) else { return }
                let adopted = UploadTask(
                    id: id,
                    requestURL: url,
                    method: request.httpMethod ?? "POST",
                    state: .uploading
                )
                commitTrackedTask(adopted)
                if let idempotencyKey = Self.idempotencyKey(in: request) {
                    idempotencyKeys[id] = idempotencyKey
                }
                logicalIDsBySystemIdentifier[identifier] = id
                responseBodies[identifier] = responseBodies[identifier] ?? Data()
                restoredTaskIDs.insert(id)
                do {
                    try Self.validateRestored(request: request, configuration: configuration)
                } catch {
                    pendingDelegateEvents.removeValue(forKey: identifier)
                    await fail(adopted, with: error)
                    return
                }
                let pending = pendingDelegateEvents.removeValue(forKey: identifier) ?? []
                for pendingEvent in pending {
                    await process(pendingEvent)
                }
            }
            guard let task = task(forSystemIdentifier: identifier) else { return }
            guard !(await task.state.isTerminal) else {
                removeRuntime(for: task.id)
                return
            }

            let body = responseBodies[identifier] ?? Data()
            let failure = forcedFailures.removeValue(forKey: identifier)
            if let failure {
                await fail(task, with: failure)
                return
            }
            if let underlying {
                let error: UploadError =
                    (underlying.domain == NSURLErrorDomain
                        && underlying.code == NSURLErrorCancelled) ? .cancelled : .network(underlying)
                await fail(task, with: error)
                return
            }
            guard let response else {
                await fail(task, with: .invalidResponse)
                return
            }
            guard let finalURL = currentRequest?.url ?? response.url else {
                await fail(task, with: .invalidResponse)
                return
            }
            do {
                try NetworkURLAdmission.validate(
                    finalURL,
                    policy: .http(allowsInsecure: false)
                )
            } catch {
                await fail(task, with: .invalidRequest("Final response URL failed HTTPS admission"))
                return
            }

            let coreResponse = Response(
                statusCode: response.statusCode,
                data: body,
                request: nil,
                response: response
            )
            let receipt = UploadReceipt(response: coreResponse)
            guard configuration.acceptableStatusCodes.contains(response.statusCode) else {
                guard
                    await task.fail(
                        with: .unacceptableStatusCode(response.statusCode),
                        receipt: receipt
                    )
                else { return }
                await eventHub.publishTerminalAndFinish(
                    .failed(.unacceptableStatusCode(response.statusCode)),
                    for: task.id
                )
                recordTerminal(task.id)
                removeRuntime(for: task.id)
                return
            }

            guard await task.complete(with: receipt) else { return }
            await eventHub.publishTerminalAndFinish(.completed(receipt), for: task.id)
            recordTerminal(task.id)
            removeRuntime(for: task.id)
        }
    }

    private func fail(_ task: UploadTask, with error: UploadError) async {
        guard await task.fail(with: error) else { return }
        await eventHub.publishTerminalAndFinish(.failed(error), for: task.id)
        recordTerminal(task.id)
        removeRuntime(for: task.id)
    }

    private func terminateRetry(_ task: UploadTask, with error: UploadError) async {
        guard await task.fail(with: error) else { return }
        await eventHub.publishTerminalAndFinish(.failed(error), for: task.id)
        recordTerminal(task.id)
    }

    private func task(forSystemIdentifier identifier: Int) -> UploadTask? {
        logicalIDsBySystemIdentifier[identifier].flatMap { tasks[$0] }
    }

    private func bufferPending(_ event: UploadDelegateEvent, for identifier: Int) {
        if pendingDelegateEvents[identifier] == nil,
            pendingDelegateEvents.count >= configuration.resourcePolicy.maximumPendingUnknownTasks
        {
            return
        }
        let maximumPerTask = configuration.resourcePolicy.maximumBufferedDelegateEvents
        guard pendingDelegateEvents[identifier, default: []].count < maximumPerTask else { return }
        pendingDelegateEvents[identifier, default: []].append(event)
    }

    private func recordTerminal(_ logicalID: String) {
        terminalTaskOrder.removeAll { $0 == logicalID }
        terminalTaskOrder.append(logicalID)
        guard let maximum = configuration.resourcePolicy.maximumRetainedTerminalTasks else { return }
        while terminalTaskOrder.count > maximum {
            let evicted = terminalTaskOrder.removeFirst()
            tasks.removeValue(forKey: evicted)
            idempotencyKeys.removeValue(forKey: evicted)
            restoredTaskIDs.remove(evicted)
        }
    }

    private func removeRuntime(for logicalID: String) {
        let urlTask = uploadTasks.removeValue(forKey: logicalID)
        let identifier =
            urlTask?.taskIdentifier
            ?? logicalIDsBySystemIdentifier.first(where: { $0.value == logicalID })?.key
        guard let identifier else { return }
        logicalIDsBySystemIdentifier.removeValue(forKey: identifier)
        retiredSystemIdentifiers.insert(identifier)
        responseBodies.removeValue(forKey: identifier)
        forcedFailures.removeValue(forKey: identifier)
    }

    private func normalizedTaskID(_ value: String?) -> String {
        guard let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= 256
        else {
            return UUID().uuidString
        }
        return value
    }

    private func uniqueTaskID(_ value: String?) -> String {
        let candidate = normalizedTaskID(value)
        return tasks[candidate] == nil && !pendingStartIDs.contains(candidate)
            ? candidate
            : UUID().uuidString
    }

    private var trackedResourceCount: Int {
        tasks.count + pendingStartIDs.count
    }

    private func reserveTrackedSlot(for taskID: String) -> Bool {
        guard tasks[taskID] == nil,
            !pendingStartIDs.contains(taskID),
            trackedResourceCount < configuration.resourcePolicy.maximumTrackedTasks
        else {
            return false
        }

        pendingStartIDs.insert(taskID)
        return true
    }

    private func commitTrackedTask(_ task: UploadTask) {
        pendingStartIDs.remove(task.id)
        tasks[task.id] = task
    }

    private func restoredTasksSnapshot() -> [UploadTask] {
        restoredTaskIDs.compactMap { tasks[$0] }.sorted { $0.id < $1.id }
    }

    private static func validate(
        request: URLRequest,
        fileURL: URL,
        configuration: UploadConfiguration
    ) throws(UploadError) {
        do {
            try NetworkURLAdmission.validate(request, policy: .http(allowsInsecure: false))
        } catch {
            throw .invalidRequest(
                "Only absolute HTTPS URLs without credentials, fragments, or dot segments are allowed")
        }
        guard request.httpBody == nil, request.httpBodyStream == nil else {
            throw .invalidRequest("The request body is supplied by fromFile and must not also be set on URLRequest")
        }
        let method = (request.httpMethod ?? "POST").uppercased()
        guard method != "GET", method != "HEAD" else {
            throw .invalidRequest("GET and HEAD cannot be used for file uploads")
        }
        guard isReadableRegularFile(fileURL) else { throw .unreadableFile }
        try validateRestored(request: request, configuration: configuration)
    }

    private static func validateRestored(
        request: URLRequest,
        configuration: UploadConfiguration
    ) throws(UploadError) {
        do {
            try NetworkURLAdmission.validate(request, policy: .http(allowsInsecure: false))
        } catch {
            throw .invalidRequest(
                "Only absolute HTTPS URLs without credentials, fragments, or dot segments are allowed")
        }
        guard configuration.sessionMode == .background else { return }
        let sensitive = Set(["authorization", "cookie", "proxy-authorization"])
        let present = (request.allHTTPHeaderFields ?? [:]).keys
            .filter { sensitive.contains($0.lowercased()) }
            .sorted()
        guard present.isEmpty else { throw .sensitiveHeadersRequireForeground(present) }
    }

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return false }
        do {
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        } catch {
            return false
        }
    }

    private static func idempotencyKey(in request: URLRequest) -> String? {
        guard
            let value = request.value(forHTTPHeaderField: "Idempotency-Key")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func claimBackgroundSessionIdentifier(
        for configuration: UploadConfiguration
    ) throws(UploadError) -> Bool {
        guard configuration.sessionMode == .background,
            let identifier = configuration.sessionIdentifier,
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            if configuration.sessionMode == .background {
                throw .invalidRequest("Background sessionIdentifier must not be empty")
            }
            return false
        }
        let inserted = activeBackgroundSessionIdentifiers.withLock { $0.insert(identifier).inserted }
        guard inserted else { throw .duplicateSessionIdentifier(identifier) }
        return true
    }

    private static func releaseBackgroundSessionIdentifier(_ identifier: String) {
        _ = activeBackgroundSessionIdentifiers.withLock { $0.remove(identifier) }
    }

    private func releaseClaimedIdentifierIfNeeded() {
        guard ownsBackgroundSessionIdentifier,
            let identifier = configuration.sessionIdentifier
        else { return }
        Self.releaseBackgroundSessionIdentifier(identifier)
    }
}

package actor UploadInvalidationBarrier {
    private var result: Bool?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// Waits for URLSession invalidation until the bounded shutdown deadline.
    ///
    /// The first timeout opens the barrier for every concurrent and future
    /// waiter so repeated shutdown calls cannot start another unbounded wait.
    package func wait(timeout: Duration) async -> Bool {
        if let result { return result }
        guard timeout > .zero else {
            resolve(with: false)
            return false
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
                return
            }
            waiters[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.timeout()
            }
        }
    }

    package func complete() {
        resolve(with: true)
    }

    private func timeout() {
        resolve(with: false)
    }

    private func resolve(with result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        let tasks = timeoutTasks.values
        timeoutTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}
