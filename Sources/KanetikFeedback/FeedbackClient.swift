import Foundation

/// Submits in-app feedback to a Kanetik feedback service.
///
/// The client has no UI and holds no state beyond its configuration; one instance per app is enough.
/// `submit` never throws: every outcome, including cancellation, is a `FeedbackResult`.
public final class FeedbackClient: Sendable {
    /// This library's version, sent in the `User-Agent`.
    public static let libraryVersion = "0.1.0"

    public let baseURL: URL
    public let appID: String
    public let appVersion: String
    private let apiKey: String
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: The service root, e.g. `https://feedback.example.com`. The client appends `api/v1/apps/{appID}/feedback`.
    ///   - appID: The app's id on the service.
    ///   - apiKey: The app's key, sent as `X-Api-Key`. App keys identify the app; they are not secrets.
    ///   - appVersion: The app's marketing version, sent in the `User-Agent`.
    ///   - session: The session used for the request. Defaults to `URLSession.shared`.
    public init(baseURL: URL, appID: String, apiKey: String, appVersion: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appID = appID
        self.apiKey = apiKey
        self.appVersion = appVersion
        self.session = session
    }

    /// The URL submissions are posted to.
    public var endpoint: URL {
        baseURL.appendingPathComponent("api/v1/apps").appendingPathComponent(appID).appendingPathComponent("feedback")
    }

    var userAgent: String { "\(appID)/\(appVersion) feedback-client-swift/\(Self.libraryVersion)" }

    public func submit(_ submission: FeedbackSubmission) async -> FeedbackResult {
        let fields = Fields(submission)
        let sizes: [Int64]
        do {
            sizes = try submission.attachments.map { try $0.byteCount() }
        } catch {
            return .failed(error)
        }
        if let rejection = Limits.violation(fields, attachments: submission.attachments, sizes: sizes) {
            return rejection
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if submission.attachments.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try fields.jsonBody()
            } catch {
                return .failed(error)
            }
            return await send { try await self.session.data(for: request) }.result(id: submission.id)
        }

        let multipart = Multipart()
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanetik-feedback-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let length: Int64
        do {
            length = try multipart.write(fields, attachments: submission.attachments, to: bodyURL)
        } catch {
            return .failed(error)
        }
        if length > Limits.maxRequestBytes {
            return .rejected(code: "request_too_large", detail: "request is over \(Limits.maxRequestBytes) bytes")
        }
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        return await send { try await self.session.upload(for: request, fromFile: bodyURL) }.result(id: submission.id)
    }

    /// One retry, with the same body and so the same id, after a connection failure.
    private func send(_ attempt: () async throws -> (Data, URLResponse)) async -> Outcome {
        do {
            return .response(try await attempt())
        } catch let error as URLError where error.code != .cancelled && !Task.isCancelled {
            do {
                return .response(try await attempt())
            } catch {
                return .error(error)
            }
        } catch {
            return .error(error)
        }
    }
}

private enum Outcome {
    case response((Data, URLResponse))
    case error(any Error)

    func result(id: UUID) -> FeedbackResult {
        switch self {
        case .error(let error):
            return .failed(error)
        case .response(let (data, response)):
            guard let http = response as? HTTPURLResponse else { return .failed(URLError(.badServerResponse)) }
            switch http.statusCode {
            case 200..<300:
                return .sent(id: id)
            case 413:
                return .rejected(code: "request_too_large", detail: nil)
            case 400..<500:
                let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
                let code = body?.error.flatMap { $0.isEmpty ? nil : $0 } ?? "http_\(http.statusCode)"
                return .rejected(code: code, detail: body?.detail.flatMap { $0.isEmpty ? nil : $0 })
            default:
                return .failed(FeedbackHTTPError(status: http.statusCode))
            }
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String?
    let detail: String?
}

/// The submission's text fields, as they go on the wire.
struct Fields {
    let id: String
    let email: String
    let message: String
    let properties: [String: JSONValue]
    let propertiesJSON: String?
    let tags: String?
    let supportID: String?

    init(_ submission: FeedbackSubmission) {
        id = submission.id.uuidString.lowercased()
        email = submission.email
        message = submission.message
        properties = submission.properties
        propertiesJSON = submission.properties.isEmpty ? nil : Self.encode(submission.properties)
        let tags = Self.normalize(submission.tags)
        self.tags = tags.isEmpty ? nil : tags
        supportID = submission.supportID?.uuidString.lowercased()
    }

    static func normalize(_ tags: [String]) -> String {
        var seen = Set<String>()
        return tags.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ",")
    }

    private static func encode(_ properties: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Only a non-finite double can make this encoding fail, and `finite` replaces those with null.
        let data = (try? encoder.encode(properties.mapValues(\.finite))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The `application/json` form of the request, used when there is nothing to attach.
    func jsonBody() throws -> Data {
        struct Body: Encodable {
            let id: String
            let email: String
            let message: String
            let properties: [String: JSONValue]?
            let tags: String?
            let supportId: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let properties = propertiesJSON == nil ? nil : self.properties.mapValues(\.finite)
        return try encoder.encode(Body(id: id, email: email, message: message, properties: properties, tags: tags, supportId: supportID))
    }
}

extension JSONValue {
    /// The same value with NaN and infinities replaced by null, which JSON cannot represent.
    var finite: JSONValue {
        switch self {
        case .double(let value) where !value.isFinite: return .null
        case .array(let values): return .array(values.map(\.finite))
        case .object(let values): return .object(values.mapValues(\.finite))
        default: return self
        }
    }
}

extension FeedbackAttachment {
    func byteCount() throws -> Int64 {
        switch source {
        case .data(let data):
            return Int64(data.count)
        case .file(let url):
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}
