# ``InnoNetworkUpload``

File-backed foreground and background uploads with progress, restoration, and
bounded typed responses.

## Overview

Use `InnoNetworkUpload` when a request body already exists as a file and the
application needs upload progress or process-independent continuation. The
manager deliberately does not accept in-memory `Data`: callers with a small
body should use the core typed request API, while large or background payloads
should be materialized as a file first.

### Start an upload

```swift
import InnoNetwork
import InnoNetworkUpload

let manager = try UploadManager()

var request = URLRequest(url: uploadURL)
request.httpMethod = "PUT"
request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

let operation = try await manager.upload(request, fromFile: payloadFileURL)
for await event in operation.events {
    switch event {
    case .progress(let progress):
        render(progress.fractionCompleted)
    case .completed(let receipt):
        let result = try receipt.decode(
            using: AnyResponseDecoder<UploadResult>.json(decoder: JSONDecoder())
        )
        consume(result)
    case .failed(let error):
        present(error)
    case .stateChanged:
        break
    }
}
```

The event stream is registered before the system task resumes, preventing a
fast response from racing ahead of observation. Response bodies are capped at
1 MiB by default, and the receipt intentionally omits the original
`URLRequest` so authorization headers are not retained.
Use ``UploadConfiguration/advanced(allowsCellularAccess:maximumResponseBytes:acceptableStatusCodes:eventDeliveryPolicy:eventMetricsReporter:)``
when a foreground endpoint needs a different response ceiling, accepted status
set, cellular policy, or event-delivery policy.

### Background continuation and restoration

```swift
let configuration = UploadConfiguration.background(
    sessionIdentifier: "com.example.product.upload"
)
let manager = try UploadManager(configuration: configuration)
let restored = await manager.restoreTasks()
```

Create only one live manager for a background session identifier. Call
``UploadManager/restoreTasks()`` before presenting transfer state after launch;
starting a new background upload performs this restoration automatically.
Foundation owns the transfer bytes, while `taskDescription` carries a private
versioned descriptor containing the opaque logical task identifier and active
or user-paused intent used for reattachment. Legacy identifier-only tasks
remain restorable as active work.
An admitted restored task that is still suspended is resumed after its request
passes the same URL and sensitive-header checks. Invalid restored tasks fail
closed and are never resumed.

Forward the application delegate's background-session completion exactly once:

```swift
uploadManager.handleBackgroundEvents(completion: completionHandler)
```

The source file must remain readable and unchanged until the background task
finishes. An App Group session also requires the file itself to live in a
container available to every participating process.

### Pause, resume, and retry

```swift
await manager.pause(operation.task)
await manager.resume(operation.task)
```

Pause and resume are idempotent no-ops for foreign, terminal, or mismatched
state. A background upload persists the distinction between user-paused intent
and Foundation's ordinary suspended state. Restoration therefore keeps a
user-paused task in ``UploadState/paused`` while still resuming an active task
that Foundation happened to suspend.

A retry is allowed only after failure. Supply the request and file again so
credentials, pre-signed URLs, and source availability are freshly validated:

```swift
var retryRequest = URLRequest(url: uploadURL)
retryRequest.httpMethod = "POST"
retryRequest.setValue(stableAttemptID, forHTTPHeaderField: "Idempotency-Key")

let retry = try await manager.retry(
    operation.task,
    with: retryRequest,
    fromFile: payloadFileURL
)
```

The destination and method must match the original attempt. The original
request must already contain the same non-empty application-owned
`Idempotency-Key`; adding or rotating a key after a possibly applied attempt
does not make replay safe. The manager reuses the logical ``UploadTask`` but
returns a new pre-registered ``UploadOperation/events`` stream for the retry.

### Server-negotiated resumable uploads

Use ``ResumableUploadEngine`` when the server exposes create, probe, chunk,
and finalize operations. Implement ``ResumableUploadAdapting`` for that exact
protocol and provide a ``ResumableUploadCheckpointStoring`` store.

The engine first copies and hashes the source into a private immutable snapshot,
then reads every chunk from that same snapshot. Replacing the caller's source
path after session creation cannot make the advertised identity differ from the
uploaded bytes. The engine probes the server on every start and advances its
checkpoint only to an offset returned by the adapter; it never infers acceptance
from bytes sent. ``FileResumableUploadCheckpointStore`` uses hashed filenames
and atomic JSON replacement. Persisted session identifiers must be non-secret;
credentials and pre-signed URLs belong in the adapter's fresh request path, not
in the checkpoint.

Cancellation or process interruption leaves the last server-confirmed offset
available for the next invocation. A changed file fails closed before the old
session is reused. Snapshot files are mode `0600` and removed on success,
failure, or cancellation. Adapter finalization must be idempotent for a session
and file identity: once the server reports success, checkpoint removal is
best-effort so local cleanup failure cannot misreport the remote outcome, and a
later invocation may repeat finalization before cleanup succeeds.

## Security contract

- Only absolute HTTPS URLs without URL credentials, fragments, or dot-path
  segments are admitted.
- Foreground redirects pass through InnoNetwork's default redirect policy and
  HTTPS admission check.
- Foundation may follow background redirects without a per-hop delegate
  decision. Background requests carrying `Authorization`, `Cookie`, or
  `Proxy-Authorization` are therefore rejected. Prefer short-lived,
  origin-bound pre-signed URLs.
- Automatic cookie and URL credential storage is disabled for upload sessions.
- Final response URLs are revalidated, although this cannot undo a redirect
  already followed by the system background daemon.
- Retry inputs are not retained after an attempt. Only the original
  idempotency key is kept privately for equality validation; callers must
  provide the refreshed request and readable source file explicitly.
- ``UploadManager/shutdown()`` cancels active work and waits for URLSession
  invalidation up to the package's bounded internal shutdown deadline. A
  missing callback is logged without leaving shutdown suspended forever.

## Topics

### Essentials

- ``UploadManager``
- ``UploadConfiguration``
- ``UploadOperation``
- ``UploadTask``
- ``UploadEvent``
- ``UploadProgress``
- ``UploadReceipt``
- ``UploadState``
- ``UploadError``
- ``ResumableUploadEngine``
- ``ResumableUploadAdapting``
- ``ResumableUploadCheckpoint``
- ``FileResumableUploadCheckpointStore``
