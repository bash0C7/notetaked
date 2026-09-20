// Sources/NotetakeCore/Capture/Heartbeat.swift
import Foundation

public enum HeartbeatStatus: Equatable, Sendable {
    case alive
    case stale
}

public enum Heartbeat {
    public static func write(to url: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = ISO8601DateFormatter().string(from: now).data(using: .utf8) ?? Data()
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try payload.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    public static func status(lastBeat: Date?, now: Date, threshold: TimeInterval) -> HeartbeatStatus {
        guard let lastBeat else { return .stale }
        return now.timeIntervalSince(lastBeat) > threshold ? .stale : .alive
    }

    public static func currentStatus(of url: URL, now: Date = Date(), threshold: TimeInterval) -> HeartbeatStatus {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return .stale
        }
        return status(lastBeat: modified, now: now, threshold: threshold)
    }
}
