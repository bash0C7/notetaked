// Sources/NotetakeCore/Capture/Heartbeat.swift
import Foundation

public enum HeartbeatStatus: Equatable, Sendable {
    case alive
    case stale
}

public enum Heartbeat {
    public static func write(to url: URL, now: Date = Date()) throws {
        try AtomicFile.write(Data(ISO8601DateFormatter().string(from: now).utf8), to: url)
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
