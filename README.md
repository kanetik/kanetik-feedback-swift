# KanetikFeedback

Swift client for Kanetik's in-app feedback service. It sends one piece of feedback (an email address, a message, some context and optional files) and tells you what happened. It has no UI and no dependencies.

It is the Swift counterpart of the Android client, `com.kanetik.feedback:feedback-client`, and behaves the same way.

## Install

Swift Package Manager, iOS 16+ or macOS 13+:

```swift
.package(url: "https://github.com/kanetik/kanetik-feedback-swift.git", from: "0.1.0")
```

and depend on the `KanetikFeedback` product.

## Use

```swift
import KanetikFeedback

let client = FeedbackClient(
    baseURL: URL(string: "https://feedback.example.com")!,
    appID: "myapp",
    apiKey: appKey,                     // the app's key; it identifies the app and is not a secret
    appVersion: "1.4.0"
)

let submission = FeedbackSubmission(
    email: "someone@example.com",
    message: "The widget stopped updating after the last update.",
    properties: [
        "App Version": "1.4.0",
        "iOS Version": "18.1",
        "Model": "iPhone16,1",
        "Feedback Source": "Settings",
    ],
    tags: ["needs_triage"],
    supportID: installID,
    attachments: [
        .file(logURL, name: "log.txt", contentType: "text/plain"),
        .data(screenshotPNG, name: "screenshot.png", contentType: "image/png"),
    ]
)

switch await client.submit(submission) {
case .sent(let id):
    // Stored, or already stored under this id.
case .rejected(let code, let detail):
    // The server or a client-side limit refused it. Retrying unchanged will not help.
case .failed(let error):
    // Network trouble or a server error. Keep the submission and retry it later; its id makes that safe.
}
```

`submit` never throws. Keep a `FeedbackSubmission` you mean to retry: its `id` is what lets the server recognise a resend.

## Public API

```swift
public final class FeedbackClient: Sendable {
    public static let libraryVersion: String
    public init(baseURL: URL, appID: String, apiKey: String, appVersion: String, session: URLSession = .shared)
    public var endpoint: URL { get }
    public func submit(_ submission: FeedbackSubmission) async -> FeedbackResult
}

public struct FeedbackSubmission: Sendable {
    public init(id: UUID = UUID(), email: String, message: String, properties: [String: JSONValue] = [:],
                tags: [String] = [], supportID: UUID? = nil, attachments: [FeedbackAttachment] = [])
}

public struct FeedbackAttachment: Sendable {
    public enum Source: Sendable { case file(URL), data(Data) }
    public init(name: String, contentType: String, source: Source)
    public static func file(_ url: URL, name: String? = nil, contentType: String) -> FeedbackAttachment
    public static func data(_ data: Data, name: String, contentType: String) -> FeedbackAttachment
}

public enum FeedbackResult: Sendable {
    case sent(id: UUID)
    case rejected(code: String, detail: String?)
    case failed(any Error)
}

public struct FeedbackHTTPError: Error, Sendable, Equatable { public let status: Int }

public enum JSONValue: Sendable, Hashable, Codable   // string, int, double, bool, array, object, null; literal-expressible
```

## The contract

The client posts to `{baseURL}/api/v1/apps/{appID}/feedback` with:

- `X-Api-Key: {apiKey}`
- `User-Agent: {appID}/{appVersion} feedback-client-swift/{libraryVersion}`
- `multipart/form-data` when there are attachments, with the parts `id`, `email`, `message`, `properties` (a JSON object as a string), `tags` (comma-separated), `supportId` and one `files` part per attachment. Empty optional parts are left out. The body is written to a temporary file and sent with an upload task from that file, so a 10 MiB log is copied in 64 KiB chunks and never held in memory.
- `application/json` when there is nothing to attach, with the same fields; `properties` is a JSON object.

Ids are sent as lower-case UUIDs. Tags are lower-cased, trimmed and de-duplicated before sending.

Responses map to results like this:

| Response | Result |
|---|---|
| 201 `{"id"}`, or 200 `{"id", "duplicate": true}` (any 2xx) | `.sent(id:)` with the submission's id |
| 413 | `.rejected(code: "request_too_large")` |
| other 4xx with `{"error", "detail"}` | `.rejected(code: error, detail: detail)` |
| other 4xx without an `error` (for example a 401 for a wrong key) | `.rejected(code: "http_<status>")` |
| 5xx | `.failed(FeedbackHTTPError)` |
| connection failure | one retry with the same body and id, then `.failed(URLError)` |

Before uploading anything, the client checks the service's limits and returns `.rejected` with the code the server would have used:

| Check | Code |
|---|---|
| email blank after trimming | `missing_email` |
| email over 254 characters, or not `^[^\s@]+@[^\s@]+\.[^\s@]+$` | `invalid_email` |
| message blank after trimming | `missing_message` |
| message over 10,000 characters after trimming | `message_too_long` |
| properties JSON over 32 KiB | `invalid_properties` |
| tags over 1,024 characters after normalizing | `invalid_tags` |
| more than 5 files | `too_many_files` |
| a file not `image/png`, `image/jpeg`, `image/webp`, `text/plain`, `application/zip` or `application/gzip` | `unsupported_type` |
| a file over 10 MiB | `file_too_large` |
| request over 50 MiB | `request_too_large` |

Lengths are counted in UTF-16 code units, as the server counts them. `invalid_id` and `invalid_support_id` cannot happen on the client, because both ids are `UUID`s. An attachment file that cannot be read gives `.failed` with the file system error, also before any upload.

## How it maps to the Android client

| Android (`com.kanetik.feedback`) | Swift (`KanetikFeedback`) |
|---|---|
| `FeedbackClient(baseUrl: HttpUrl, appId, apiKey, versionName, okHttp)` | `FeedbackClient(baseURL:appID:apiKey:appVersion:session:)` |
| `suspend fun submit(...)` | `func submit(_:) async` |
| `FeedbackSubmission.id: String` | `id: UUID` |
| `properties: Map<String, Any?>` | `properties: [String: JSONValue]` |
| `supportId: String?` | `supportID: UUID?` |
| `FeedbackAttachment.FromFile` / `FromUri` | `.file(_:name:contentType:)` / `.data(_:name:contentType:)` |
| `FeedbackResult.Sent` / `Rejected` / `Failed` | `.sent` / `.rejected` / `.failed` |
| `User-Agent: … feedback-client/{v}` | `User-Agent: … feedback-client-swift/{v}` |

Behaviour is the same: the same limits and codes, one retry on connection failure with the same id, file parts streamed, and `http_<status>` / `request_too_large` for 4xx without a code and for 413. Two differences: the Swift client sends `application/json` when there are no attachments (the Android client always sends multipart; the service accepts both), and it sends tags already normalized.

Like the Android client, it does not own the form UI, which properties to collect, which logs to attach, or the consent copy. Those stay in the app.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
