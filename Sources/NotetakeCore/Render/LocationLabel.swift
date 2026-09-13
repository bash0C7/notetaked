import Foundation

/// 場所（入力機材・方位）の表示用文字列。パネルとfinal.mdで共通
public enum LocationLabel {
    public static func short(inputName: String, platform: Platform, source: Source) -> String {
        if source == .system { return "system" }
        switch platform {
        case .watchos: return "Watch"
        case .ios: return "iPhone"
        case .mac: return inputName.contains("AirPods") ? "AirPods" : "Mac"
        }
    }

    /// 30°刻みで最寄りの時計位置。0°→12時
    public static func clock(azimuthDeg: Double) -> String {
        let hour = Int((azimuthDeg / 30).rounded()) % 12
        return "\(hour == 0 ? 12 : hour)時"
    }

    public static func text(inputName: String, platform: Platform, source: Source, direction: Direction?) -> String {
        let label = short(inputName: inputName, platform: platform, source: source)
        guard let direction else { return label }
        return "\(label) \(clock(azimuthDeg: direction.azimuthDeg))"
    }

    public static func text(for utterance: Utterance) -> String {
        text(inputName: utterance.input, platform: utterance.platform, source: utterance.source,
             direction: utterance.direction)
    }
}
