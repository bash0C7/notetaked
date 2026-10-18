import Foundation

/// Watch内だけのsidecarの形式（`<file>.m4a.json`）。未完了の小片を検査で救えるよう、開いた時点から
/// `metadataJSON`を持つ。phase 1aの形式（`WatchChunkMetadata.metadata`そのもののJSON）は完了済みとして読む
public struct WatchChunkSidecar: Codable, Sendable, Equatable {
    public var complete: Bool
    public var session: String
    public var index: Int
    public var openedAtMS: Int64
    public var durationMS: Int64?
    /// `WatchChunkMetadata.encodedJSON()`
    public var metadataJSON: String

    public init(
        complete: Bool, session: String, index: Int, openedAtMS: Int64, durationMS: Int64?, metadataJSON: String
    ) {
        self.complete = complete
        self.session = session
        self.index = index
        self.openedAtMS = openedAtMS
        self.durationMS = durationMS
        self.metadataJSON = metadataJSON
    }

    private enum CodingKeys: String, CodingKey {
        case complete
        case session
        case index
        case openedAtMS = "opened_at_ms"
        case durationMS = "duration_ms"
        case metadataJSON = "metadata_json"
    }

    public static func decode(_ data: Data) -> WatchChunkSidecar? {
        if let sidecar = try? JSONDecoder().decode(WatchChunkSidecar.self, from: data) {
            return sidecar
        }
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let legacy = WatchChunkMetadata(metadata: object),
            let json = try? legacy.encodedJSON()
        else {
            return nil
        }
        return WatchChunkSidecar(
            complete: true, session: legacy.session, index: legacy.index, openedAtMS: legacy.startAtMS,
            durationMS: legacy.durationMS, metadataJSON: json)
    }

    public var metadata: WatchChunkMetadata? {
        WatchChunkMetadata(json: metadataJSON)
    }

    /// 未完了のsidecarを、読めたframe数で完了にする。`isFinal`は付けない
    public func completedByInspection(frames: Int64) -> WatchChunkSidecar? {
        guard frames >= 1, var meta = metadata, meta.sampleRate > 0 else { return nil }
        let duration = Int64((Double(frames) / meta.sampleRate * 1000).rounded())
        meta.durationMS = duration
        meta.isFinal = nil
        guard let json = try? meta.encodedJSON() else { return nil }
        var done = self
        done.complete = true
        done.durationMS = duration
        done.metadataJSON = json
        return done
    }
}

public struct StoredChunk: Sendable, Equatable {
    public var fileName: String
    public var sidecar: WatchChunkSidecar?
    public var sizeBytes: Int64

    public init(fileName: String, sidecar: WatchChunkSidecar?, sizeBytes: Int64) {
        self.fileName = fileName
        self.sidecar = sidecar
        self.sizeBytes = sizeBytes
    }
}

/// `resend`は送り直す完了済み、`inspect`は未完了で中身を読んで確かめるもの、`drop`は消すもの、
/// `cancelBeforeDrop`は`drop`のうち転送中なので先に`WCSessionFileTransfer.cancel()`するもの
public struct ChunkStorePlan: Sendable, Equatable {
    public var resend: [String]
    public var inspect: [String]
    public var drop: [String]
    public var cancelBeforeDrop: [String]
    public var droppedDurationMS: Int64

    public init(
        resend: [String] = [], inspect: [String] = [], drop: [String] = [], cancelBeforeDrop: [String] = [],
        droppedDurationMS: Int64 = 0
    ) {
        self.resend = resend
        self.inspect = inspect
        self.drop = drop
        self.cancelBeforeDrop = cancelBeforeDrop
        self.droppedDurationMS = droppedDurationMS
    }
}

public enum WatchChunkStorePolicy {
    /// Watch内の保持の上限。20秒・32kbpsのAACで約2,500小片・約14時間ぶん
    public static let capacityBytes: Int64 = 200 * 1024 * 1024

    /// `recover`へ渡す録音中のsession。後始末で積み残しのbufferを書いている最中のsessionも録音中として扱う
    public static func activeSession(current: String?, draining: String?) -> String? {
        current ?? draining
    }

    /// `activeSession`の小片は、resendにもinspectにも入れない（書きかけや、閉じてから`transferFile`を呼ぶまでの小片を
    /// 送らないため）。起動時は`nil`
    public static func plan(
        stored: [StoredChunk], outstanding: Set<String>, activeSession: String?
    ) -> ChunkStorePlan {
        var plan = ChunkStorePlan()
        let activeLatestIndex: Int? = activeSession.flatMap { active in
            stored.compactMap { parse(fileName: $0.fileName) }.filter { $0.session == active }.map(\.index).max()
        }
        var dropped: Set<String> = []
        var candidates: [(chunk: StoredChunk, sidecar: WatchChunkSidecar)] = []

        for chunk in stored {
            let name = chunk.fileName
            let parsed = parse(fileName: name)
            let isActive = activeSession != nil && (chunk.sidecar?.session ?? parsed?.session) == activeSession
            guard let sidecar = chunk.sidecar else {
                if isActive, parsed?.index == activeLatestIndex { continue }
                plan.drop.append(name)
                dropped.insert(name)
                continue
            }
            if sidecar.complete { candidates.append((chunk, sidecar)) }
            if isActive { continue }
            if !sidecar.complete {
                plan.inspect.append(name)
            } else if !outstanding.contains(name) {
                plan.resend.append(name)
            }
        }

        var total: Int64 = stored.filter { !dropped.contains($0.fileName) }.reduce(0) { $0 + $1.sizeBytes }
        if total > capacityBytes {
            let oldestFirst = candidates.sorted {
                let l = (Int64($0.sidecar.session) ?? 0, $0.sidecar.index)
                let r = (Int64($1.sidecar.session) ?? 0, $1.sidecar.index)
                return l < r
            }
            for (chunk, sidecar) in oldestFirst where total > capacityBytes {
                total -= chunk.sizeBytes
                plan.drop.append(chunk.fileName)
                if outstanding.contains(chunk.fileName) { plan.cancelBeforeDrop.append(chunk.fileName) }
                plan.droppedDurationMS += sidecar.durationMS ?? 0
                plan.resend.removeAll { $0 == chunk.fileName }
            }
        }
        return plan
    }

    /// `<session>-<index>.m4a`
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
