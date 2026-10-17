import Foundation

/// 生のsample列を一定の長さで区切り、区切りごとのdBFSにする
public enum LevelChunker {
    /// `chunkSamples`ごとのdBFS。端数の最後の区切りは足りない分だけで計算せず、返さない
    /// （端数は呼び出し側が次回へ持ち越す）
    public static func dbfsSeries(samples: [Float], chunkSamples: Int) -> [Double] {
        guard chunkSamples > 0 else { return [] }
        return stride(from: 0, through: samples.count - chunkSamples, by: chunkSamples).map { start in
            AudioLevel.dbfs(Array(samples[start..<start + chunkSamples]))
        }
    }
}
