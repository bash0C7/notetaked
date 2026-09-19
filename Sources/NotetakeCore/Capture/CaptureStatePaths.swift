// Sources/NotetakeCore/Capture/CaptureStatePaths.swift
import Foundation

public enum CaptureStatePaths {
    public static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notetake").appendingPathComponent("state")
    }

    public static var processHeartbeatURL: URL { stateDirectory().appendingPathComponent("process.heartbeat") }
    public static var captureHeartbeatURL: URL { stateDirectory().appendingPathComponent("capture.heartbeat") }
    public static var captureCommandURL: URL { stateDirectory().appendingPathComponent("capture-command.json") }
    public static var captureEventURL: URL { stateDirectory().appendingPathComponent("capture-event.json") }
    public static var currentSessionMarkerURL: URL { stateDirectory().appendingPathComponent("current-session.json") }
}
