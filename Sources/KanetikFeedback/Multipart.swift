import Foundation

/// Writes a `multipart/form-data` body to a file, copying file attachments in chunks so a large log is never held in memory.
struct Multipart {
    static let chunkSize = 64 * 1024

    let boundary = "kanetik-feedback-\(UUID().uuidString)"

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Writes the body to `url` and returns its length in bytes.
    func write(_ fields: Fields, attachments: [FeedbackAttachment], to url: URL) throws -> Int64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        func text(_ name: String, _ value: String) throws {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        try text("id", fields.id)
        try text("email", fields.email)
        try text("message", fields.message)
        if let properties = fields.propertiesJSON { try text("properties", properties) }
        if let tags = fields.tags { try text("tags", tags) }
        if let supportID = fields.supportID { try text("supportId", supportID) }

        for attachment in attachments {
            let header = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"files\"; filename=\"\(Self.quoted(attachment.name))\"\r\n"
                + "Content-Type: \(attachment.contentType.lowercased())\r\n\r\n"
            try out.write(contentsOf: Data(header.utf8))
            switch attachment.source {
            case .data(let data):
                try out.write(contentsOf: data)
            case .file(let fileURL):
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
            }
            try out.write(contentsOf: Data("\r\n".utf8))
        }
        try out.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return Int64(try out.offset())
    }

    /// A filename safe inside a quoted `Content-Disposition` parameter, escaped the way browsers do it.
    static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
