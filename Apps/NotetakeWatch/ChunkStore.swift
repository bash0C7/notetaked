import AVFoundation
import Foundation
import NotetakeCore
import WatchConnectivity

/// 小片のfile名の決め方。`<session>-<index>.m4a`と、そのsidecar`<file>.m4a.json`
enum ChunkFiles {
    static func audioURL(directory: URL, session: String, index: Int) -> URL {
        directory.appendingPathComponent("\(session)-\(index).m4a")
    }

    static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("json")
    }
}

/// diskに残っている小片の走査と、`WatchChunkStorePolicy.plan`の実行。判断は`NotetakeCore`の純ロジックにあり、
/// ここはfile・`AVAudioFile`・`WCSessionFileTransfer`を扱うだけ
@MainActor
struct ChunkStore {
    let directory: URL

    /// diskの小片を`StoredChunk`にする。音声の無いsidecarは掃除する
    func scan() -> [StoredChunk] {
        let urls: [URL] = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var chunks: [StoredChunk] = []
        for url in urls where url.pathExtension == "m4a" {
            let size: Int64 = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            chunks.append(StoredChunk(fileName: url.lastPathComponent, sidecar: loadSidecar(of: url), sizeBytes: size))
        }
        let audioNames = Set(chunks.map(\.fileName))
        for url in urls where url.pathExtension == "json" && url.lastPathComponent.hasSuffix(".m4a.json") {
            let audioName = String(url.lastPathComponent.dropLast(".json".count))
            if !audioNames.contains(audioName) { try? FileManager.default.removeItem(at: url) }
        }
        return chunks
    }

    func loadSidecar(of audioURL: URL) -> WatchChunkSidecar? {
        guard let data = try? Data(contentsOf: ChunkFiles.sidecarURL(for: audioURL)) else { return nil }
        return WatchChunkSidecar.decode(data)
    }

    /// `outstanding`は`WCSession`と自分が持っている転送中の小片（file名 → 転送）。
    /// `transferFile`は呼び出し側が転送の表へ載せるclosure、`record`は記録を書くclosure
    func recover(
        activeSession: String?,
        outstanding: [String: WCSessionFileTransfer],
        transferFile: (URL, WatchChunkMetadata) -> Void,
        record: (WatchObsRecord) -> Void,
        nowMS: Int64
    ) {
        let stored = scan()
        let plan = WatchChunkStorePolicy.plan(
            stored: stored, outstanding: Set(outstanding.keys), activeSession: activeSession)
        let byName: [String: StoredChunk] = Dictionary(stored.map { ($0.fileName, $0) }) { first, _ in first }

        for name in plan.cancelBeforeDrop { outstanding[name]?.cancel() }
        for name in plan.drop {
            let chunk = byName[name]
            removeFiles(named: name)
            record(droppedRecord(name: name, sidecar: chunk?.sidecar, reason: dropReason(for: chunk), nowMS: nowMS))
        }
        for name in plan.resend {
            let url = directory.appendingPathComponent(name)
            guard let metadata = byName[name]?.sidecar?.metadata else {
                removeFiles(named: name)
                record(droppedRecord(name: name, sidecar: byName[name]?.sidecar, reason: "sidecar_unreadable", nowMS: nowMS))
                continue
            }
            transferFile(url, metadata)
        }
        for name in plan.inspect {
            let url = directory.appendingPathComponent(name)
            let sidecar = byName[name]?.sidecar
            guard
                let frames = Self.readableFrames(of: url),
                let completed = sidecar?.completedByInspection(frames: frames),
                let metadata = completed.metadata,
                Self.write(completed, for: url)
            else {
                removeFiles(named: name)
                record(droppedRecord(name: name, sidecar: sidecar, reason: "incomplete_unreadable", nowMS: nowMS))
                continue
            }
            transferFile(url, metadata)
        }
    }

    private func dropReason(for chunk: StoredChunk?) -> String {
        guard let chunk else { return "unknown" }
        return chunk.sidecar == nil ? "no_sidecar" : "over_capacity"
    }

    private func droppedRecord(name: String, sidecar: WatchChunkSidecar?, reason: String, nowMS: Int64) -> WatchObsRecord {
        let parsed = Self.parse(fileName: name)
        return WatchObsRecord(
            atMS: nowMS, event: .chunkDropped, session: sidecar?.session ?? parsed?.session,
            index: sidecar?.index ?? parsed?.index, detail: reason,
            value: sidecar?.durationMS.map { Double($0) / 1000 })
    }

    private func removeFiles(named name: String) {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ChunkFiles.sidecarURL(for: url))
    }

    /// 開けて1 frame以上読めれば、そのframe数。書きかけのAACが読めるかは実機でしか分からない
    private static func readableFrames(of url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url), file.length >= 1 else { return nil }
        return Int64(file.length)
    }

    private static func write(_ sidecar: WatchChunkSidecar, for audioURL: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(sidecar) else { return false }
        do {
            try data.write(to: ChunkFiles.sidecarURL(for: audioURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func parse(fileName: String) -> (session: String, index: Int)? {
        let stem = (fileName as NSString).deletingPathExtension
        guard
            let separator = stem.lastIndex(of: "-"),
            let index = Int(stem[stem.index(after: separator)...])
        else {
            return nil
        }
        return (String(stem[..<separator]), index)
    }
}
