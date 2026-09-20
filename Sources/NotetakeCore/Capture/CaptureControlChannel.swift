import Foundation

public struct CaptureControlChannel<Message: Codable & Equatable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func send(_ message: Message) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = Envelope(sentAt: Date(), message: message)
        let data = try JSONEncoder().encode(envelope)
        let tempURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }

    public func poll(after: Date?) -> (message: Message, sentAt: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        if let after, envelope.sentAt <= after { return nil }
        return (envelope.message, envelope.sentAt)
    }

    private struct Envelope: Codable {
        let sentAt: Date
        let message: Message
    }
}
