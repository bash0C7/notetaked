import AVFoundation
import Foundation
import NotetakeCore
import WatchConnectivity

// MARK: - WatchSessionDelegate

/// WCSessionのdelegate。callbackはバックグラウンドの任意スレッド（WCSessionが内部で使う
/// 非公開のserial queue）から呼ばれ、`actor`にも`@MainActor`にも属さない普通の`NSObject`
/// subclassなので、各メソッドは`nonisolated`相当（isolationを持たない）として振る舞う。
/// 保持する状態は不変の`relay`（actor、Sendable）のみで可変stateを持たないため
/// `@unchecked Sendable`は安全。
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let relay: WatchRelay

    init(relay: WatchRelay) {
        self.relay = relay
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            FileHandle.standardError.write(
                Data("WatchSessionDelegate: activation failed: \(error)\n".utf8))
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

    /// `file.fileURL`はこのcallback内でしか有効でないため、まず同期的にアプリ管理下へコピーする。
    /// metadataが読めない場合はコピーを削除して終わる（再送する側の材料が無く復旧不能なため）。
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let destination = WatchRelay.inboxDirectory()
            .appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
        } catch {
            FileHandle.standardError.write(
                Data("WatchSessionDelegate: failed to copy received file: \(error)\n".utf8))
            return
        }
        guard let meta = WatchChunkMetadata(metadata: file.metadata ?? [:]) else {
            FileHandle.standardError.write(
                Data(
                    "WatchSessionDelegate: received file with missing/invalid metadata; discarding\n"
                        .utf8))
            try? FileManager.default.removeItem(at: destination)
            return
        }
        let relay = self.relay
        Task {
            await relay.receive(url: destination, meta: meta)
        }
    }
}

// MARK: - WatchRelay

/// Watch由来の20秒小片を受け取り、Watch sessionごとに専用の`Transcriber`streamへ流して
/// `Segment(platform: .watchos, source: .watch)`を生成する。
///
/// 並行性: `WatchSessionDelegate`（任意スレッド）は自前でファイルをコピーした後
/// `Task { await relay.receive(...) }`でこのactorへ処理を委ねる。同じsessionの小片が
/// ほぼ同時に複数`receive`されても、streamの生成（`Transcriber`の非同期init/start）を
/// 二重に走らせないよう`creating`に生成中のTaskをキャッシュし、後続の呼び出しはそれを
/// 待つ（詳細は`streamFor`のコメント）。
@available(iOS 26, *)
actor WatchRelay {
    /// Watch 1 session分の受信状態。actorの外へ出ることは無いのでSendable適合は不要
    private final class WatchStream {
        var sequencer = WatchChunkSequencer()
        let transcriber: Transcriber
        var converter: AudioConverter?
        let originMS: Int64
        var pieceTask: Task<Void, Never>?
        var lastChunkAt = Date()
        var seq = 0
        /// 最初にこのstreamを作るきっかけになった小片のmetadata。device/deviceName/owner用
        let firstMeta: WatchChunkMetadata
        /// 順序整え待ち・保留中の小片の、indexごとのファイルURL
        var pendingFiles: [Int: URL] = [:]

        init(transcriber: Transcriber, originMS: Int64, firstMeta: WatchChunkMetadata) {
            self.transcriber = transcriber
            self.originMS = originMS
            self.firstMeta = firstMeta
        }
    }

    private static let idleCheckInterval: Duration = .seconds(15)
    /// 最後の小片からこの秒数届かなければstreamを終わらせる
    private static let idleTimeoutSeconds: TimeInterval = 60

    private let locale: Locale
    private let onSegment: @Sendable (Segment) async -> Void
    private let onStreamCount: @Sendable (Int) -> Void

    private var streams: [String: WatchStream] = [:]
    /// session生成中（Transcriber起動待ち）のTask。完了したら`streams`へ移し空にする
    private var creating: [String: Task<WatchStream, Error>] = [:]
    private var idleTask: Task<Void, Never>?

    /// - Parameters:
    ///   - onSegment: final pieceごとに呼ばれる。Watch streamの1つのpieceTask内で順に
    ///     `await`されるため、この呼び出し自体をawaitで待ちきる実装にすることで、
    ///     Segmentの生成順序（=outboxへのenqueue順序）が保たれる。
    ///   - onStreamCount: 現在アクティブなWatch stream数が変わるたびに呼ばれる（UI表示用）
    init(
        locale: Locale,
        onSegment: @escaping @Sendable (Segment) async -> Void,
        onStreamCount: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.locale = locale
        self.onSegment = onSegment
        self.onStreamCount = onStreamCount
        idleTask = Task { [weak self] in
            await self?.runIdleLoop()
        }
    }

    /// `<Application Support>/Notetake/watch-inbox`。`WatchSessionDelegate`（actor外）からも
    /// 同期的に呼べるようstatic。
    static func inboxDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Notetake/watch-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `WatchSessionDelegate`から呼ばれる。`url`の所有権を引き取り、最終的に必ず削除する
    /// （streamの生成に失敗した場合も含む）。
    func receive(url: URL, meta: WatchChunkMetadata) async {
        guard let stream = await streamFor(meta: meta, orphanFileIfFailed: url) else { return }

        // `WatchChunkSequencer`が内部で「すでに追い越されたindex」として即座に捨てる小片を
        // ここで先に弾く。先にpendingFilesへ入れてからaccept()に渡すと、この種の小片は
        // accept()の戻り値にもflush()にも二度と現れずファイルが残り続けてしまうため。
        guard meta.index >= stream.sequencer.nextIndex else {
            logError("chunk \(meta.session)/\(meta.index) arrived after being skipped; discarding")
            try? FileManager.default.removeItem(at: url)
            return
        }

        stream.pendingFiles[meta.index] = url
        let released = stream.sequencer.accept(meta)
        for chunk in released {
            guard let fileURL = stream.pendingFiles.removeValue(forKey: chunk.index) else { continue }
            await process(chunk: chunk, fileURL: fileURL, stream: stream)
        }
        stream.lastChunkAt = Date()
    }

    /// 全streamを強制終了する（app終了時など）。
    func finishAll() async {
        idleTask?.cancel()
        idleTask = nil
        for session in Array(streams.keys) {
            await finishStream(session: session)
        }
    }

    // MARK: - Stream lookup / creation

    /// `meta.session`のstreamを返す。無ければ作る。
    ///
    /// `Transcriber(locale:origin:)`のinitと`start()`はどちらも`await`を要する非同期処理。
    /// この関数自体が`await`で中断している間、同じactorの別の`receive`呼び出し（同じ新規
    /// sessionの別小片）が先に進んでしまうと、streamが二重に作られてしまう（片方は破棄され
    /// Transcriberとpieceを消費するTaskがリークする）。これを避けるため、
    /// 生成中はTaskとして`creating`にキャッシュし、後続の呼び出しはそのTaskの完了を
    /// 待つだけにする（`Task{}`の生成自体はawaitを含まないので、`creating`への書き込みは
    /// 必ず最初のawaitより前に完了する）。
    private func streamFor(meta: WatchChunkMetadata, orphanFileIfFailed url: URL) async -> WatchStream? {
        if let existing = streams[meta.session] {
            return existing
        }

        let task: Task<WatchStream, Error>
        if let inFlight = creating[meta.session] {
            task = inFlight
        } else {
            let newTask = Task { try await self.buildStream(meta: meta) }
            creating[meta.session] = newTask
            task = newTask
        }

        do {
            let stream = try await task.value
            // task.valueを待っていた複数の呼び出しが順にここへ戻ってくる可能性があるため、
            // 二重登録・二重のonStreamCount通知を避ける
            if streams[meta.session] == nil {
                streams[meta.session] = stream
                creating[meta.session] = nil
                onStreamCount(streams.count)
            }
            return stream
        } catch {
            creating[meta.session] = nil
            logError("failed to start transcriber for session \(meta.session): \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// origin(先頭小片のstartAtMS)でTranscriberを起動し、final pieceを消費するTaskを繋いだ
    /// `WatchStream`を作る。`self`への参照はpieceTask経由のみ（weak、`emit`はactor-isolated）。
    private func buildStream(meta: WatchChunkMetadata) async throws -> WatchStream {
        let originMS = meta.startAtMS
        let origin = Date(timeIntervalSince1970: Double(originMS) / 1000)
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        let pieces = try await transcriber.start()

        let stream = WatchStream(transcriber: transcriber, originMS: originMS, firstMeta: meta)
        let session = meta.session
        stream.pieceTask = Task { [weak self] in
            for await piece in pieces where piece.isFinal {
                guard !piece.text.isEmpty else { continue }
                guard let self else { return }
                await self.emit(piece: piece, session: session)
            }
        }
        return stream
    }

    private func emit(piece: TranscriptPiece, session: String) async {
        guard let stream = streams[session] else { return }
        stream.seq += 1
        let meta = stream.firstMeta
        let segment = Segment(
            id: UUID(),
            session: session,
            seq: stream.seq,
            device: meta.device,
            deviceName: meta.deviceName,
            owner: meta.owner,
            platform: .watchos,
            source: .watch,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence
        )
        await onSegment(segment)
    }

    // MARK: - Chunk processing

    /// AACの小片ファイルをPCMへ読み出し、Transcriberのinput formatへ変換してfeedする。
    /// 成功・失敗にかかわらずファイルは必ず削除する（再送する仕組みが無いため、失敗した
    /// 小片はログに残して諦める）。
    private func process(chunk: WatchChunkMetadata, fileURL: URL, stream: WatchStream) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            let file = try AVAudioFile(forReading: fileURL)
            guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max) else {
                logError("chunk \(chunk.session)/\(chunk.index) is empty or too large; skipped")
                return
            }
            guard
                let raw = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else {
                logError("chunk \(chunk.session)/\(chunk.index): failed to allocate PCM buffer")
                return
            }
            try file.read(into: raw)

            // converterはstreamの最初に処理できた小片のformatから遅延生成する（AACファイルの
            // processingFormatはsessionを通じて一定である前提。異なれば以後のconvertが失敗し
            // ログに出る）。
            if stream.converter == nil {
                stream.converter = try AudioConverter(
                    from: file.processingFormat, to: stream.transcriber.inputFormat)
            }
            guard let converter = stream.converter else { return }
            let converted = try converter.convert(raw)

            let offsetMS = chunk.startAtMS - stream.originMS
            if offsetMS < 0 {
                // streamのoriginは「このsessionで最初にreceive()されたmeta」のstartAtMSであり、
                // 必ずしもindex 0とは限らない（reorderingでindexの大きい小片が先に届いた場合）。
                // その場合、あとから届くより小さいindexのstartAtMSがoriginより前になりうるので
                // 0へclampしてfeedする（本来はここで数十〜数百ms程度のずれに収まる想定）。
                logError(
                    "chunk \(chunk.session)/\(chunk.index): startAtMS precedes stream origin by \(-offsetMS)ms; clamping to 0"
                )
            }
            let sampleTime = AVAudioFramePosition(
                (max(0, Double(offsetMS)) / 1000.0 * stream.transcriber.inputFormat.sampleRate)
                    .rounded())
            await stream.transcriber.feed(converted, at: sampleTime)
            stream.lastChunkAt = Date()
        } catch {
            logError("chunk \(chunk.session)/\(chunk.index): processing failed: \(error)")
        }
    }

    // MARK: - Idle finishing

    private func runIdleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.idleCheckInterval)
            if Task.isCancelled { break }
            await finishIdleStreams()
        }
    }

    private func finishIdleStreams() async {
        let now = Date()
        let idleSessions = streams.filter { now.timeIntervalSince($0.value.lastChunkAt) > Self.idleTimeoutSeconds }
            .map(\.key)
        for session in idleSessions {
            await finishStream(session: session)
        }
    }

    /// 保留中の小片を`flush()`で全部feedしてから`transcriber.finish()`し、pieceTaskの完了を
    /// 待ってからstreamを取り除く。
    ///
    /// `streams`から取り除くのは必ず`pieceTask`完了の後にする: `emit(piece:session:)`は
    /// `streams[session]`を引いて`seq`カウンタとfirstMetaを取るため、`transcriber.finish()`が
    /// 流す最後のfinal piece（finalize経由のtail）が来る前にここでstreamを消してしまうと、
    /// そのpieceが`emit`内で黙って捨てられてしまう。
    private func finishStream(session: String) async {
        guard let stream = streams[session] else { return }

        for chunk in stream.sequencer.flush() {
            guard let fileURL = stream.pendingFiles.removeValue(forKey: chunk.index) else { continue }
            await process(chunk: chunk, fileURL: fileURL, stream: stream)
        }
        // 想定外に拾えなかったファイルが残っていれば掃除する（ここに来る経路は無いはずだが保険）
        for url in stream.pendingFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        stream.pendingFiles.removeAll()

        try? await stream.transcriber.finish()
        await stream.pieceTask?.value

        streams.removeValue(forKey: session)
        onStreamCount(streams.count)
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write(Data("WatchRelay: \(message)\n".utf8))
    }
}
