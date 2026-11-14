import Foundation

/// One piece of feedback. `id` is generated once and reused on retry, which makes a resend idempotent on the server.
public struct FeedbackSubmission: Sendable {
    public var id: UUID
    public var email: String
    public var message: String
    /// Free-form context (app version, OS version, device model, ...). Sent as a JSON object.
    public var properties: [String: JSONValue]
    /// Sent comma-separated, lower-cased and de-duplicated.
    public var tags: [String]
    /// The app's stable per-install id.
    public var supportID: UUID?
    public var attachments: [FeedbackAttachment]

    public init(
        id: UUID = UUID(),
        email: String,
        message: String,
        properties: [String: JSONValue] = [:],
        tags: [String] = [],
        supportID: UUID? = nil,
        attachments: [FeedbackAttachment] = []
    ) {
        self.id = id
        self.email = email
        self.message = message
        self.properties = properties
        self.tags = tags
        self.supportID = supportID
        self.attachments = attachments
    }
}

/// A file sent with a submission. File-backed attachments are streamed from disk, never read whole into memory.
public struct FeedbackAttachment: Sendable {
    public enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    public var name: String
    /// One of `image/png`, `image/jpeg`, `image/webp`, `text/plain`, `application/zip`, `application/gzip`.
    public var contentType: String
    public var source: Source

    public init(name: String, contentType: String, source: Source) {
        self.name = name
        self.contentType = contentType
        self.source = source
    }

    /// An attachment read from a local file. `name` defaults to the file's last path component.
    public static func file(_ url: URL, name: String? = nil, contentType: String) -> FeedbackAttachment {
        FeedbackAttachment(name: name ?? url.lastPathComponent, contentType: contentType, source: .file(url))
    }

    /// An attachment held in memory.
    public static func data(_ data: Data, name: String, contentType: String) -> FeedbackAttachment {
        FeedbackAttachment(name: name, contentType: contentType, source: .data(data))
    }
}

public enum FeedbackResult: Sendable {
    /// Stored (201), or already stored under the same id (200 with `duplicate: true`).
    case sent(id: UUID)
    /// The server or a client-side limit refused it. `code` is the server's error code
    /// (`invalid_email`, `file_too_large`, ...), `http_<status>` for a 4xx without one,
    /// or `request_too_large` for 413 and the client's own total-size check. Retrying unchanged will not help.
    case rejected(code: String, detail: String?)
    /// Network failure (after one retry), a 5xx, or an unreadable attachment. Safe to retry later with the same submission.
    case failed(any Error)
}

/// The server answered with a status the client treats as a failure (5xx, or anything else non-2xx/4xx).
public struct FeedbackHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int
    public init(status: Int) { self.status = status }
    public var description: String { "HTTP \(status)" }
}

/// A JSON value, so `properties` can be flat or nested.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
