import Foundation

/// 小片の受領・Watchの記録・文字起こし・受け取り箱の件数から、Macへ中継する`WatchStatusSnapshot`を組み立てる。
/// 届く順は前後する（背面で溜まった前のsessionの小片、止まった後に届く止まる前の小片）ので、
/// sessionと時刻の新しい方を勝たせ、古い入力で表示を巻き戻さない
public struct WatchStatusTracker: Sendable, Equatable {
    /// 一度に足す欠番の上限。ありえない大きなindexの飛びで集合が膨らまないため
    private static let maxGapToTrack = 1_000

    private var current: WatchStatusSnapshot?
    private var missing: Set<Int> = []

    public init(snapshot: WatchStatusSnapshot? = nil) {
        current = snapshot
    }

    public var snapshot: WatchStatusSnapshot? {
        guard var out = current else { return nil }
        if !missing.isEmpty || out.missingChunkCount == 0 { out.missingChunkCount = missing.count }
        return out
    }

    // MARK: - chunk

    public mutating func chunkReceived(_ receipt: WatchChunkReceipt, deviceName: String) {
        if current == nil || current?.device != receipt.device {
            current = WatchStatusSnapshot(
                device: receipt.device, deviceName: deviceName, updatedAtMS: receipt.receivedAtMS)
            missing = []
        }
        guard var snap = current else { return }
        snap.deviceName = deviceName
        snap.lastChunkReceivedAtMS = max(snap.lastChunkReceivedAtMS ?? receipt.receivedAtMS, receipt.receivedAtMS)
        snap.updatedAtMS = max(snap.updatedAtMS, receipt.receivedAtMS)

        let order = snap.session.map { Self.compare(receipt.session, $0) } ?? .orderedDescending
        if order == .orderedAscending {
            current = snap
            return
        }

        let endMS = receipt.startAtMS + (receipt.durationMS ?? 0)
        if order == .orderedDescending {
            Self.beginSession(receipt.session, in: &snap, missing: &missing)
            snap.state = .unknown
            snap.stateAtMS = nil
        }

        // Watchはhaltを記録した後に最後の小片を閉じるので、終わりでなく先頭の時刻で比べる。
        // 止まった後に閉じた小片（先頭がhaltより前）で、haltを戻さない。
        // 最後の小片では止まった理由を消さない（停止の理由として残す）
        if snap.stateAtMS == nil || receipt.startAtMS > snap.stateAtMS! {
            snap.state = receipt.isFinal == true ? .stopped : .recording
            snap.stateAtMS = receipt.startAtMS
            if receipt.isFinal != true {
                snap.haltReason = nil
                snap.haltDetail = nil
            }
        }

        snap.levels.removeAll { $0.index == receipt.index }
        snap.levels.append(WatchChunkLevel(
            index: receipt.index, startAtMS: receipt.startAtMS, durationMS: receipt.durationMS,
            maxDBFS: receipt.maxDBFS, meanDBFS: receipt.meanDBFS))
        snap.levels.sort { $0.index > $1.index }
        if snap.levels.count > WatchStatusSnapshot.maxLevels {
            snap.levels.removeLast(snap.levels.count - WatchStatusSnapshot.maxLevels)
        }

        trackGaps(index: receipt.index, in: &snap)

        if let level = receipt.batteryLevel, snap.batteryAtMS == nil || endMS > snap.batteryAtMS! {
            snap.batteryLevel = level
            snap.batteryAtMS = endMS
        }

        snap.missingChunkCount = missing.count
        current = snap
    }

    private mutating func trackGaps(index: Int, in snap: inout WatchStatusSnapshot) {
        if let last = snap.lastChunkIndex {
            if index > last + 1, index - last - 1 <= Self.maxGapToTrack {
                missing.formUnion((last + 1)..<index)
            } else if index < last {
                missing.remove(index)
            }
            snap.lastChunkIndex = max(last, index)
        } else {
            snap.lastChunkIndex = index
        }
    }

    // MARK: - obs

    /// Watchの記録を反映する。まだ小片が1つも届いていない（snapshotが無い）時は何もしない
    public mutating func obsReceived(_ records: [WatchObsRecord]) {
        guard var snap = current else { return }
        for record in records { Self.apply(record, to: &snap, missing: &missing) }
        snap.missingChunkCount = missing.count
        current = snap
    }

    /// snapshotが無い・別のdeviceの時は、記録の`device`からsnapshotを作って反映する（開始に失敗して小片が1つも無い時など）
    public mutating func obsReceived(_ records: [WatchObsRecord], device: String, deviceName: String) {
        if current == nil || current?.device != device {
            missing = []
            current = WatchStatusSnapshot(
                device: device, deviceName: deviceName, updatedAtMS: records.map(\.atMS).max() ?? 0)
        }
        obsReceived(records)
    }

    private static func apply(_ record: WatchObsRecord, to snap: inout WatchStatusSnapshot, missing: inout Set<Int>) {
        var isNewSession = false
        if let session = record.session {
            if let currentSession = snap.session {
                switch compare(session, currentSession) {
                case .orderedAscending: return
                case .orderedDescending: isNewSession = true
                case .orderedSame: break
                }
            } else {
                isNewSession = true
            }
            if isNewSession {
                beginSession(session, in: &snap, missing: &missing)
                snap.state = .unknown
                snap.stateAtMS = nil
            }
        }
        snap.updatedAtMS = max(snap.updatedAtMS, record.atMS)

        func isNewer() -> Bool { snap.stateAtMS == nil || record.atMS > snap.stateAtMS! }

        switch record.event {
        case .halted, .startFailed:
            guard isNewer() else { return }
            snap.state = .halted
            snap.haltReason = record.haltReason ?? (record.event == .startFailed ? .startFailed : nil)
            snap.haltDetail = record.detail
            snap.stateAtMS = record.atMS
        case .stopped:
            guard isNewer() else { return }
            snap.state = .stopped
            snap.haltReason = nil
            snap.haltDetail = nil
            snap.stateAtMS = record.atMS
        case .autoStopped:
            guard isNewer() else { return }
            snap.state = .stopped
            snap.haltReason = .autoStopped
            snap.haltDetail = record.detail
            snap.stateAtMS = record.atMS
        case .started:
            guard isNewer() else { return }
            snap.state = .recording
            snap.haltReason = nil
            snap.haltDetail = nil
            snap.stateAtMS = record.atMS
        case .chunkClosed:
            if let level = record.batteryLevel, snap.batteryAtMS == nil || record.atMS > snap.batteryAtMS! {
                snap.batteryLevel = level
                snap.batteryAtMS = record.atMS
            }
        default:
            break
        }
    }

    // MARK: - text / inbox

    public mutating func textEmitted(_ text: String, atMS: Int64) {
        guard var snap = current else { return }
        snap.lastText = text
        snap.lastTextAtMS = atMS
        snap.updatedAtMS = max(snap.updatedAtMS, atMS)
        current = snap
    }

    public mutating func inboxChanged(pendingCount: Int, atMS: Int64) {
        guard var snap = current else { return }
        snap.inboxPendingCount = pendingCount
        snap.updatedAtMS = max(snap.updatedAtMS, atMS)
        current = snap
    }

    // MARK: - helpers

    /// sessionは録音の開始ms。数として比べ、読めなければ文字列で比べる
    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        if let x = Int64(a), let y = Int64(b) {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private static func beginSession(_ session: String, in snap: inout WatchStatusSnapshot, missing: inout Set<Int>) {
        snap.session = session
        snap.levels = []
        snap.lastChunkIndex = nil
        snap.haltReason = nil
        snap.haltDetail = nil
        missing = []
        snap.missingChunkCount = 0
    }
}
