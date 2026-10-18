import Foundation
import NotetakeCore
import WatchConnectivity

/// Watch側の出来事を`<directory>/current.jsonl`へ1行ずつ追記し、区切りごとにiPhoneへ`transferFile`で送る。
/// 記録の失敗で録音を止めないため、書き込み・rename・列挙の失敗は捨てる。
/// 送り切れなかったfileは`<device>-<createdAtMS>.jsonl`のまま残り、次の起動の`resendLeftovers`が送り直す。
@MainActor
final class WatchObsLog {
    /// 20秒の小片で約5分ごと
    static let shipEveryChunks = 15

    private static let currentFileName = "current.jsonl"

    private let directory: URL
    private let device: String
    private var handle: FileHandle?

    init(directory: URL, device: String) {
        self.directory = directory
        self.device = device
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var currentURL: URL {
        directory.appendingPathComponent(Self.currentFileName)
    }

    /// `current.jsonl`へ1行追記する。開いた`FileHandle`は持ち続ける
    func record(_ record: WatchObsRecord) {
        guard let line = try? record.encodedLine() else { return }
        guard let handle = openHandle() else { return }
        let data: Data = Data((line + "\n").utf8)
        try? handle.write(contentsOf: data)
    }

    /// `current.jsonl`が空でなければ閉じて`<device>-<nowMS>.jsonl`へ改名し、送る。
    /// 次の`record`で新しい`current.jsonl`を開く
    func ship(nowMS: Int64) {
        closeHandle()
        let url = currentURL
        let size: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let meta = WatchObsFileMetadata(device: device, createdAtMS: nowMS)
        let shipped = directory.appendingPathComponent(meta.fileName)
        // 同じmsに2回shipした時に上書きで失わないよう、既存があれば何もせず次の区切りへ持ち越す
        guard !FileManager.default.fileExists(atPath: shipped.path) else { return }
        do {
            try FileManager.default.moveItem(at: url, to: shipped)
        } catch {
            return
        }
        WCSession.default.transferFile(shipped, metadata: meta.metadata)
    }

    /// 起動時: 他の`.jsonl`をfile名からmetadataを作り直して送り直し、前回の`current.jsonl`が残っていれば`ship`する
    func resendLeftovers(nowMS: Int64) {
        let files: [URL] =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jsonl" && url.lastPathComponent != Self.currentFileName {
            guard let meta = Self.metadata(fromFileName: url.lastPathComponent) else { continue }
            WCSession.default.transferFile(url, metadata: meta.metadata)
        }
        ship(nowMS: nowMS)
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let url = currentURL
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// `<device>-<createdAtMS>.jsonl`から復元する。deviceにも`-`が入る（UUID）ので最後の`-`で割る
    private static func metadata(fromFileName name: String) -> WatchObsFileMetadata? {
        let stem: String = (name as NSString).deletingPathExtension
        guard
            let separator = stem.lastIndex(of: "-"),
            let createdAtMS = Int64(stem[stem.index(after: separator)...])
        else {
            return nil
        }
        let device = String(stem[..<separator])
        guard !device.isEmpty else { return nil }
        return WatchObsFileMetadata(device: device, createdAtMS: createdAtMS)
    }
}
