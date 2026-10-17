import Foundation

public enum LevelScale {
    /// グラフの下端。これ以下は0として描く
    public static let floorDBFS: Double = -80

    /// dBFSを0...1へ線形に直す。floor以下は0、0dBFS以上は1
    public static func normalized(dbfs: Double) -> Double {
        let ratio = (dbfs - floorDBFS) / (0 - floorDBFS)
        return min(max(ratio, 0), 1)
    }

    /// 完全な無音（AudioLevelが返す-120）か。静かな部屋の-70などは含まない
    public static func isSilent(dbfs: Double) -> Bool {
        dbfs <= -120.0
    }
}
