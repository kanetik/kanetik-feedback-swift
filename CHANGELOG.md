# Changelog

## 0.1.0 (2026-11-14)

First release.

- `FeedbackClient.submit(_:)` posts a `FeedbackSubmission` to `{baseURL}/api/v1/apps/{appID}/feedback` and returns a `FeedbackResult`: `.sent`, `.rejected` or `.failed`.
- `multipart/form-data` when there are attachments, written to a temporary file and uploaded from it, so file attachments stream from disk; `application/json` when there are none.
- Client-side copies of the service's limits, checked before anything is uploaded.
- One retry with the same id after a connection failure.
- iOS 16+ and macOS 13+, no dependencies.
