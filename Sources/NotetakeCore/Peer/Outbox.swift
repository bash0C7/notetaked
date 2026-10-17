import Foundation

/// iPhone側の未送信seg蓄積（ファイル追記 + ack済みseqカーソル）
public actor Outbox {
    public nonisolated let outboxURL: URL
    public nonisolated let cursorURL: URL
    /// compactIfDrainedが最初の1回だけ取る、compact前のoutbox.jsonlの控え
    public nonisolated let backupURL: URL

    private var fileHandle: FileHandle?
    private var lastAppendedSeq: Int
    private var acked: Int

    /// <dir>/outbox.jsonl（seg NDJSON、Record.segmentで1行）と<dir>/outbox.cursor（ack済み最大seq、10進文字列）
    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.outboxURL = directory.appendingPathComponent("outbox.jsonl")
        self.cursorURL = directory.appendingPathComponent("outbox.cursor")

        self.backupURL = directory.appendingPathComponent("outbox.before-compact.jsonl")

        var ackedSeq = 0
        if let cursorText = try? String(contentsOf: cursorURL, encoding: .utf8) {
            let trimmed = cursorText.trimmingCharacters(in: .whitespacesAndNewlines)
            ackedSeq = Int(trimmed) ?? 0
        }
        self.acked = ackedSeq

        var maxSeq = 0
        if let text = try? String(contentsOf: outboxURL, encoding: .utf8) {
            for record in NDJSON.decodeAll(text) {
                if case .segment(let segment) = record {
                    maxSeq = max(maxSeq, segment.seq)
                }
            }
        }
        // compactで全行を捨てた後でも、ack済みseqを再採番しない
        self.lastAppendedSeq = max(maxSeq, ackedSeq)
    }

    /// segment.seqをそのまま記録（呼び出し側が単調増加させる）。開いたまま保持して追記
    public func append(_ segment: Segment) throws {
        let handle = try openHandle()
        let line = try NDJSON.encode(.segment(segment)) + "\n"
        try handle.write(contentsOf: Data(line.utf8))
        lastAppendedSeq = max(lastAppendedSeq, segment.seq)
    }

    /// 最後にappendしたseq + 1（起動時はファイルを走査して復元、無ければ1）
    public func nextSeq() -> Int {
        lastAppendedSeq + 1
    }

    /// `nextSeq()`を採番して`segment.seq`に入れ、そのままappendする（actor内で中断点なしに行うため、
    /// 複数の呼び出し元（mic / Watch中継）が同じseqを取ることがない）。採番後のsegmentを返す
    @discardableResult
    public func appendAssigningSeq(_ segment: Segment) throws -> Segment {
        var sequenced = segment
        sequenced.seq = nextSeq()
        try append(sequenced)
        return sequenced
    }

    /// seq > ackedSeqのもの、seq昇順
    public func pending() throws -> [Segment] {
        guard let text = try? String(contentsOf: outboxURL, encoding: .utf8) else { return [] }
        let segments: [Segment] = NDJSON.decodeAll(text).compactMap { record in
            if case .segment(let segment) = record, segment.seq > acked {
                return segment
            }
            return nil
        }
        return segments.sorted { $0.seq < $1.seq }
    }

    /// cursor更新（後退しない）
    public func acknowledge(upTo seq: Int) throws {
        guard seq > acked else { return }
        // cursorを書けてからackedを進める。書けないまま進めると、compact後の再起動でseqが戻る
        try String(seq).write(to: cursorURL, atomically: true, encoding: .utf8)
        acked = seq
    }

    /// cursorファイルを読み直した値。読めない・数値でない時はnil
    private func persistedCursor() -> Int? {
        guard let text = try? String(contentsOf: cursorURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var ackedSeq: Int {
        acked
    }

    /// 未ackの件数（lastAppendedSeq - acked、負にならない）
    public var unacknowledgedCount: Int {
        max(0, lastAppendedSeq - acked)
    }

    /// 未ackが0件で、outbox.jsonlに中身がある時だけcompactする。compact前の控えを`backupURL`に1回だけ残す。
    /// cursorファイルが読めて`lastAppendedSeq`以上の時だけ行う（再起動でseqが戻り、Macに受信済みとして捨てられるのを防ぐ）。
    /// compactしたらtrue、何もしなかったらfalse
    @discardableResult
    public func compactIfDrained() throws -> Bool {
        guard lastAppendedSeq <= acked else { return false }
        guard let persisted = persistedCursor(), persisted >= lastAppendedSeq else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: outboxURL.path)
        guard let size = attributes?[.size] as? NSNumber, size.intValue > 0 else { return false }
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.copyItem(at: outboxURL, to: backupURL)
        }
        try compact()
        return true
    }

    /// ack済み行を捨てて書き直す
    public func compact() throws {
        let remaining = try pending()
        var text = ""
        for segment in remaining {
            text += try NDJSON.encode(.segment(segment)) + "\n"
        }
        try Data(text.utf8).write(to: outboxURL, options: .atomic)
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle = fileHandle {
            return handle
        }
        if !FileManager.default.fileExists(atPath: outboxURL.path) {
            FileManager.default.createFile(atPath: outboxURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: outboxURL)
        _ = try handle.seekToEnd()
        fileHandle = handle
        return handle
    }
}
