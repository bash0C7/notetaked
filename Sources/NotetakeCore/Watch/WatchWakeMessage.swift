import Foundation

/// WatchがiPhoneを背面で起こす`sendMessage`の辞書。音声や可変長の値は載せない（合図と小片の識別だけ）。
/// 小片・記録のmetadataやreplyと取り違えないよう、`kind`が`"wake"`の時だけ読む
public struct WatchWakeMessage: Sendable, Equatable {
    public var device: String
    public var session: String
    /// 閉じた小片のindex
    public var index: Int
    public var sentAtMS: Int64

    public init(device: String, session: String, index: Int, sentAtMS: Int64) {
        self.device = device
        self.session = session
        self.index = index
        self.sentAtMS = sentAtMS
    }

    public var message: [String: Any] {
        [
            "kind": "wake",
            "device": device,
            "session": session,
            "index": index,
            "sent_at_ms": sentAtMS,
        ]
    }

    public init?(message: [String: Any]) {
        guard
            message["kind"] as? String == "wake",
            let device = message["device"] as? String,
            let session = message["session"] as? String,
            let index = WireNumber.int64(message["index"]),
            let sentAtMS = WireNumber.int64(message["sent_at_ms"])
        else {
            return nil
        }
        self.init(device: device, session: session, index: Int(index), sentAtMS: sentAtMS)
    }
}

/// iPhoneが合図へ返す辞書
public struct WatchWakeReply: Sendable, Equatable {
    public var receivedAtMS: Int64

    public init(receivedAtMS: Int64) {
        self.receivedAtMS = receivedAtMS
    }

    public var message: [String: Any] {
        ["kind": "wake_reply", "received_at_ms": receivedAtMS]
    }

    public init?(message: [String: Any]) {
        guard
            message["kind"] as? String == "wake_reply",
            let receivedAtMS = WireNumber.int64(message["received_at_ms"])
        else {
            return nil
        }
        self.init(receivedAtMS: receivedAtMS)
    }
}

private enum WireNumber {
    /// Int / Int64 / NSNumber / 整数値のDoubleを許す。boolと小数は読まない
    static func int64(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        switch any {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(exactly: v)
        case let v as NSNumber: return Int64(exactly: v.doubleValue)
        default: return nil
        }
    }
}
