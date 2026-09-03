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
Foundation owns the transfer bytes, while `taskDescription` carries the opaque
logical task identifier used for reattachment.
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
