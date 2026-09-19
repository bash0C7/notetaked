import Foundation

public enum CaptureCommand: Codable, Equatable, Sendable {
    case startSession(directory: String, sources: [String], inputDeviceUID: String?)
    case stopSession
    case quit
}

public enum CaptureEvent: Codable, Equatable, Sendable {
    case started(directory: String)
    case stopped
    case inputFallback
    case error(String)
}
