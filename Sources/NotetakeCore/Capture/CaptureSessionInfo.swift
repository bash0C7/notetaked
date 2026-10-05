import Foundation

/// 生音声ディレクトリの`session.json`。serveが収録の開始時に書き、確定処理が出力先とMacの情報を知るために読む
public struct CaptureSessionInfo: Codable, Equatable, Sendable {
    public var outputDirectory: String
    public var device: String
    public var deviceName: String
    public var owner: String

    enum CodingKeys: String, CodingKey {
        case outputDirectory = "output_directory"
        case device
        case deviceName = "device_name"
        case owner
    }

    public init(outputDirectory: String, device: String, deviceName: String, owner: String) {
        self.outputDirectory = outputDirectory
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
    }
}
