import Foundation

/// `timed.jsonl`と`orphans.jsonl`のような、記録を1行ずつ追記するファイルの書き込み
enum TimedFile {
    /// 追記用に開き、末尾へ移動して返す。ファイルが無ければ作る。
    /// 書き手が落ちて改行で終わっていない最後の行は、その行だけが壊れた行になるよう改行で閉じる
    static func openForAppend(at url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        do {
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if last != Data([0x0A]) {
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
        } catch {
            try? handle.close()
            throw error
        }
        return handle
    }

    /// 記録を1回の書き込みで足す。途中で落ちても、読み手は読めた行だけを使う
    static func append(_ records: [Record], to url: URL) throws {
        var data = Data()
        for record in records {
            data.append(Data((try NDJSON.encode(record) + "\n").utf8))
        }
        let handle = try openForAppend(at: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
