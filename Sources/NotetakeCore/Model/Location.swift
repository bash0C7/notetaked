import Foundation

/// 音を拾った入力機材。Macでは内蔵マイクかAirPodsか等が収録ごとに変わる
public struct InputDevice: Codable, Sendable, Equatable {
    public var name: String      // AVCaptureDevice.localizedName
    public var uid: String       // AVCaptureDevice.uniqueID
    public var spatial: Bool     // 開始時の isMultichannelAudioModeSupported(.firstOrderAmbisonics)

    public init(name: String, uid: String, spatial: Bool) {
        self.name = name
        self.uid = uid
        self.spatial = spatial
    }

    /// Macのシステム音声tap
    public static let system = InputDevice(name: "system", uid: "system", spatial: false)
}

/// 空間収録対応機材でのみ付く方位。機材の上端方向を0°、上から見て時計回り
public struct Direction: Codable, Sendable, Equatable {
    public var azimuthDeg: Double   // key: azimuth_deg、0 <= x < 360
    public var confidence: Double   // 0...1

    enum CodingKeys: String, CodingKey {
        case azimuthDeg = "azimuth_deg"
        case confidence
    }

    public init(azimuthDeg: Double, confidence: Double) {
        self.azimuthDeg = azimuthDeg
        self.confidence = confidence
    }
}
