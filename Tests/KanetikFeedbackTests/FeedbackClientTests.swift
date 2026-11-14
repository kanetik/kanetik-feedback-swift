import Foundation
import XCTest
@testable import KanetikFeedback

final class FeedbackClientTests: XCTestCase {
    private var directory: URL!
    private lazy var client = FeedbackClient(
        baseURL: URL(string: "https://feedback.test")!, appID: "testapp", apiKey: "test-app-key",
        appVersion: "1.2.3", session: StubProtocol.session()
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func submission(_ attachments: FeedbackAttachment...) -> FeedbackSubmission {
        FeedbackSubmission(email: "someone@example.com", message: "It broke", attachments: attachments)
    }

    private func file(_ name: String, _ content: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func sized(_ name: String, _ bytes: Int64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    private func parts(_ recorded: StubProtocol.Recorded) -> [Part] {
        Part.parse(recorded.body, contentType: recorded.request.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    private func json(_ recorded: StubProtocol.Recorded) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
    }

    private func assertSent(_ result: FeedbackResult, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) {
        guard case .sent(let sent) = result else { return XCTFail("expected sent, got \(result)", file: file, line: line) }
        XCTAssertEqual(sent, id, file: file, line: line)
    }

    private func assertRejected(_ result: FeedbackResult, _ code: String, detail: String?? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .rejected(let actual, let actualDetail) = result else {
            return XCTFail("expected rejected(\(code)), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(actual, code, file: file, line: line)
        if let detail { XCTAssertEqual(actualDetail, detail, file: file, line: line) }
    }

    // MARK: Request shape

    func testSendsEveryFieldAsMultipartWhenThereAreAttachments() async throws {
        StubProtocol.reset([.http(201, #"{"id":"x"}"#)])
        let supportID = UUID()
        let sub = FeedbackSubmission(
            email: "someone@example.com",
            message: "It broke",
            properties: ["FCM Token": "tok", "nested": ["a": 1]],
            tags: ["license_recovery", "Needs_Triage", "license_recovery"],
            supportID: supportID,
            attachments: [
                .file(try file("a.txt", "log line"), name: "log.txt", contentType: "text/plain"),
                .data(Data("png bytes".utf8), name: "shot.png", contentType: "image/png"),
            ]
        )

        assertSent(await client.submit(sub), sub.id)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.url?.absoluteString, "https://feedback.test/api/v1/apps/testapp/feedback")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "X-Api-Key"), "test-app-key")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "User-Agent"), "testapp/1.2.3 feedback-client-swift/0.1.0")
        XCTAssertTrue(request.request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))

        let parts = parts(request)
        XCTAssertEqual(parts.map(\.name), ["id", "email", "message", "properties", "tags", "supportId", "files", "files"])
        let values = Dictionary(parts.map { ($0.name, $0.text) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values["id"], sub.id.uuidString.lowercased())
        XCTAssertEqual(values["email"], "someone@example.com")
        XCTAssertEqual(values["message"], "It broke")
        XCTAssertEqual(values["tags"], "license_recovery,needs_triage")
        XCTAssertEqual(values["supportId"], supportID.uuidString.lowercased())
        let properties = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(values["properties"]!.utf8)) as? [String: Any])
        XCTAssertEqual(properties["FCM Token"] as? String, "tok")
        XCTAssertEqual((properties["nested"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(parts.filter { $0.name == "files" }, [
            Part(name: "files", filename: "log.txt", contentType: "text/plain", body: Data("log line".utf8)),
            Part(name: "files", filename: "shot.png", contentType: "image/png", body: Data("png bytes".utf8)),
        ])
    }

    func testSendsJSONWhenThereIsNothingToAttach() async throws {
        StubProtocol.reset([.http(201, nil)])
        let supportID = UUID()
        let sub = FeedbackSubmission(
            email: "someone@example.com", message: "It broke",
            properties: ["App Version": "1.2.3", "iOS Version": "18.1", "count": 2, "beta": true, "missing": nil],
            tags: ["a", "B"], supportID: supportID
        )

        assertSent(await client.submit(sub), sub.id)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.request.url?.path, "/api/v1/apps/testapp/feedback")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "X-Api-Key"), "test-app-key")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "User-Agent"), "testapp/1.2.3 feedback-client-swift/0.1.0")
        let body = try json(request)
        XCTAssertEqual(Set(body.keys), ["id", "email", "message", "properties", "tags", "supportId"])
        XCTAssertEqual(body["id"] as? String, sub.id.uuidString.lowercased())
        XCTAssertEqual(body["email"] as? String, "someone@example.com")
        XCTAssertEqual(body["message"] as? String, "It broke")
        XCTAssertEqual(body["tags"] as? String, "a,b")
        XCTAssertEqual(body["supportId"] as? String, supportID.uuidString.lowercased())
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(properties["iOS Version"] as? String, "18.1")
        XCTAssertEqual(properties["count"] as? Int, 2)
        XCTAssertEqual(properties["beta"] as? Bool, true)
        XCTAssertTrue(properties["missing"] is NSNull)
    }

    func testOmitsOptionalFieldsWhenEmpty() async throws {
        StubProtocol.reset([.http(201, nil), .http(201, nil)])
        _ = await client.submit(submission())
        _ = await client.submit(submission(.data(Data("x".utf8), name: "a.txt", contentType: "text/plain")))

        XCTAssertEqual(Set(try json(StubProtocol.requests[0]).keys), ["id", "email", "message"])
        XCTAssertEqual(parts(StubProtocol.requests[1]).map(\.name), ["id", "email", "message", "files"])
    }

    // MARK: Results

    func testDuplicateIsSent() async {
        StubProtocol.reset([.http(200, #"{"id":"x","duplicate":true}"#)])
        let sub = submission()
        assertSent(await client.submit(sub), sub.id)
    }

    func testClientErrorIsRejectedWithTheServerCode() async {
        StubProtocol.reset([.http(400, #"{"error":"invalid_email","detail":"email is not a valid address"}"#)])
        assertRejected(await client.submit(submission()), "invalid_email", detail: "email is not a valid address")
    }

    func testClientErrorWithoutACodeIsRejectedWithTheStatus() async {
        StubProtocol.reset([.http(401, nil)])
        assertRejected(await client.submit(submission()), "http_401", detail: .some(nil))
        StubProtocol.reset([.http(404, "not json")])
        assertRejected(await client.submit(submission()), "http_404", detail: .some(nil))
    }

    func testPayloadTooLargeIsRequestTooLarge() async {
        StubProtocol.reset([.http(413, nil)])
        assertRejected(await client.submit(submission()), "request_too_large")
    }

    func testServerErrorFailsWithoutRetrying() async {
        StubProtocol.reset([.http(503, nil), .http(201, nil)])
        guard case .failed(let error) = await client.submit(submission()) else { return XCTFail("expected failed") }
        XCTAssertEqual(error as? FeedbackHTTPError, FeedbackHTTPError(status: 503))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    // MARK: Retry

    func testRetriesOnceWithTheSameIdAfterAConnectionFailure() async throws {
        StubProtocol.reset([.fail(.networkConnectionLost), .http(201, nil)])
        let sub = submission(.file(try file("log.txt", "log line"), contentType: "text/plain"))

        assertSent(await client.submit(sub), sub.id)

        let requests = StubProtocol.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let parts = parts(request)
            XCTAssertEqual(parts.first { $0.name == "id" }?.text, sub.id.uuidString.lowercased())
            XCTAssertEqual(parts.first { $0.name == "files" }?.text, "log line")
        }
    }

    func testRetriesAJSONSubmissionWithTheSameId() async throws {
        StubProtocol.reset([.fail(.cannotConnectToHost), .http(201, nil)])
        let sub = submission()
        assertSent(await client.submit(sub), sub.id)
        XCTAssertEqual(try StubProtocol.requests.map { try json($0)["id"] as? String },
                       [sub.id.uuidString.lowercased(), sub.id.uuidString.lowercased()])
    }

    func testFailsAfterTheSecondConnectionFailure() async {
        StubProtocol.reset([.fail(.networkConnectionLost), .fail(.notConnectedToInternet), .http(201, nil)])
        guard case .failed(let error) = await client.submit(submission()) else { return XCTFail("expected failed") }
        XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    // MARK: Client-side limits

    func testLimitsAreCheckedBeforeAnyUpload() async throws {
        StubProtocol.reset([])
        let mib: Int64 = 1024 * 1024
        let text = { (name: String) in FeedbackAttachment.data(Data("x".utf8), name: name, contentType: "text/plain") }
        func base(_ change: (inout FeedbackSubmission) -> Void) -> FeedbackSubmission {
            var sub = submission()
            change(&sub)
            return sub
        }
        let cases: [(String, FeedbackSubmission)] = [
            ("missing_email", base { $0.email = "  " }),
            ("invalid_email", base { $0.email = "not an email" }),
            ("invalid_email", base { $0.email = "a@b" }),
            ("invalid_email", base { $0.email = String(repeating: "a", count: 243) + "@example.com" }),
            ("missing_message", base { $0.message = " \n " }),
            ("message_too_long", base { $0.message = String(repeating: "m", count: 10_001) }),
            ("invalid_properties", base { $0.properties = ["big": .string(String(repeating: "p", count: 32 * 1024))] }),
            ("invalid_tags", base { $0.tags = [String(repeating: "t", count: 1025)] }),
            ("too_many_files", base { $0.attachments = (1...6).map { text("\($0).txt") } }),
            ("unsupported_type", base { $0.attachments = [.data(Data(), name: "a.pdf", contentType: "application/pdf")] }),
            ("file_too_large", base { $0.attachments = [.file(try! self.sized("big.txt", 10 * mib + 1), contentType: "text/plain")] }),
            ("request_too_large", base {
                $0.attachments = try! (1...5).map { .file(try self.sized("\($0).zip", 10 * mib), contentType: "application/zip") }
                $0.message = "It broke, and five full logs say why"
            }),
        ]
        for (code, sub) in cases {
            assertRejected(await client.submit(sub), code)
        }
        XCTAssertEqual(StubProtocol.requests.count, 0, "nothing may be uploaded when a limit is broken")
    }

    func testLimitsAcceptTheBoundaryValues() async throws {
        StubProtocol.reset(Array(repeating: .http(201, nil), count: 2))
        let mib: Int64 = 1024 * 1024
        let atLimits = FeedbackSubmission(
            email: String(repeating: "a", count: 242) + "@example.com",
            message: "  " + String(repeating: "m", count: 10_000) + "\n",
            properties: ["p": .string(String(repeating: "p", count: 32 * 1024 - 8))],
            tags: [String(repeating: "t", count: 1024), String(repeating: "T", count: 1024) + ", "],
            attachments: [
                .file(try sized("big.txt", 10 * mib), contentType: "text/plain"),
                .data(Data("x".utf8), name: "a.png", contentType: "image/png"),
                .data(Data("x".utf8), name: "a.jpg", contentType: "image/jpeg"),
                .data(Data("x".utf8), name: "a.webp", contentType: "IMAGE/WEBP"),
                .data(Data("x".utf8), name: "a.gz", contentType: "application/gzip; charset=binary"),
            ]
        )
        assertSent(await client.submit(atLimits), atLimits.id)
        let zip = submission(.data(Data("x".utf8), name: "a.zip", contentType: "application/zip"))
        assertSent(await client.submit(zip), zip.id)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testAnUnreadableAttachmentFailsBeforeAnyUpload() async {
        StubProtocol.reset([.http(201, nil)])
        let missing = directory.appendingPathComponent("gone.txt")
        guard case .failed = await client.submit(submission(.file(missing, contentType: "text/plain"))) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(StubProtocol.requests.count, 0)
    }

    // MARK: Streaming

    func testALargeFileIsStreamedFromDisk() async throws {
        StubProtocol.reset([.http(201, nil)])
        let size = 10 * 1024 * 1024
        let url = directory.appendingPathComponent("big.log")
        var pattern = Data(count: size)
        pattern.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        }
        try pattern.write(to: url)
        let sub = submission(.file(url, contentType: "text/plain"))

        assertSent(await client.submit(sub), sub.id)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertTrue(request.streamed, "the multipart body must reach the session as a file stream, not as httpBody")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Length"), String(request.body.count))
        let filePart = try XCTUnwrap(parts(request).first { $0.name == "files" })
        XCTAssertEqual(filePart.filename, "big.log")
        XCTAssertEqual(filePart.body.count, size)
        XCTAssertTrue(filePart.body == pattern, "the file must arrive byte for byte")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("kanetik-feedback-") }
        XCTAssertEqual(leftovers, [], "the temporary multipart file is removed after the upload")
    }

    func testMultipartWriterCopiesFilesInChunks() throws {
        let size = Multipart.chunkSize * 3 + 17
        let url = directory.appendingPathComponent("log.txt")
        try Data(repeating: 0x61, count: size).write(to: url)
        let out = directory.appendingPathComponent("body")
        let multipart = Multipart()
        let fields = Fields(submission())
        let length = try multipart.write(fields, attachments: [.file(url, contentType: "text/plain")], to: out)
        let body = try Data(contentsOf: out)
        XCTAssertEqual(Int64(body.count), length)
        XCTAssertEqual(Part.parse(body, contentType: multipart.contentType).last?.body.count, size)
    }

    func testFilenamesAreEscaped() {
        XCTAssertEqual(Multipart.quoted("a\"b\r\nc.txt"), "a%22b%0D%0Ac.txt")
    }
}
