import Foundation

/// `finalized`の記録から、(device, source)の組ごとに使う確定版の回を求め、描画に使う記録を選ぶ。
/// 確定版の発話は、その回の`finalized`の記録がある時だけ有効になる。取り込みの途中で落ちて
/// `finalized`が無い回の発話は、何度取り込み直しても描画に出ない
public struct FinalizedRuns: Sendable {
    private struct Key: Hashable {
        var device: String
        var source: Source
    }

    private var latest: [Key: Int] = [:]
    private var activeRuns: Set<Int> = []

    public init(records: [Record]) {
        for record in records {
            guard case .finalized(let finalized) = record else { continue }
            for source in finalized.sources {
                let key = Key(device: finalized.device, source: source)
                latest[key] = max(latest[key] ?? 0, finalized.run)
            }
        }
        activeRuns = Set(latest.values)
    }

    /// `device`の確定版のうち最新の回。無ければnil
    public static func latestRun(in records: [Record], device: String) -> Int? {
        var latest: Int?
        for record in records {
            guard case .finalized(let finalized) = record, finalized.device == device else { continue }
            latest = max(latest ?? 0, finalized.run)
        }
        return latest
    }

    /// `record`を描画に使うか。
    /// - 確定版の発話: その(device, source)の最新の回のものだけ
    /// - 暫定版の発話: その(device, source)に確定版が無い時だけ
    /// - 回を持つ名前とまとめ: いずれかの組で使っている回のものだけ。回の無い名前は従来の大域idへの名前
    public func includes(_ record: Record) -> Bool {
        switch record {
        case .segment(let segment):
            let active = latest[Key(device: segment.device, source: segment.source)]
            if segment.pass == .final {
                return segment.run != nil && segment.run == active
            }
            return active == nil
        case .speakerName(let rename):
            return rename.run.map(activeRuns.contains) ?? true
        case .speakerMerge(let merge):
            return activeRuns.contains(merge.run)
        case .session, .device, .sessionEnd, .finalized:
            return true
        }
    }
}
