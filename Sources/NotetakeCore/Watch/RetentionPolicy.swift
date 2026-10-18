import Foundation

/// iPhone内の記録・受領記録・失敗した小片の保持期間
public enum RetentionPolicy {
    public static let obsDays = 30
    public static let receiptDays = 30
    public static let failedInboxDays = 7

    private static let dayMS: Int64 = 86_400_000

    /// 更新から`days`日を超えたfileの名前（ちょうど`days`日は残す）
    public static func expired(files: [(name: String, modifiedMS: Int64)], nowMS: Int64, days: Int) -> [String] {
        let limit = Int64(days) * dayMS
        return files.filter { nowMS - $0.modifiedMS > limit }.map(\.name)
    }
}
