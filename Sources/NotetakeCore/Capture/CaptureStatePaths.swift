// Sources/NotetakeCore/Capture/CaptureStatePaths.swift
import Foundation

public enum CaptureStatePaths {
    public static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notetake").appendingPathComponent("state")
    }

    public static var processHeartbeatURL: URL { stateDirectory().appendingPathComponent("process.heartbeat") }
    public static var captureDesiredURL: URL { stateDirectory().appendingPathComponent("capture-desired.json") }
    public static var captureActualURL: URL { stateDirectory().appendingPathComponent("capture-actual.json") }
}
