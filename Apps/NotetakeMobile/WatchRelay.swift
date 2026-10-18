import AVFoundation
import Foundation
import NotetakeCore
import WatchConnectivity

/// `replyHandler`はSendableでないので、MainActorへ渡して呼ぶためのbox。
/// WCSessionのreplyHandlerはどのthreadからも1度だけ呼んでよい
private final class ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}

// MARK: - WatchSessionDelegate

/// WCSessionのdelegate。callbackはバックグラウンドの任意スレッド（WCSessionが内部で使う
/// 非公開のserial queue）から呼ばれ、`actor`にも`@MainActor`にも属さない普通の`NSObject`
/// subclassなので、各メソッドは`nonisolated`相当（isolationを持たない）として振る舞う。
/// 保持する状態はいずれも不変のSendableな値（struct・actor・closure）のみで可変stateを持たないため
/// `@unchecked Sendable`は安全。
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let store: WatchInboxStore
    private let intake: WatchIntakeQueue
    private let onReceipt: @Sendable (WatchChunkReceipt, String) -> Void
    private let onObs: @Sendable ([WatchObsRecord], String) -> Void
    /// 合図で起こされた時に呼ばれる。background taskを取り終えてから受領時刻（ms）を返す
    private let onWake: @Sendable @MainActor (WatchWakeMessage) -> Int64

    init(
        store: WatchInboxStore,
        intake: WatchIntakeQueue,
        onReceipt: @escaping @Sendable (WatchChunkReceipt, String) -> Void,
        onObs: @escaping @Sendable ([WatchObsRecord], String) -> Void,
        onWake: @escaping @Sendable @MainActor (WatchWakeMessage) -> Int64
    ) {
        self.store = store
        self.intake = intake
        self.onReceipt = onReceipt
        self.onObs = onObs
        self.onWake = onWake
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Diag.log("WatchSessionDelegate: activation failed: \(error)")
        }
    }

    /// iPhoneが複数Watchとのペアリング切り替え中などで一時的に呼ばれる。再開時は通常のcallbackが
    /// 続くので何もしない。
    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 別のWatchへペアリング先が切り替わった合図。このprocess内の`WCSession.default`を
    /// 引き続き使うため、Appleのドキュメント通り再度activateする。
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Watchの合図（`WatchWakeMessage`）。背面のappをこのcallbackで起こす。
    /// background taskを取ってから返事する（返事の前にsuspendされないため）。
    /// 合図として読めない辞書には空で返す
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let wake = WatchWakeMessage(message: message) else {
            replyHandler([:])
            return
        }
        let reply = ReplyBox(replyHandler)
        let onWake = self.onWake
        Task { @MainActor in
            let receivedAtMS = onWake(wake)
            reply.send(WatchWakeReply(receivedAtMS: receivedAtMS).message)
        }
    }

    /// 返事を求めない合図も同じ処理で受ける
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let wake = WatchWakeMessage(message: message) else { return }
        let onWake = self.onWake
        Task { @MainActor in
            _ = onWake(wake)
        }
    }

    /// `file.fileURL`はこのcallback内でしか有効でないため、callbackの中で同期的に、音声・sidecar・
    /// 受領記録を書いてから返る。そのあと列へ積む。処理の前にappが落ちても、次の起動・前面化・合図で
    /// 受け取り箱から回収される。metadataが読めない場合は今まで通り捨てる（再送する側の材料が無く復旧不能なため）。
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileMetadata: [String: Any] = file.metadata ?? [:]
        if WatchTransferKind.of(fileMetadata) == .obs {
            saveObsFile(file, metadata: fileMetadata)
            return
        }
        guard let meta = WatchChunkMetadata(metadata: fileMetadata) else {
            Diag.log("WatchSessionDelegate: received file with missing/invalid metadata; discarding")
            return
        }
        let nowMS = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let entry: WatchInboxEntry
        do {
            entry = try store.save(audioFrom: file.fileURL, metadata: meta, receivedAtMS: nowMS)
        } catch {
            Diag.log("WatchSessionDelegate: failed to save received file: \(error)")
            return
        }
        let receipt = WatchChunkReceipt(metadata: meta, receivedAtMS: nowMS)
        appendReceipt(receipt)
        RelayTrace.record(.fileReceived, device: meta.device, session: meta.session, index: meta.index)
        intake.submit(entry)
        onReceipt(receipt, meta.deviceName)
    }

    /// `<Documents>/watch-obs`。devicectlで取り出せるようDocuments配下に置く。無ければ作る
    static func watchObsDirectory() -> URL {
        let base: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory: URL = base.appendingPathComponent("watch-obs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `device`はWatch由来の文字列なので、directoryの外へ出る名前は受け付けない
    private static func isPlainFileName(_ fileName: String) -> Bool {
        fileName == (fileName as NSString).lastPathComponent && fileName != "." && fileName != ".."
    }

    /// `Documents/watch-obs/receipts-<device>.jsonl`へ受領記録を1行足す。書けなくても小片の保存は続ける
    private func appendReceipt(_ receipt: WatchChunkReceipt) {
        let fileName = "receipts-\(receipt.device).jsonl"
        guard Self.isPlainFileName(fileName) else {
            Diag.log("WatchSessionDelegate: receipt file name is not a plain file name; skipping receipt")
            return
        }
        guard let line = try? receipt.encodedLine() else { return }
        let url = Self.watchObsDirectory().appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            Diag.log("WatchSessionDelegate: failed to append receipt: \(error)")
        }
    }

    /// Watchの記録ファイルをcallbackの中で同期的に保存する（戻るとfile.fileURLが消えるため）。
    /// 再送で同じファイルが届くので、同名があれば消してからコピーして冪等にする。
    /// metadataが読めなければ1行logして捨てる。保存できたら中身を読んで`onObs`へ渡す。
    private func saveObsFile(_ file: WCSessionFile, metadata: [String: Any]) {
        guard let meta = WatchObsFileMetadata(metadata: metadata) else {
            Diag.log("WatchSessionDelegate: received obs file with missing/invalid metadata; discarding")
            return
        }
        let fileName: String = meta.fileName
        guard Self.isPlainFileName(fileName) else {
            Diag.log("WatchSessionDelegate: obs file name is not a plain file name; discarding")
            return
        }
        let destination: URL = Self.watchObsDirectory().appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
        } catch {
            Diag.log("WatchSessionDelegate: failed to save obs file \(fileName): \(error)")
            return
        }
        guard let text = try? String(contentsOf: destination, encoding: .utf8) else { return }
        let records = WatchObsRecord.decodeLines(text)
        if !records.isEmpty { onObs(records, meta.device) }
    }
}

// MARK: - WatchRelay

/// Watch由来の20秒小片を受け取り箱から1件ずつ受け取り（`WatchIntakeQueue`が1本の列で渡す）、
/// Watch sessionごとに専用の`Transcriber`streamへ流して`Segment(platform: .watchos, source: .watch)`を生成する。
///
/// 二重に文字起こししないため、sessionごとの処理済みindexを`WatchSessionLedger`に永続する。
/// streamの起点はsession文字列（Watchの録音の開始ms）から決め、最初に届いた小片にはしない。
/// 並べ替えは件数でなく保留の古さ（2分）で飛ばし、飛ばした小片は後から1回きりのTranscriberで拾う。
///
/// 並行性: `handle`は列の1本のTaskから1件ずつ呼ばれるので再入しない。idleのloopだけが別に動く。
@available(iOS 26, *)
actor WatchRelay: WatchChunkFeeding {
    /// Watch 1 session分の受信状態。actorの外へ出ることは無いのでSendable適合は不要
    private final class WatchStream {
        var sequencer: WatchChunkSequencer
        var transcriber: Transcriber
        /// `transcriber`の起点（piece時刻 = 起点 + 音声内の時刻）。30分ごとの作り直しで変わる
        var transcriberOriginMS: Int64
        var transcriberCreatedAt = Date()
        var converter: AudioConverter?
        var converterSourceFormat: AVAudioFormat?
        var pieceTask: Task<Void, Never>?
        var lastChunkAt = Date()
        var seq = 0
        /// このstreamを作るきっかけになった小片のmetadata。device/deviceName/owner用
        let firstMeta: WatchChunkMetadata
        /// 順序整え待ちの小片の、indexごとの受け取り箱の1件
        var heldEntries: [Int: WatchInboxEntry] = [:]
        /// `finishStream`の途中（最後の小片の処理から再入して二重に閉じないため）
        var isFinishing = false

        init(
            sequencer: WatchChunkSequencer, transcriber: Transcriber, transcriberOriginMS: Int64,
            firstMeta: WatchChunkMetadata
        ) {
            self.sequencer = sequencer
            self.transcriber = transcriber
            self.transcriberOriginMS = transcriberOriginMS
            self.firstMeta = firstMeta
        }
    }

    private static let idleCheckInterval: Duration = .seconds(15)
    /// 最後の小片からこの秒数届かなければstreamを終わらせる
    private static let idleTimeoutSeconds: TimeInterval = 60
    /// 保留の小片をこの時間待っても欠けたindexが届かなければ飛ばす
    private static let maxPendingAgeMS: Int64 = 120_000
    /// Transcriberをこの秒数ごとに作り直す（feedの時刻が大きくなりすぎないように）
    private static let transcriberLifetimeSeconds: TimeInterval = 30 * 60

    private let locale: Locale
    private let store: WatchInboxStore
    private let ledgerURL: URL
    private let onSegment: @Sendable (Segment) async -> Void
    private let onStreamCount: @Sendable (Int) -> Void
    private let onChunkFed: @Sendable (WatchChunkMetadata) -> Void
    private let onInboxChange: @Sendable () -> Void

    /// `handle`・保留の流し・streamの終了を1本の連鎖にする。actorは`await`の間に別の呼び出しが入るので、
    /// idleのloopや背面の終了処理と、列からの`handle`が重ならないようにする
    private let gate = AsyncGate()
    private var ledger: WatchSessionLedger
    /// feed済みでstreamを閉じるまで受け取り箱に残す音声
    private var fedHold = WatchFedAudioHold()
    private var streams: [String: WatchStream] = [:]
    /// session生成中（Transcriber起動待ち）のTask。完了したら`buildStream`が`streams`へ登録し、ここから消す。
    /// `WatchStream`は可変なclassでSendableでないため、Taskの結果としてactor外へ出さない
    private var creating: [String: Task<Void, Never>] = [:]
    private var idleTask: Task<Void, Never>?
    /// 受信の列の未処理件数。`attach(backlog:)`で渡される（列は`self`をfeederに作るので後付け）
    private var backlog: @Sendable () -> Int = { 0 }

    /// - Parameters:
    ///   - onSegment: final pieceごとに呼ばれる。Watch streamの1つのpieceTask内で順に
    ///     `await`されるため、この呼び出し自体をawaitで待ちきる実装にすることで、
    ///     Segmentの生成順序（=outboxへのenqueue順序）が保たれる。
    ///   - onStreamCount: 現在アクティブなWatch stream数が変わるたびに呼ばれる（UI表示用）
    ///   - onChunkFed: 小片をTranscriberへfeedできた時（計測の記録と、起きている時間の延長用）
    ///   - onInboxChange: 受け取り箱の1件を消した・試行を数えた時（未処理の件数の数え直し用）
    init(
        locale: Locale,
        store: WatchInboxStore,
        ledgerURL: URL,
        onSegment: @escaping @Sendable (Segment) async -> Void,
        onStreamCount: @escaping @Sendable (Int) -> Void = { _ in },
        onChunkFed: @escaping @Sendable (WatchChunkMetadata) -> Void = { _ in },
        onInboxChange: @escaping @Sendable () -> Void = {}
    ) {
        self.locale = locale
        self.store = store
        self.ledgerURL = ledgerURL
        self.onSegment = onSegment
        self.onStreamCount = onStreamCount
        self.onChunkFed = onChunkFed
        self.onInboxChange = onInboxChange
        if let data = try? Data(contentsOf: ledgerURL),
            let loaded = try? JSONDecoder().decode(WatchSessionLedger.self, from: data)
        {
            ledger = loaded
        } else {
            ledger = WatchSessionLedger()
        }
    }

    func attach(backlog: @escaping @Sendable () -> Int) {
        self.backlog = backlog
    }

    /// 台帳の30日より古いsessionを消す（保持期間）
    func pruneLedger(olderThanMS: Int64) {
        ledger.prune(olderThanMS: olderThanMS)
        saveLedger()
    }

    // MARK: - WatchChunkFeeding

    /// 受け取り箱の1件を処理する。成功すれば音声とsidecarを消し、失敗すれば`attempts`を数えて残す
    func handle(_ entry: WatchInboxEntry) async {
        await gate.run { await self.handleLocked(entry) }
    }

    private func handleLocked(_ entry: WatchInboxEntry) async {
        ensureIdleLoop()
        // 音声が無い = 別の経路で処理済み。残ったsidecarだけ片付ける
        guard FileManager.default.fileExists(atPath: store.audioURL(id: entry.id).path) else {
            store.remove(id: entry.id)
            onInboxChange()
            return
        }
        guard let meta = entry.metadata else {
            logError("inbox entry \(entry.id) has unreadable metadata; discarding")
            store.remove(id: entry.id)
            onInboxChange()
            return
        }
        if ledger.isProcessed(session: meta.session, index: meta.index) {
            store.remove(id: entry.id)
            onInboxChange()
            return
        }
        // Transcriberを起動できないのは環境の事情（背面など）なので、試行に数えず受け取り箱に残す。
        // 次の合図か前面化の`recover`で試し直す
        guard let stream = await streamFor(meta: meta) else { return }
        // feedを`await`している間にidleで閉じられないよう、最初に更新する
        stream.lastChunkAt = Date()

        // 飛ばした後で届いた小片は、streamとは別の1回きりのTranscriberで拾う
        if meta.index < stream.sequencer.nextIndex {
            await processLate(entry: entry, meta: meta, stream: stream)
            return
        }
        if let held = stream.heldEntries[meta.index], held.id != entry.id {
            // 再送で同じindexが別の受信として届いた。先に保留している方を使う
            store.remove(id: entry.id)
            onInboxChange()
            return
        }

        stream.heldEntries[meta.index] = entry
        let result = stream.sequencer.accept(meta, atMS: entry.receivedAtMS)
        await release(result, stream: stream)
        stream.lastChunkAt = Date()
    }

    /// 全streamを閉じる（app終了時と、背面のbackground taskを終える前）。
    /// 閉じると、analyzerに残った末尾の音声が確定して出る
    func finishAll() async {
        await gate.run {
            self.idleTask?.cancel()
            self.idleTask = nil
            for session in Array(self.streams.keys) {
                await self.finishStream(session: session)
            }
        }
    }

    // MARK: - Stream lookup / creation

    /// `meta.session`のstreamを返す。無ければ作る。
    ///
    /// `Transcriber(locale:origin:)`のinitと`start()`はどちらも`await`を要する非同期処理。
    /// idleのloopなど別のTaskが同じ新規sessionを同時に作ると二重に作られてしまうので、
    /// 生成中はTaskとして`creating`にキャッシュし、後続の呼び出しはそのTaskの完了を待つだけにする
    /// （`Task{}`の生成自体はawaitを含まないので、`creating`への書き込みは必ず最初のawaitより前に完了する）。
    private func streamFor(meta: WatchChunkMetadata) async -> WatchStream? {
        if let existing = streams[meta.session] {
            return existing
        }

        let task: Task<Void, Never>
        if let inFlight = creating[meta.session] {
            task = inFlight
        } else {
            let newTask = Task { await self.buildStream(meta: meta) }
            creating[meta.session] = newTask
            task = newTask
        }
        await task.value
        return streams[meta.session]
    }

    /// Transcriberを起動して`streams[meta.session]`へ登録する。失敗はlogして登録しない。
    /// 起点はsession文字列（Watchの録音の開始ms）。読めなければ小片の`startAtMS`。
    /// sequencerは台帳の続きから始める
    private func buildStream(meta: WatchChunkMetadata) async {
        defer { creating[meta.session] = nil }
        do {
            let originMS = ledger.streamOriginMS(session: meta.session, firstChunkStartAtMS: meta.startAtMS)
            let (transcriber, pieceTask) = try await startTranscriber(originMS: originMS, session: meta.session)
            let sequencer = WatchChunkSequencer(
                maxPending: 3, maxPendingAgeMS: Self.maxPendingAgeMS,
                startingAt: ledger.nextIndex(session: meta.session))
            let stream = WatchStream(
                sequencer: sequencer, transcriber: transcriber, transcriberOriginMS: originMS, firstMeta: meta)
            stream.pieceTask = pieceTask
            streams[meta.session] = stream
            onStreamCount(streams.count)
        } catch {
            logError("failed to start transcriber for session \(meta.session): \(error)")
        }
    }

    private func startTranscriber(originMS: Int64, session: String) async throws -> (Transcriber, Task<Void, Never>) {
        let origin = Date(timeIntervalSince1970: Double(originMS) / 1000)
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        let pieces = try await transcriber.start()
        let pieceTask = Task { [weak self] in
            for await piece in pieces where piece.isFinal {
                guard !piece.text.isEmpty else { continue }
                guard let self else { return }
                await self.emit(piece: piece, session: session)
            }
        }
        return (transcriber, pieceTask)
    }

    private func emit(piece: TranscriptPiece, session: String) async {
        guard let stream = streams[session] else { return }
        stream.seq += 1
        await onSegment(Self.segment(from: piece, session: session, seq: stream.seq, meta: stream.firstMeta))
    }

    private static func segment(from piece: TranscriptPiece, session: String, seq: Int, meta: WatchChunkMetadata)
        -> Segment
    {
        Segment(
            id: UUID(),
            session: session,
            seq: seq,
            device: meta.device,
            deviceName: meta.deviceName,
            owner: meta.owner,
            platform: .watchos,
            source: .watch,
            input: InputDevice(name: "Apple Watch", uid: meta.device, spatial: false),
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence
        )
    }

    // MARK: - Chunk processing

    /// sequencerが流してよいとした小片を順にfeedする。飛ばしたindexは台帳の欠番として残り、後から届けば拾う
    private func release(
        _ result: (ready: [WatchChunkMetadata], skipped: [Int]), stream: WatchStream
    ) async {
        if !result.skipped.isEmpty {
            logError("session \(stream.firstMeta.session): skipped indexes \(result.skipped)")
        }
        for chunk in result.ready {
            guard let entry = stream.heldEntries.removeValue(forKey: chunk.index) else { continue }
            await process(chunk: chunk, entry: entry, stream: stream)
        }
    }

    /// 受け取り箱の1件をPCMへ読み出し、Transcriberのinput formatへ変換してfeedする。
    /// 成功で台帳に記録して音声とsidecarを消し、失敗で`attempts`を数えて残す
    private func process(chunk: WatchChunkMetadata, entry: WatchInboxEntry, stream: WatchStream) async {
        do {
            let fileURL = store.audioURL(id: entry.id)
            let file = try AVAudioFile(forReading: fileURL)
            guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max) else {
                logError("chunk \(chunk.session)/\(chunk.index) is empty or too large; discarded")
                markDone(chunk: chunk, entry: entry)
                return
            }
            guard
                let raw = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else {
                logError("chunk \(chunk.session)/\(chunk.index): failed to allocate PCM buffer")
                failAttempt(entry)
                return
            }
            try file.read(into: raw)

            do {
                try await rotateTranscriberIfNeeded(stream: stream, nextChunk: chunk)
            } catch {
                // Transcriberを作り直せないのは環境の事情。試行に数えず、受け取り箱に残して後で試し直す
                logError("transcriber rotation failed: \(error)")
                return
            }

            // 小片ごとにprocessingFormatが変われば変換器を作り直す
            if stream.converter == nil || stream.converterSourceFormat != file.processingFormat {
                stream.converter = try AudioConverter(
                    from: file.processingFormat, to: stream.transcriber.inputFormat)
                stream.converterSourceFormat = file.processingFormat
            }
            guard let converter = stream.converter else { return }
            let converted = try converter.convert(raw)

            let offsetMS = chunk.startAtMS - stream.transcriberOriginMS
            if offsetMS < 0 {
                // 起点はsession文字列から決めるので、順に流す限りここには来ないはず
                logError(
                    "chunk \(chunk.session)/\(chunk.index): startAtMS precedes the transcriber origin by \(-offsetMS)ms; clamping to 0"
                )
            }
            let sampleTime = AVAudioFramePosition(
                (max(0, Double(offsetMS)) / 1000.0 * stream.transcriber.inputFormat.sampleRate).rounded())
            await stream.transcriber.feed(converted, at: sampleTime)
            stream.lastChunkAt = Date()
            onChunkFed(chunk)
            markDone(chunk: chunk, entry: entry, holdAudioUntilStreamFinished: true)
            if chunk.isFinal == true {
                await finishStream(session: chunk.session)
            }
        } catch {
            logError("chunk \(chunk.session)/\(chunk.index): processing failed: \(error)")
            failAttempt(entry)
        }
    }

    /// 飛ばした後で届いた小片を、そのsessionのstreamとは別の1回きりのTranscriberで文字起こしし、
    /// `startAtMS - origin`の位置のsegにする（捨てない）
    private func processLate(entry: WatchInboxEntry, meta: WatchChunkMetadata, stream: WatchStream) async {
        do {
            let file = try AVAudioFile(forReading: store.audioURL(id: entry.id))
            guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
                let raw = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else {
                markDone(chunk: meta, entry: entry)
                return
            }
            try file.read(into: raw)

            // 1回きりなので、起点はこの小片の先頭にして位置は0から
            let origin = Date(timeIntervalSince1970: Double(meta.startAtMS) / 1000)
            let transcriber: Transcriber
            let pieces: AsyncStream<TranscriptPiece>
            do {
                transcriber = try await Transcriber(locale: locale, origin: origin)
                pieces = try await transcriber.start()
            } catch {
                // 環境の事情。試行に数えず受け取り箱に残す
                logError("late chunk \(meta.session)/\(meta.index): transcriber start failed: \(error)")
                return
            }
            let collector = Task { () -> [TranscriptPiece] in
                var finals: [TranscriptPiece] = []
                for await piece in pieces where piece.isFinal && !piece.text.isEmpty {
                    finals.append(piece)
                }
                return finals
            }
            let converter = try AudioConverter(from: file.processingFormat, to: transcriber.inputFormat)
            let converted = try converter.convert(raw)
            await transcriber.feed(converted, at: 0)
            do {
                try await transcriber.finish()
            } catch {
                // 環境の事情。試行に数えず受け取り箱に残す
                collector.cancel()
                logError("late chunk \(meta.session)/\(meta.index): transcriber finish failed: \(error)")
                return
            }
            let finals = await collector.value
            for piece in finals {
                await onSegment(Self.segment(from: piece, session: meta.session, seq: 0, meta: stream.firstMeta))
            }
            onChunkFed(meta)
            markDone(chunk: meta, entry: entry)
        } catch {
            logError("late chunk \(meta.session)/\(meta.index): processing failed: \(error)")
            failAttempt(entry)
        }
    }

    /// `transcriberLifetimeSeconds`を過ぎていたら、Transcriberを次の小片の先頭を起点に作り直す
    private func rotateTranscriberIfNeeded(stream: WatchStream, nextChunk: WatchChunkMetadata) async throws {
        guard Date().timeIntervalSince(stream.transcriberCreatedAt) >= Self.transcriberLifetimeSeconds else { return }
        let old = stream.transcriber
        let oldTask = stream.pieceTask
        try? await old.finish()
        await oldTask?.value
        let (transcriber, pieceTask) = try await startTranscriber(
            originMS: nextChunk.startAtMS, session: nextChunk.session)
        stream.transcriber = transcriber
        stream.pieceTask = pieceTask
        stream.transcriberOriginMS = nextChunk.startAtMS
        stream.transcriberCreatedAt = Date()
        stream.converter = nil
        stream.converterSourceFormat = nil
    }

    /// 台帳には処理済みと記録する。`holdAudioUntilStreamFinished`の時は、analyzerの中に末尾が残っている間
    /// 音声を消さず、streamを閉じ終えてから消す（途中でappが落とされても音声が受け取り箱に残る。
    /// 台帳は処理済みなので、次の回収では二重にfeedされず片付く）
    private func markDone(
        chunk: WatchChunkMetadata, entry: WatchInboxEntry, holdAudioUntilStreamFinished: Bool = false
    ) {
        ledger.markProcessed(
            session: chunk.session, index: chunk.index, atMS: Self.nowMS(),
            endAtMS: chunk.startAtMS + (chunk.durationMS ?? 0))
        saveLedger()
        if holdAudioUntilStreamFinished {
            fedHold.hold(session: chunk.session, id: entry.id)
        } else {
            store.remove(id: entry.id)
        }
        onInboxChange()
    }

    private func failAttempt(_ entry: WatchInboxEntry) {
        store.markAttempt(id: entry.id)
        onInboxChange()
    }

    private func saveLedger() {
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        } catch {
            logError("failed to save ledger: \(error)")
        }
    }

    private static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Idle finishing

    /// idle監視は最初の小片が届いてから始める（非asyncなactor initでは`self`を捕捉するTaskを作れないため）。
    /// `finishAll()`で止めた後に小片が来れば再び起動する
    private func ensureIdleLoop() {
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            await self?.runIdleLoop()
        }
    }

    private func runIdleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.idleCheckInterval)
            if Task.isCancelled { break }
            await gate.run {
                await self.tickStreams()
                await self.finishIdleStreams()
            }
        }
    }

    /// 新しい小片が来なくても古い保留を流す。受信の列に積まれたままの小片を、
    /// まだ届いていないものとして飛ばさないよう、列が空の時だけ行う
    private func tickStreams() async {
        guard backlog() == 0 else { return }
        let now = Self.nowMS()
        for stream in Array(streams.values) {
            let result = stream.sequencer.tick(atMS: now)
            await release(result, stream: stream)
        }
    }

    private func finishIdleStreams() async {
        // 列に積まれた小片がある間は閉じない（回収した小片をこれから同じstreamへ流す）
        guard backlog() == 0 else { return }
        let now = Date()
        let idleSessions = streams.filter {
            $0.value.heldEntries.isEmpty && now.timeIntervalSince($0.value.lastChunkAt) > Self.idleTimeoutSeconds
        }.map(\.key)
        for session in idleSessions {
            await finishStream(session: session)
        }
    }

    /// 保留中の小片を`flush()`で全部feedしてから`transcriber.finish()`し、pieceTaskの完了を
    /// 待ってからstreamを取り除き、台帳にsessionの終わりを記録する。
    ///
    /// `streams`から取り除くのは必ず`pieceTask`完了の後にする: `emit(piece:session:)`は
    /// `streams[session]`を引いて`seq`カウンタとfirstMetaを取るため、`transcriber.finish()`が
    /// 流す最後のfinal piece（finalize経由のtail）が来る前にここでstreamを消してしまうと、
    /// そのpieceが`emit`内で黙って捨てられてしまう。
    private func finishStream(session: String) async {
        guard let stream = streams[session], !stream.isFinishing else { return }
        stream.isFinishing = true

        for chunk in stream.sequencer.flush() {
            guard let entry = stream.heldEntries.removeValue(forKey: chunk.index) else { continue }
            await process(chunk: chunk, entry: entry, stream: stream)
        }

        var finishSucceeded = true
        do {
            try await stream.transcriber.finish()
        } catch {
            logError("session \(session): transcriber finish failed: \(error)")
            finishSucceeded = false
        }
        await stream.pieceTask?.value

        streams.removeValue(forKey: session)
        ledger.markFinished(session: session, atMS: Self.nowMS())
        saveLedger()
        // 末尾が確定して出た後で、feed済みの音声を消す
        for id in fedHold.release(session: session, finishSucceeded: finishSucceeded) {
            store.remove(id: id)
        }
        onInboxChange()
        onStreamCount(streams.count)
    }

    private func logError(_ message: String) {
        Diag.log("WatchRelay: \(message)")
    }
}
