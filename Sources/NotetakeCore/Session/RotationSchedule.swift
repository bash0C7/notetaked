import Foundation

/// 自動で区切る間隔の正規化と、次の区切り時刻の計算（純粋関数）
public enum RotationSchedule {
    public static let defaultIntervalHours: Double = 24

    /// 0以下・非有限（NaN / inf）は0（= 区切らない）に正規化。それ以外はそのまま
    public static func normalizedIntervalHours(_ hours: Double) -> Double {
        guard hours.isFinite, hours > 0 else { return 0 }
        return hours
    }

    /// intervalHoursが0以下・非有限なら nil。それ以外は start + hours * 3600 秒
    public static func nextRotation(recordingStartedAt start: Date, intervalHours: Double) -> Date? {
        guard intervalHours.isFinite, intervalHours > 0 else { return nil }
        return start.addingTimeInterval(intervalHours * 3600)
    }
}
