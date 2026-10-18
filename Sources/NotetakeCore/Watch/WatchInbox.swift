import Foundation

/// iPhoneの受け取り箱にある小片1件のsidecar。音声（`<id>.m4a`）と対で保存し、処理が済むまで消さない
public struct WatchInboxEntry: Codable, Sendable, Equatable {
    public static let maxAttempts = 3

    /// 受信時のUUID
    public var id: String
    /// contractsの`WatchChunkMetadata.encodedJSON()`
    public var metadataJSON: String
    public var receivedAtMS: Int64
    public var attempts: Int

    public init(id: String, metadataJSON: String, receivedAtMS: Int64, attempts: Int) {
        self.id = id
        self.metadataJSON = metadataJSON
        self.receivedAtMS = receivedAtMS
        self.attempts = attempts
    }

    public var metadata: WatchChunkMetadata? { WatchChunkMetadata(json: metadataJSON) }

    public var isExhausted: Bool { attempts >= Self.maxAttempts }

    private enum CodingKeys: String, CodingKey {
        case id
        case metadataJSON = "metadata_json"
        case receivedAtMS = "received_at_ms"
        case attempts
    }
}

public enum WatchInbox {
    /// `didReceive`が音声をコピーしてsidecarを書く途中のものを、前面化の`recover`が消さないための猶予
    public static let orphanGraceMS: Int64 = 300_000

    public static func audioFileName(id: String) -> String { "\(id).m4a" }
    public static func sidecarFileName(id: String) -> String { "\(id).json" }

    /// 受け取り箱のfile一覧から、処理するもの・試行を使い切ったもの・片方しか無いfileを分ける。
    /// `entries`はsidecarを`decode`できたものだけ（idがkey）。decodeできないsidecarは片方しか無い扱い
    public static func recoverable(
        files: [(name: String, modifiedMS: Int64)],
        entries: [String: WatchInboxEntry],
        nowMS: Int64
    ) -> (process: [WatchInboxEntry], exhausted: [WatchInboxEntry], orphanFiles: [String]) {
        var audioIDs: Set<String> = []
        var sidecarIDs: Set<String> = []
        for file in files {
            if file.name.hasSuffix(".m4a") {
                audioIDs.insert(String(file.name.dropLast(4)))
            } else if file.name.hasSuffix(".json") {
                sidecarIDs.insert(String(file.name.dropLast(5)))
            }
        }

        var process: [WatchInboxEntry] = []
        var exhausted: [WatchInboxEntry] = []
        var pairedIDs: Set<String> = []
        for id in audioIDs.intersection(sidecarIDs) {
            guard let entry = entries[id] else { continue }
            pairedIDs.insert(id)
            if entry.isExhausted { exhausted.append(entry) } else { process.append(entry) }
        }

        var orphans: [String] = []
        for file in files {
            let id: String
            if file.name.hasSuffix(".m4a") {
                id = String(file.name.dropLast(4))
            } else if file.name.hasSuffix(".json") {
                id = String(file.name.dropLast(5))
            } else {
                continue
            }
            guard !pairedIDs.contains(id) else { continue }
            if nowMS - file.modifiedMS >= orphanGraceMS { orphans.append(file.name) }
        }

        let byReceived: (WatchInboxEntry, WatchInboxEntry) -> Bool = {
            ($0.receivedAtMS, $0.id) < ($1.receivedAtMS, $1.id)
        }
        return (process.sorted(by: byReceived), exhausted.sorted(by: byReceived), orphans.sorted())
    }
}
