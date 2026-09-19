import Foundation

public struct CaptureCheckpoint: Codable, Equatable, Sendable {
    public var offsets: [String: Int]

    public init(offsets: [String: Int] = [:]) {
        self.offsets = offsets
    }

    public static func load(from url: URL) -> CaptureCheckpoint {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CaptureCheckpoint.self, from: data) else {
            return CaptureCheckpoint()
        }
        return decoded
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
