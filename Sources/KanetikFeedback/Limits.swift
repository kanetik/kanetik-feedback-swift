import Foundation

/// Client-side copies of the service's limits (DESIGN §4.1, §4.4), checked before anything is uploaded.
/// Lengths are counted in UTF-16 code units, as the server (JavaScript) counts them.
enum Limits {
    static let maxFiles = 5
    static let maxFileBytes: Int64 = 10 * 1024 * 1024
    static let maxRequestBytes: Int64 = 50 * 1024 * 1024
    static let maxMessageChars = 10_000
    static let maxPropertiesBytes = 32 * 1024
    static let maxTagsChars = 1024
    static let maxEmailChars = 254
    static let acceptedTypes: [String] = [
        "image/png", "image/jpeg", "image/webp", "text/plain", "application/zip", "application/gzip",
    ]

    static func violation(_ fields: Fields, attachments: [FeedbackAttachment], sizes: [Int64]) -> FeedbackResult? {
        let email = fields.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty { return .rejected(code: "missing_email", detail: "email is required") }
        if email.utf16.count > maxEmailChars || !isEmail(email) {
            return .rejected(code: "invalid_email", detail: "email is not a valid address")
        }
        let message = fields.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { return .rejected(code: "missing_message", detail: "message is required") }
        if message.utf16.count > maxMessageChars {
            return .rejected(code: "message_too_long", detail: "message is over \(maxMessageChars) characters")
        }
        if let properties = fields.propertiesJSON, properties.utf8.count > maxPropertiesBytes {
            return .rejected(code: "invalid_properties", detail: "properties are over \(maxPropertiesBytes) bytes")
        }
        if let tags = fields.tags, tags.utf16.count > maxTagsChars {
            return .rejected(code: "invalid_tags", detail: "tags are over \(maxTagsChars) characters")
        }
        if attachments.count > maxFiles { return .rejected(code: "too_many_files", detail: "at most \(maxFiles) files") }

        var total = [fields.id, fields.email, fields.message, fields.propertiesJSON ?? "", fields.tags ?? "", fields.supportID ?? ""]
            .reduce(Int64(0)) { $0 + Int64($1.utf8.count) }
        for (attachment, size) in zip(attachments, sizes) {
            if !acceptedTypes.contains(mediaType(attachment.contentType)) {
                return .rejected(code: "unsupported_type", detail: "accepted types: \(acceptedTypes.joined(separator: ", "))")
            }
            if size > maxFileBytes {
                return .rejected(code: "file_too_large", detail: "each file must be at most \(maxFileBytes) bytes")
            }
            total += size
        }
        if total > maxRequestBytes {
            return .rejected(code: "request_too_large", detail: "request is over \(maxRequestBytes) bytes")
        }
        return nil
    }

    /// `type/subtype` without parameters, lower-cased.
    static func mediaType(_ contentType: String) -> String {
        (contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The server's `^[^\s@]+@[^\s@]+\.[^\s@]+$`.
    static func isEmail(_ value: String) -> Bool {
        value.wholeMatch(of: emailPattern) != nil
    }

    nonisolated(unsafe) private static let emailPattern = try! Regex(#"[^\s@]+@[^\s@]+\.[^\s@]+"#)
}
