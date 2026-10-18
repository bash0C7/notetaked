import Foundation

/// Watchのsessionごとに、処理済みのindexと起点を覚える台帳。
/// streamを作り直しても・再送で同じindexが来ても二重にfeedしないための永続の正本。
/// appが`Application Support/Notetake/watch-ledger.json`へ`.atomic`で書く
public struct WatchSessionLedger: Codable, Sendable, Equatable {
    private struct Record: Codable, Sendable, Equatable {
        var processed: Set<Int> = []
        var finished = false
        /// 処理済みの小片の終わり（`startAtMS + durationMS`）の最大。streamを作り直す時の起点に使う
        var maxEndAtMS: Int64?
        var updatedAtMS: Int64
    }

    private var sessions: [String: Record] = [:]

    public init() {}

    /// sessionはWatchの録音の開始ms。数として読めなければnil
    public func originMS(session: String) -> Int64? { Int64(session) }

    public func isProcessed(session: String, index: Int) -> Bool {
        sessions[session]?.processed.contains(index) ?? false
    }

    public mutating func markProcessed(session: String, index: Int, atMS: Int64, endAtMS: Int64? = nil) {
        var record = sessions[session] ?? Record(updatedAtMS: atMS)
        record.processed.insert(index)
        if let endAtMS { record.maxEndAtMS = max(record.maxEndAtMS ?? endAtMS, endAtMS) }
        record.updatedAtMS = max(record.updatedAtMS, atMS)
        sessions[session] = record
    }

    public mutating func markFinished(session: String, atMS: Int64) {
        var record = sessions[session] ?? Record(updatedAtMS: atMS)
        record.finished = true
        record.updatedAtMS = max(record.updatedAtMS, atMS)
        sessions[session] = record
    }

    public func isFinished(session: String) -> Bool { sessions[session]?.finished ?? false }

    /// 0から最大の処理済みindexまでの欠番
    public func missingIndexes(session: String) -> [Int] {
        guard let record = sessions[session], let last = record.processed.max() else { return [] }
        return (0...last).filter { !record.processed.contains($0) }
    }

    /// 作り直したstreamの起点を、処理済みの終わりからさかのぼる量（ms）。小片の長さ・時計の丸めの余裕
    public static let rebuildToleranceMS: Int64 = 2_000

    /// streamのTranscriberの起点。新しいsessionはsession文字列（録音の開始ms）から決める。
    /// 台帳に処理済みがある（streamを閉じて作り直す）時は、feedの時刻が録音の経過時間ぶん大きくならないよう
    /// 処理済みの小片の終わりの少し前にする。続きの小片は終わり以後に始まるのでoffsetが負にならず、
    /// 複数の小片が同じ時刻に丸められない。sessionの開始より前にも、最初の小片の先頭より後にもしない
    public func streamOriginMS(session: String, firstChunkStartAtMS: Int64) -> Int64 {
        guard let sessionOrigin = originMS(session: session) else { return firstChunkStartAtMS }
        guard let record = sessions[session], !record.processed.isEmpty else { return sessionOrigin }
        guard let maxEnd = record.maxEndAtMS else { return sessionOrigin }
        return min(max(sessionOrigin, maxEnd - Self.rebuildToleranceMS), firstChunkStartAtMS)
    }

    /// 次に流すindex（最大の処理済みindex + 1。無ければ0）。sequencerを台帳の続きから始める時に使う
    public func nextIndex(session: String) -> Int {
        (sessions[session]?.processed.max()).map { $0 + 1 } ?? 0
    }

    /// 最後の更新が`olderThanMS`より古いsessionを消す
    public mutating func prune(olderThanMS: Int64) {
        sessions = sessions.filter { $0.value.updatedAtMS >= olderThanMS }
    }
}
