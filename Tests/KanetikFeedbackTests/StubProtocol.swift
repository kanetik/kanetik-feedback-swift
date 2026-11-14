import Foundation

/// A URLProtocol that records each request (with its body) and answers from a queue of canned replies.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, String?)
        case fail(URLError.Code)
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
        /// True when the body reached the protocol as a stream rather than as in-memory `httpBody`.
        let streamed: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            recorded = []
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        let streamed = request.httpBody == nil && request.httpBodyStream != nil
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: body, streamed: streamed))
            return Self.replies.isEmpty ? .http(500, nil) : Self.replies.removeFirst()
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let text { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A minimal multipart/form-data parser for assertions.
struct Part: Equatable {
    let name: String
    let filename: String?
    let contentType: String?
    let body: Data

    var text: String { String(decoding: body, as: UTF8.self) }

    static func parse(_ body: Data, contentType: String) -> [Part] {
        guard let range = contentType.range(of: "boundary=") else { return [] }
        let delimiter = Data("--\(contentType[range.upperBound...])".utf8)
        var parts: [Part] = []
        var cursor = body.startIndex
        guard let first = body.range(of: delimiter, in: cursor..<body.endIndex) else { return [] }
        cursor = first.upperBound
        while body[cursor..<min(cursor + 2, body.endIndex)] == Data("\r\n".utf8) {
            let headersStart = cursor + 2
            guard let headersEnd = body.range(of: Data("\r\n\r\n".utf8), in: headersStart..<body.endIndex),
                  let next = body.range(of: Data("\r\n".utf8) + delimiter, in: headersEnd.upperBound..<body.endIndex)
            else { break }
            let headers = String(decoding: body[headersStart..<headersEnd.lowerBound], as: UTF8.self)
            func match(_ pattern: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let found = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
                      let group = Range(found.range(at: 1), in: headers) else { return nil }
                return String(headers[group])
            }
            parts.append(Part(
                name: match(#" name="([^"]*)""#) ?? "",
                filename: match(#"filename="([^"]*)""#),
                contentType: match(#"Content-Type: (.*)"#),
                body: Data(body[headersEnd.upperBound..<next.lowerBound])
            ))
            cursor = next.upperBound
        }
        return parts
    }
}
