import AVFoundation
import Foundation
import InnoNetwork
import InnoNetworkNext
import InnoNetworkAuthAWS
import InnoNetworkDownload
import InnoNetworkHLS
import InnoNetworkHLSAVFoundation
import InnoNetworkHLSLive
import InnoNetworkOpenAPI
import InnoNetworkPersistentCache
import InnoNetworkWebSocket
#if compiler(>=6.4)
import InnoNetworkHLSAudio
#endif

private let smokeNextConfiguration = NetworkClientConfiguration.secure(
    baseURL: URL(string: "https://example.com")!
)
private let smokeNextFailureKind = NetworkFailureKind.transport
private let smokeNextRecoveryDisposition = NetworkRecoveryDisposition.retry

private let smokeHLSResolver = PlaylistResolver()
private let smokeHLSSelector = VariantSelector()
private let smokeHLSRenditionSelector = RenditionSelector()
private let smokeHLSSubtitleProvenance = HLSSubtitleProvenancePolicy(
    machineGenerated: .preferred,
    translation: .excluded
)
private let smokeHLSDownloader = HLSDownloader()
private let smokeHLSLiveClient = HLSLivePlaylistClient(
    configuration: .advanced(
        reload: HLSLiveReloadPack(
            prefersBlockingReloads: true,
            allowsDeltaUpdates: true
        )
    )
)
private let smokeHLSLiveHealthAnalyzer = HLSLiveHealthAnalyzer(
    configuration: .advanced(
        thresholds: HLSLiveHealthThresholdPack(
            degradedStagnantSnapshotCount: 3,
            criticalStagnantSnapshotCount: 6,
            degradedPlaylistAgeMultiplier: 3,
            criticalPlaylistAgeMultiplier: 6
        )
    )
)
private let smokeHLSLiveHTTPFreshnessType = HLSLiveHTTPFreshness.self
private let smokeHLSLiveFreshnessIssue =
    HLSLiveHealthIssue.stalePlaylistResponse
private let smokeHLSLiveDVRConfiguration =
    HLSLiveDVRConfiguration.advanced(
        parts: HLSLiveDVRPartPack(
            policy: .independent
        ),
        preloading: HLSLiveDVRPreloadPack(
            policy: .unencryptedMedia
        ),
        recovery: HLSLiveDVRRecoveryPack(policy: .resumable)
    )
private let smokeHLSLiveDVRRecorder = HLSLiveDVRRecorder(
    configuration: smokeHLSLiveDVRConfiguration
)
private let smokeHLSAssetSessionPack = HLSAssetDownloadSessionPack(
    identifier: "com.example.innonetwork.doc-smoke.hls"
)
private let smokeHLSAssetSessionType = HLSAssetDownloadSession.self
private let smokeHLSAssetLibraryType = HLSAssetDownloadLibrary.self
private let smokeHLSOfflineAssetInspector = HLSOfflineAssetInspector()
private let smokeHLSOfflineAssetReadinessState =
    HLSOfflineAssetReadinessState.ready
private let smokeHLSOfflineCustomCoverage =
    HLSOfflineCustomMediaSelectionCoverage.complete
private let smokeHLSFairPlaySessionType = HLSFairPlaySession.self
private let smokeHLSFairPlayPersistentKeyWorkflowType =
    HLSFairPlayPersistentKeyWorkflow.self
private let smokeHLSFairPlayPersistentKeyConfiguration =
    HLSFairPlayPersistentKeyConfiguration.advanced(
        limits: HLSFairPlayPersistentKeyLimitPack()
    )
private let smokeHLSPlaybackHealthAnalyzerType =
    HLSPlaybackHealthAnalyzer.self
private let smokeHLSPlaybackHealthConfiguration =
    HLSPlaybackHealthConfiguration.advanced(
        thresholds: HLSPlaybackHealthThresholdPack(
            observationWindow: 60
        )
    )
private let smokeHLSPlaybackStartupMetricType =
    HLSPlaybackStartupMetric.self
private let smokeHLSPlaybackBufferMetricType =
    HLSPlaybackBufferMetric.self
private let smokeHLSPlaybackMetricDeliveryType =
    HLSPlaybackMetricDelivery.self
private let smokeHLSPlaybackReadinessMetricType =
    HLSPlaybackReadinessMetric.self
private let smokeHLSPlaybackRateChangeMetricType =
    HLSPlaybackRateChangeMetric.self
private let smokeHLSPlaybackRateChangeReason =
    HLSPlaybackRateChangeReason.stalled
private let smokeHLSPlaybackVariantSwitchMetricType =
    HLSPlaybackVariantSwitchMetric.self
private let smokeHLSLegibleMediaCatalogType =
    HLSLegibleMediaCatalog.self
private let smokeHLSLegibleMediaSelection =
    HLSLegibleMediaSelection.automatic
private let smokeHLSConfiguration = HLSDownloadConfiguration.advanced(
    storage: HLSStoragePack(
        maximumTotalDownloadBytes: 4 * 1_024 * 1_024 * 1_024,
        diskCapacityPolicy: .required(
            minimumAvailableCapacity: 512 * 1_024 * 1_024
        )
    ),
    variantSelectionPolicy: .maximumResolution(width: 1_920, height: 1_080),
    contentSteering: HLSContentSteeringPack(
        healthPolicy: HLSContentSteeringHealthPolicy(
            consecutiveFailureThreshold: 2,
            recoveryCooldown: .seconds(15)
        ),
        eventObservers: [SmokeHLSContentSteeringObserver()]
    ),
    transfer: HLSTransferPack(
        maximumConcurrentResourceTransfers: 2,
        retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 2)
    )
)
private let smokeHLSRequestPolicy = HLSRequestPolicy(
    eventObservers: [SmokeHLSRequestObserver()]
) { request, context in
    _ = (
        context.requestID,
        context.purpose,
        context.resourceIndex,
        context.retryIndex
    )
    return request
}
private let smokeHLSConfiguredResolver = PlaylistResolver(
    session: .shared,
    requestContext: NetworkRequestContext(),
    requestPolicy: smokeHLSRequestPolicy
)
private let smokeHLSConfiguredDownloader = HLSDownloader(
    session: .shared,
    configuration: smokeHLSConfiguration,
    requestContext: NetworkRequestContext(),
    requestAdapter: { $0 }
)
private let smokeHLSOfflineConfiguration =
    HLSOfflinePackageConfiguration.advanced(
        storage: HLSOfflinePackageStoragePack(
            diskCapacityPolicy: .disabled
        ),
        renditions: HLSOfflineRenditionPack(
            audio: .preferredLanguages(["ko", "en"]),
            video: .defaultOrFirst,
            subtitles: .preferredLanguages(["ko", "en"]),
            subtitleProvenance: smokeHLSSubtitleProvenance,
            includesIFrameTrickPlay: true
        ),
        transfer: HLSTransferPack(
            maximumConcurrentResourceTransfers: 2
        )
    )
private let smokeHLSOfflineDownloader = HLSOfflinePackageDownloader(
    configuration: smokeHLSOfflineConfiguration
)
private let smokeHLSConfiguredOfflineDownloader =
    HLSOfflinePackageDownloader(
        session: .shared,
        configuration: smokeHLSOfflineConfiguration,
        requestPolicy: smokeHLSRequestPolicy
    )
private let smokeHLSExternalResourceResolver =
    HLSExternalResourceResolver(
        configuration: HLSExternalResourcePack(
            maximumSessionDataBytes: 256 * 1_024,
            maximumInterstitialAssetCount: 100
        )
    )
private let smokeHLSInterstitial = HLSInterstitial(
    source: .asset(URL(string: "https://example.com/ad.m3u8")!),
    contentVariability: .sameForAllPlayers,
    timelineOccupancy: .range,
    timelineStyle: .primary,
    navigationRestrictions: [.skip, .jump],
    skipControl: HLSInterstitialSkipControl(
        offset: 5,
        duration: 20,
        labelID: "Skip_Ad"
    )
)
private let smokeHLSInterstitialAssetResolutionType =
    HLSInterstitialAssetResolution.self
private let smokeHLSPlaybackAssetConfiguratorType =
    HLSPlaybackAssetConfigurator.self
private let smokeHLSCommonMediaClientDataPolicy =
    HLSCommonMediaClientDataPolicy.enabled
private let smokeHLSCommonMediaClientDataStatusType =
    HLSCommonMediaClientDataStatus.self

private func smokeHLSOfflineAssetSurface(
    storedAsset: HLSStoredAsset
) async throws {
    let snapshot = try await smokeHLSOfflineAssetInspector.inspect(
        storedAsset
    )
    _ = (
        HLSOfflineAssetReadinessSnapshot.self,
        HLSOfflineMediaSelectionGroupSnapshot.self,
        HLSOfflineMediaSelectionOptionSnapshot.self,
        snapshot.state,
        snapshot.isPlayableOffline,
        snapshot.didCompleteMediaSelectionInspection,
        snapshot.mediaSelectionGroups.map {
            (
                $0.kind,
                $0.options,
                $0.cachedCustomLanguageTags,
                $0.customMediaSelectionCoverage
            )
        },
        smokeHLSOfflineAssetReadinessState,
        smokeHLSOfflineCustomCoverage
    )
}

@available(
    macOS 15,
    iOS 18,
    tvOS 18,
    watchOS 11,
    visionOS 2,
    *
)
@MainActor
private func smokeHLSIntegratedTimelineSurface(
    playerItem: AVPlayerItem
) {
    let monitor = HLSIntegratedTimelineMonitor(
        playerItem: playerItem,
        updateInterval: 0.5,
        maximumBufferedUpdateCount: 64
    )
    _ = (
        HLSIntegratedTimelineSegmentKind.self,
        HLSIntegratedTimelineSegmentSnapshot.self,
        HLSIntegratedTimelineSnapshot.self,
        HLSIntegratedTimelineUpdate.self,
        HLSIntegratedTimelineUpdateReason.self,
        monitor.currentSnapshot,
        monitor.updates()
    )
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func smokeHLSPlaybackStartupMetricsSurface(
    playerItem: AVPlayerItem
) {
    let metrics = HLSPlaybackMetrics(playerItem: playerItem)
    let startupEvents = metrics.startupEvents(
        maximumRetainedRequestCount: 128
    )
    _ = startupEvents
    _ = smokeHLSPlaybackStartupMetricType
    _ = smokeHLSPlaybackBufferMetricType
    let readinessEvents = metrics.readinessEvents()
    _ = readinessEvents
    _ = smokeHLSPlaybackReadinessMetricType
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func smokeHLSPlaybackMetricDeliverySurface(
    playerItem: AVPlayerItem
) async throws {
    let deliveries = HLSPlaybackMetrics(
        playerItem: playerItem
    ).sequencedEvents()
    var analyzer = HLSPlaybackHealthAnalyzer()
    for try await delivery in deliveries {
        let health = analyzer.ingest(delivery)
        _ = health.droppedMetricEventCount
        break
    }
    _ = smokeHLSPlaybackMetricDeliveryType
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func smokeHLSPlaybackRateChangeMetricsSurface(
    playerItem: AVPlayerItem
) {
    let events = HLSPlaybackMetrics(playerItem: playerItem).rateChangeEvents()
    _ = events
    _ = smokeHLSPlaybackRateChangeMetricType
    _ = smokeHLSPlaybackRateChangeReason
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func smokeHLSPlaybackVariantSwitchMetricsSurface(
    playerItem: AVPlayerItem
) {
    let metrics = HLSPlaybackMetrics(playerItem: playerItem)
    let variantSwitchEvents = metrics.variantSwitchEvents()
    _ = variantSwitchEvents
    _ = smokeHLSPlaybackVariantSwitchMetricType
}

@MainActor
private func smokeHLSTimedMetadataSurface(
    playerItem: AVPlayerItem
) throws {
    let configuration = HLSTimedMetadataConfiguration.advanced(
        fields: [
            .text(.id3Title),
            .redacted(.id3Private),
        ]
    )
    let monitor = try HLSTimedMetadataMonitor(
        playerItem: playerItem,
        configuration: configuration
    )
    _ = (
        HLSTimedMetadataEvent.self,
        HLSTimedMetadataValue.self,
        monitor.events()
    )
    monitor.detach()
}

#if compiler(>=6.4)
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
@MainActor
private func smokeHLSDecodedAudioSurface(
    playerItem: AVPlayerItem
) throws {
    let configuration = try HLSDecodedAudioConfiguration.float32()
    let output = HLSDecodedAudioOutput(
        playerItem: playerItem,
        configuration: configuration
    )
    let pacedSamples = output.pacedSamples(
        configuration: HLSDecodedAudioPacingConfiguration(
            maximumLeadTime: 0.25
        )
    )
    _ = (
        HLSDecodedAudioSample.self,
        HLSDecodedAudioPacedSequence.self,
        pacedSamples,
        output.isAttached,
        try output.nextAvailableSample()
    )
    output.detach()
}
#endif

private struct SmokeHLSRequestObserver: HLSRequestEventObserving {
    func hlsRequestDidEmit(_ event: HLSRequestEvent) async {
        switch event {
        case .requestStarted(let context):
            _ = context.purpose
        case .responseReceived(let context, let statusCode):
            _ = (context.requestID, statusCode)
        case .requestFailed(let context, let failure):
            switch failure {
            case .adaptation, .urlAdmission, .transport, .cancellation:
                _ = context.retryIndex
            }
        }
    }
}

private struct SmokeHLSContentSteeringObserver:
    HLSContentSteeringEventObserving
{
    func contentSteeringDidEmit(
        _ event: HLSContentSteeringEvent
    ) async {
        if case .pathwayHealthChanged(let snapshot) = event {
            _ = (
                snapshot.pathwayID,
                snapshot.successRate,
                snapshot.availability,
                snapshot.selectionCounts
            )
        }
        if case .pathwaySelectionChanged(
            let fromPathwayID,
            let toPathwayID,
            let reason
        ) = event {
            _ = (fromPathwayID, toPathwayID, reason)
        }
    }
}

private struct SmokeUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct SmokePost: Decodable, Sendable {
    let id: Int
    let title: String
}

private struct SmokeAuthResponse: Decodable, Sendable {
    let token: String
}

private struct SmokeGetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SmokeUser

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeLoginRequest: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias APIResponse = SmokeAuthResponse

    let parameters: Parameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var contentType: ContentType { .formUrlEncoded }

    init(email: String, password: String) {
        self.parameters = Parameter(email: email, password: password)
    }
}

private struct SmokeUploadImage: MultipartAPIDefinition {
    typealias APIResponse = EmptyResponse

    let imageData: Data

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("My Image", name: "title")
        formData.append(
            imageData,
            name: "file",
            fileName: "image.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeOpenAPIListUsers: OpenAPIRestOperation {
    typealias Response = [SmokeUser]

    var method: HTTPMethod { .get }
    var path: String { "/openapi/users" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
}

private struct SmokeAlamofireStyleAdapter: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("smoke", forHTTPHeaderField: "X-Request-ID")
        return request
    }
}

private enum SmokeMoyaStyleTarget {
    case posts(userID: String, page: Int)

    func endpoint() -> SmokeUserPosts {
        switch self {
        case .posts(let userID, let page):
            SmokeUserPosts(userID: userID, page: page)
        }
    }
}

private struct SmokeUserPosts: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let page: Int
    }

    typealias APIResponse = [SmokePost]

    let userID: String
    let page: Int

    var method: HTTPMethod { .get }
    var path: String { "/users/\(userID)/posts" }
    var sessionAuthentication: SessionAuthentication { .anonymous }
    var parameters: Parameter? { Parameter(page: page) }
    var transport: TransportPolicy<[SmokePost]> { .query() }
}

private func compileBackgroundDownloadArticleExamples() async throws {
    let configuration = DownloadConfiguration.advanced(
        sessionIdentifier: "com.example.docsmoke.background.\(UUID().uuidString)",
        transfer: DownloadTransferPack(
            maxConnectionsPerHost: 4,
            allowsCellularAccess: true
        ),
        persistence: DownloadPersistencePack(
            compactionPolicy: .init(
                maxEvents: 1_000,
                maxLogBytes: 1_048_576,
                tombstoneRatio: 0.25
            )
        )
    )

    let manager = try DownloadManager(configuration: configuration)
    _ = await manager.waitForRestoration()

    let task = await manager.download(
        url: URL(string: "https://example.com/archive.zip")!,
        to: FileManager.default.temporaryDirectory.appendingPathComponent("archive.zip")
    )
    await manager.pause(task)
    await manager.resume(task)
    await manager.cancel(task)
}

private func compileWebSocketArticleExamples() async {
    let configuration = WebSocketConfiguration.advanced(
        liveness: WebSocketLivenessPack(
            heartbeatInterval: 20,
            pongTimeout: 5
        ),
        messaging: WebSocketMessagingPack(sendQueueLimit: 32)
    )
    let manager = WebSocketManager(configuration: configuration)
    let task = await manager.connect(
        url: URL(string: "wss://echo.example.com/socket")!
    )
    let events = await manager.events(for: task)
    _ = events
    await manager.disconnect(task, closeCode: .custom(4001))
}

@MainActor
private func compileHLSArticleExamples() async throws {
    let sourceURL = URL(string: "https://media.example/master.m3u8")!
    let inspection = smokeHLSResolver.inspect(
        """
        #EXTM3U
        #EXT-X-ENDLIST
        """,
        relativeTo: sourceURL
    )
    _ = inspection.isValid
    _ = inspection.canDownloadAsSingleFile
    _ = inspection.canCreateOfflinePackage
    _ = inspection.diagnostics.map {
        ($0.code, $0.severity, $0.scope, $0.lineNumber)
    }
    let presentation =
        try await smokeHLSConfiguredResolver
        .inspectPresentation(
            from: sourceURL,
            using: .advanced(
                limits: HLSPresentationInspectionLimitPack(
                    maximumPlaylistCount: 16,
                    maximumConcurrentRequests: 2
                )
            )
        )
    _ = presentation.isConformant
    _ = presentation.diagnostics.map {
        (
            $0.code,
            $0.severity,
            $0.playlistIndex,
            $0.relatedPlaylistIndex
        )
    }
    let secondEdition = try smokeHLSResolver.resolve(
        """
        #EXTM3U
        #EXT-X-VERSION:12
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="Generated",LANGUAGE="en",CHARACTERISTICS="public.machine-generated",URI="generated.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000,VIDEO-RANGE=PQ,HDCP-LEVEL=TYPE-1,ALLOWED-CPC="com.example.drm:HW",REQ-VIDEO-LAYOUT="CH-STEREO/PROJ-HEQU",SUBTITLES="subtitles"
        hdr.m3u8
        """,
        relativeTo: sourceURL
    )
    if let variant = secondEdition.variants.first {
        _ = variant.hdcpLevel == .type1
        _ = variant.allowedContentProtectionConfigurations
        _ = variant.requiredVideoLayouts
    }
    let generatedSubtitle = smokeHLSRenditionSelector.select(
        in: secondEdition,
        groupID: "subtitles",
        kind: .subtitles,
        policy: .defaultOrFirst,
        subtitleProvenance: smokeHLSSubtitleProvenance
    )
    _ = generatedSubtitle?.hasCharacteristic(.machineGenerated)
    _ = generatedSubtitle?.mediaCharacteristics
    _ = generatedSubtitle?.isMachineGenerated
    _ = generatedSubtitle?.isTranslated
    let mediaMetadata = try smokeHLSResolver.resolve(
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:20
        #EXT-X-DISCONTINUITY-SEQUENCE:3
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-BITRATE:900
        #EXTINF:4,
        segment.ts
        #EXT-X-ENDLIST
        """,
        relativeTo: sourceURL
    )
    _ = (
        mediaMetadata.targetDuration,
        mediaMetadata.mediaSequence,
        mediaMetadata.discontinuitySequence,
        mediaMetadata.mediaPlaylistType,
        mediaMetadata.segmentBitrates
    )
    let destinationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("video.ts")
    let downloader = HLSDownloader(configuration: smokeHLSConfiguration)
    let preparation = try await downloader.prepare(sourceURL: sourceURL)
    _ = preparation.resourceTransferCount

    for await event in downloader.download(
        sourceURL: sourceURL,
        destinationURL: destinationURL
    ) {
        switch event {
        case .progress(let progress):
            if let percent = progress.percentCompleted {
                _ = percent
            } else {
                _ = progress.totalBytesWritten
            }
        case .completed(let fileURL):
            _ = fileURL
        case .failed(let error):
            _ = error.code
        case .cancelled:
            break
        }
    }

    _ = try await downloader.downloadFile(
        sourceURL: sourceURL,
        destinationURL: destinationURL
    )
    let receipt = try await downloader.downloadReceipt(
        sourceURL: sourceURL,
        destinationURL:
            destinationURL
            .appendingPathExtension("receipt")
    )
    _ = receipt.resumedResourceTransferCount

    let packagePreparation =
        try await smokeHLSOfflineDownloader.prepare(
            sourceURL: sourceURL
        )
    _ = packagePreparation.tracks
    _ = packagePreparation.selectedIFrameVariant
    let packageDirectoryURL =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("video.hlspkg")
    for await event in smokeHLSOfflineDownloader.download(
        sourceURL: sourceURL,
        destinationDirectoryURL: packageDirectoryURL
    ) {
        switch event {
        case .progress(let progress):
            _ = progress.fractionCompleted
        case .completed(let receipt):
            _ = receipt.entryPlaylistURL
            _ = receipt.selectedIFrameVariant
            let localAsset = try await HLSLocalPlaybackAsset(
                source: receipt.playbackSource
            )
            _ = AVPlayerItem(asset: localAsset.urlAsset)
            localAsset.close()
        case .failed(let error):
            _ = error.code
        case .cancelled:
            break
        }
    }
}

private func runDocSmoke() {
    let client = DefaultNetworkClient(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
    let typedOneOff = EndpointBuilder<SmokeUser>.get("/user/1")
    _ = client
    _ = typedOneOff

    let networkAdvanced = NetworkConfiguration.advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        auth: AuthPack(
            additionalRequestInterceptors: [SmokeAlamofireStyleAdapter()]
        ),
        transport: TransportPack(timeout: 45, trustPolicy: .systemDefault)
    )
    _ = networkAdvanced

    let awsSigner = AWSSigV4Interceptor(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        service: "execute-api"
    )
    let awsConfiguration = NetworkConfiguration.advanced(
        baseURL: URL(string: "https://api.example.com/v1")!,
        auth: AuthPack(additionalSigners: [awsSigner])
    )
    _ = awsConfiguration

    let persistentCacheConfiguration = PersistentResponseCacheConfiguration(
        directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-docsmoke-cache", isDirectory: true)
    )
    _ = persistentCacheConfiguration

    let downloadDefaults = DownloadConfiguration.safeDefaults(
        sessionIdentifier: "com.example.docsmoke.downloads"
    )
    let downloadAdvanced = DownloadConfiguration.advanced(
        retry: DownloadRetryPack(
            maxTotalRetries: 5,
            waitsForNetworkChanges: true
        )
    )
    _ = downloadDefaults
    _ = downloadAdvanced

    let webSocketDefaults = WebSocketConfiguration.safeDefaults()
    let webSocketAdvanced = WebSocketConfiguration.advanced(
        liveness: WebSocketLivenessPack(heartbeatInterval: 15),
        reconnect: WebSocketReconnectPack(maxAttempts: 8)
    )
    _ = webSocketDefaults
    _ = webSocketAdvanced

    let request = SmokeGetUser()
    let login = SmokeLoginRequest(email: "user@example.com", password: "password123")
    let upload = SmokeUploadImage(imageData: Data([0x00, 0x01, 0x02]))
    let openAPIRequest = OpenAPIRequest(SmokeOpenAPIListUsers())
    let alamofireStyleAdapter = SmokeAlamofireStyleAdapter()
    let moyaStyleEndpoint = SmokeMoyaStyleTarget.posts(userID: "1", page: 2).endpoint()
    _ = request
    _ = login
    _ = upload
    _ = openAPIRequest
    _ = alamofireStyleAdapter
    _ = moyaStyleEndpoint
}

_ = compileBackgroundDownloadArticleExamples
_ = compileWebSocketArticleExamples
_ = compileHLSArticleExamples
runDocSmoke()
print("InnoNetworkDocSmoke OK")
