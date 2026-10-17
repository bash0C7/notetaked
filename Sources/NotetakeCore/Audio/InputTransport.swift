/// 入力機器の接続種別。CoreAudioのkAudioDevicePropertyTransportTypeの4文字コードを、選び方に要る3つへ畳む
public enum InputTransport: Sendable, Equatable {
    /// 内蔵マイク
    case builtIn
    /// iPhoneなどのContinuity Capture（有線 / 無線）。自動では選ばない
    case continuity
    /// それ以外（USB、Bluetoothなど）
    case other

    // kAudioDeviceTransportTypeBuiltIn 'bltn'
    private static let builtInCode: UInt32 = 0x626C746E
    // kAudioDeviceTransportTypeContinuityCaptureWired 'ccwd'（実機で見た値）
    private static let continuityWiredCode: UInt32 = 0x63637764
    // kAudioDeviceTransportTypeContinuityCaptureWireless 'ccwl'（CoreAudioの定義名から取った値）
    private static let continuityWirelessCode: UInt32 = 0x6363776C

    public init(fourCC: UInt32) {
        switch fourCC {
        case Self.builtInCode: self = .builtIn
        case Self.continuityWiredCode, Self.continuityWirelessCode: self = .continuity
        default: self = .other
        }
    }
}

/// 取り込み先の候補（接続中の入力機器）
public struct InputCandidate: Sendable, Equatable {
    public var uid: String
    public var transport: InputTransport

    public init(uid: String, transport: InputTransport) {
        self.uid = uid
        self.transport = transport
    }
}
