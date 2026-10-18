import Foundation
import NotetakeCore

/// Watchの小片の受け取り箱（`<Application Support>/Notetake/watch-inbox`）。
/// 1件は`<id>.m4a`と`<id>.json`（`WatchInboxEntry`）の対で、処理が成功するまで消さない。
/// 状態を持たず、どのthreadからも呼べる（`didReceive`のcallbackからも同期的に使う）
struct WatchInboxStore: Sendable {
    let directory: URL

    var failedDirectory: URL { directory.appendingPathComponent("failed", isDirectory: true) }

    static func standard() -> WatchInboxStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Notetake/watch-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WatchInboxStore(directory: directory)
    }

    func audioURL(id: String) -> URL { directory.appendingPathComponent(WatchInbox.audioFileName(id: id)) }
    func sidecarURL(id: String) -> URL { directory.appendingPathComponent(WatchInbox.sidecarFileName(id: id)) }

    /// 音声をコピーし、sidecarを`.atomic`で書く。`didReceive`のcallbackの中で同期的に呼ぶ
    /// （戻ると`file.fileURL`が消えるため）。sidecarが書けなければ音声も消して投げる
    func save(audioFrom source: URL, metadata: WatchChunkMetadata, receivedAtMS: Int64) throws -> WatchInboxEntry {
        let id = UUID().uuidString
        let entry = WatchInboxEntry(
            id: id, metadataJSON: try metadata.encodedJSON(), receivedAtMS: receivedAtMS, attempts: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: audioURL(id: id))
        // copyItemは元の更新時刻を引き継ぐ。受け取り箱に溜まっていた小片が、`didReceive`が書き終える前に
        // 並行の`recover`から「音声だけの古い片割れ」に見えて`failed/`へ移されないよう、今の時刻にする
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: audioURL(id: id).path)
        do {
            try write(entry)
        } catch {
            try? FileManager.default.removeItem(at: audioURL(id: id))
            throw error
        }
        return entry
    }

    func entry(id: String) -> WatchInboxEntry? {
        guard let data = try? Data(contentsOf: sidecarURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(WatchInboxEntry.self, from: data)
    }

    /// 処理に失敗した小片の`attempts`を1増やして残す（次の`recover`で試し直す）
    func markAttempt(id: String) {
        guard var entry = entry(id: id) else { return }
        entry.attempts += 1
        try? write(entry)
    }

    /// 処理の成功か、続けても無意味な小片の破棄で、音声とsidecarを消す
    func remove(id: String) {
        try? FileManager.default.removeItem(at: audioURL(id: id))
        try? FileManager.default.removeItem(at: sidecarURL(id: id))
    }

    /// 受け取り箱にある未処理の件数（sidecarの数）
    func pendingCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }

    /// 起動時・合図で起きた時・前面になった時に呼ぶ。処理できるものを列へ積み、
    /// 試行を使い切ったものと片方しか無いfileは`failed/`へ移す（消さない。保持期間は`pruneFailed`）。
    /// 列に載っている・処理中のidの再投入は`WatchIntakeQueue`が捨てる。積んだ件数を返す
    @discardableResult
    func recover(into intake: WatchIntakeQueue, nowMS: Int64) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var files: [(name: String, modifiedMS: Int64)] = []
        var entries: [String: WatchInboxEntry] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasSuffix(".m4a") || name.hasSuffix(".json") else { continue }
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            files.append((name, Int64(((modified ?? Date()).timeIntervalSince1970 * 1000).rounded())))
            if name.hasSuffix(".json"),
                let data = try? Data(contentsOf: url),
                let entry = try? JSONDecoder().decode(WatchInboxEntry.self, from: data),
                entry.id == String(name.dropLast(5))
            {
                entries[entry.id] = entry
            }
        }
        let result = WatchInbox.recoverable(files: files, entries: entries, nowMS: nowMS)
        for entry in result.process { intake.submit(entry) }
        for entry in result.exhausted {
            moveToFailed(WatchInbox.audioFileName(id: entry.id))
            moveToFailed(WatchInbox.sidecarFileName(id: entry.id))
        }
        for name in result.orphanFiles { moveToFailed(name) }
        return result.process.count
    }

    /// `failed/`で`failedInboxDays`を過ぎたfileを消す
    func pruneFailed(nowMS: Int64) {
        Self.prune(directory: failedDirectory, days: RetentionPolicy.failedInboxDays, nowMS: nowMS)
    }

    /// directory直下で更新から`days`日を過ぎたfileを消す
    static func prune(directory: URL, days: Int, nowMS: Int64, matching: (String) -> Bool = { _ in true }) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var files: [(name: String, modifiedMS: Int64)] = []
        for url in urls where matching(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            files.append((url.lastPathComponent, Int64((modified.timeIntervalSince1970 * 1000).rounded())))
        }
        for name in RetentionPolicy.expired(files: files, nowMS: nowMS, days: days) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func write(_ entry: WatchInboxEntry) throws {
        let data = try JSONEncoder().encode(entry)
        try data.write(to: sidecarURL(id: entry.id), options: .atomic)
    }

    private func moveToFailed(_ name: String) {
        let source = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        let destination = failedDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
    }
}
