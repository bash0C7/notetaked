public struct PeerSegSummary: Sendable, Equatable {
    public var device: String
    public var deviceName: String
    public var receivedAt: Int64
    public var outcome: PeerSegOutcome
    public var platform: Platform?

    public init(device: String, deviceName: String, receivedAt: Int64, outcome: PeerSegOutcome, platform: Platform? = nil) {
        self.device = device
        self.deviceName = deviceName
        self.receivedAt = receivedAt
        self.outcome = outcome
        self.platform = platform
    }

    /// 端末種別ごとの、受信の最も新しいもの。`platform`が無い旧い通知はiPhone（`.ios`）として扱う
    public static func latest(_ items: [PeerSegSummary], platform: Platform) -> PeerSegSummary? {
        items.filter { ($0.platform ?? .ios) == platform }.max { $0.receivedAt < $1.receivedAt }
    }
}
