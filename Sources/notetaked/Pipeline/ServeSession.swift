#if canImport(Speech)
import Foundation
import NotetakeCore

/// serveの収録の状態（出力ファイル、Reconciler、ライブの文字起こし、capture-daemonの状態）を持ち、
/// stdinのコマンド、文字起こしの結果、peerからの受信が競合しないよう1つのactorへ直列化する
@available(macOS 26, iOS 26, *)
actor ServeSession {
    enum SourceOption: String {
        case mic, system, both

        var sources: [(source: Source, owner: (_ configuredOwner: String) -> String)] {
            switch self {
            case .mic:
                return [(.mic, { $0 })]
            case .system:
                return [(.system, { _ in OwnerLabel.remote })]
            case .both:
                return [(.mic, { $0 }), (.system, { _ in OwnerLabel.remote })]
            }
        }
    }

    private struct LiveStream {
        let source: Source
        let transcription: LiveTranscription
        let consumer: Task<Void, Never>
    }

    /// 状態を整える前の、始めたばかりのライブの文字起こし
    private struct StartedTranscription {
        let source: Source
        let owner: String
        let transcription: LiveTranscription
        let outputs: AsyncStream<LiveTranscription.Output>
    }

    /// peer接続1本ぶんの状態（hello情報・clock offset・ping往復管理）
    private struct PeerState {
        var hello: HelloMessage?
        var offsetSamples: [ClockOffsetSample] = []
        var pingID: Int = 0
        var pingSent: [Int: Int64] = [:]
        /// 接続直後の即時5回 + 以後60秒ごとのping送信を担うTask。切断時にcancelする
        var pingTask: Task<Void, Never>?
    }

    private let outputDirectory: URL
    private let owner: String
    private let sourceOption: SourceOption
    private let locale: Locale
    private let control: StdioControl
    private let device: DeviceIdentity
    /// micを固定したい入力機器のUID。nilなら既定の入力を使う
    private let inputDeviceUID: String?

    private let archive: SessionArchive
    private let finalizer: FinalizeQueue
    /// 収録中の収録のprefix。収録していなければnil
    private var currentPrefix: String?
    private var reconciler = Reconciler()
    private var seq = 0
    private var live: [LiveStream] = []
    private var recording = false
    /// 直前に使ったprefix。同じ秒の中で開始と区切りが重なってもprefixが衝突しないよう、開始時刻をずらすのに使う
    private var lastPrefix: String?
    /// serveの寿命で1つ。収録ごとの記憶は`beginRecording`で消す
    private var captureWatcher = CaptureActualWatcher()
    /// 望む状態を停止へ書けなかった。書けるまで1秒ごとに書き直す
    private var desiredStopPending = false
    /// 直前に読めなかった実状態の失敗。同じ失敗はlogへ1度だけ出す
    private var lastActualReadError: String?
    private var captureStatuses: [CaptureStatus] = []
    /// capture-daemonが実状態で伝えるmicの入力機器
    private var micInput: InputDevice?
    private var captureWatchTask: Task<Void, Never>?

    // MARK: - peer (iPhone/Watch)

    private var peerListener: PeerListener?
    private var peerStates: [PeerConnectionID: PeerState] = [:]
    /// device単位の受信済み最大seq（`ReceivedCursor`のin-memory mirror）
    private var receivedCursors: [String: Int] = [:]
    private let receivedCursorStore = ReceivedCursor.default()
    /// 進行中の収録で既にDeviceRecordを書いたdevice id集合。新しいprefixで開始するたびリセットする
    private var recordedPeerDevices: Set<String> = []

    init(
        outputDirectory: URL, owner: String, sourceOption: SourceOption, locale: Locale,
        control: StdioControl, device: DeviceIdentity, archive: SessionArchive, finalizer: FinalizeQueue,
        inputDeviceUID: String? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.owner = owner
        self.sourceOption = sourceOption
        self.locale = locale
        self.control = control
        self.device = device
        self.archive = archive
        self.finalizer = finalizer
        self.inputDeviceUID = inputDeviceUID
    }

    /// serveが再起動する前から収録が続いていれば、同じ収録を引き継ぐ。収録中かどうかは望む状態のファイルで判断する。
    /// 再起動の間の音声はライブの表示には出ないが、生音声には残る
    func resumeIfRecording() async {
        let desired: CaptureDesiredState?
        do {
            desired = try JSONFile.read(CaptureDesiredState.self, from: CaptureStatePaths.captureDesiredURL)
        } catch {
            await control.send(.error("failed to read capture desired state: \(error)"))
            return
        }
        guard let recording = desired?.recording else { return }
        let records: [Record]
        do {
            // 電源断などで壊れたbyteがあっても、読める行で引き継ぐ
            records = try await archive.readRecords(prefix: recording.prefix, in: outputDirectory)
            try restoreSessionInfoIfMissing(sessionDirectory: URL(fileURLWithPath: recording.directory))
        } catch {
            await control.send(.error("failed to resume \(recording.prefix): \(error)"))
            await writeDesiredStopped()
            return
        }
        let restored = Reconciler.restore(from: records, device: device.id)
        await archive.begin(prefix: recording.prefix, in: outputDirectory)
        guard
            await beginLive(
                prefix: recording.prefix, sessionDirectory: URL(fileURLWithPath: recording.directory), startAtEnd: true,
                keepingCapture: false, reconciler: restored.reconciler, seq: restored.lastSeq)
        else {
            await writeDesiredStopped()
            return
        }
        await control.send(.status(statusEvent()))
        await control.send(.log("resumed \(recording.prefix)"))
    }

    /// 再起動の前に生音声のディレクトリが消えていても、段階2が出力先を辿れるよう`session.json`を書き直す
    private func restoreSessionInfoIfMissing(sessionDirectory: URL) throws {
        let url = CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try JSONFile.write(
            CaptureSessionInfo(
                outputDirectory: outputDirectory.path, device: device.id, deviceName: device.name, owner: owner),
            to: url)
    }

    func handle(_ command: Command) async {
        switch command {
        case .start:
            await start()
        case .stop:
            await stop()
        case .renameSpeaker(let id, let name):
            await renameSpeaker(id: id, name: name)
        case .rotate:
            await rotate()
        case .pairCode(let code):
            await setPairingCode(code)
        case .quit:
            await quit()
        }
    }

    // MARK: - start

    private func start() async {
        guard !recording else {
            await control.send(.error("already recording"))
            return
        }
        if await startNewRecording(keepingCapture: false) {
            await control.send(.status(statusEvent()))
        }
    }

    /// 新しい収録を始める。出力ファイルへ収録とMacの記録を書き、生音声ディレクトリへ`session.json`を書いてから、
    /// 望む状態でcapture-daemonへ書き込み先を伝え、ライブの文字起こしを始める
    /// `keepingCapture`は区切りの時だけtrue。取り込みの状態と入力機器を引き継ぎ、表示が途切れないようにする
    private func startNewRecording(keepingCapture: Bool) async -> Bool {
        var date = Date()
        while SessionStore.prefix(for: date, timeZone: .current) == lastPrefix {
            date.addTimeInterval(1)
        }
        let prefix = SessionStore.prefix(for: date, timeZone: .current)
        let sessionDirectory = CaptureSessionPaths.sessionDirectory(prefix: prefix)
        await archive.begin(prefix: prefix, in: outputDirectory)
        do {
            try await archive.appendLive(
                .session(SessionRecord(id: prefix, started: Self.ms(date), owner: owner)))
            try await archive.appendLive(
                .device(
                    DeviceRecord(
                        device: device.id, deviceName: device.name, owner: owner, platform: .mac, offsetMS: 0)))
            try JSONFile.write(
                CaptureSessionInfo(
                    outputDirectory: outputDirectory.path, device: device.id, deviceName: device.name,
                    owner: owner),
                to: CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory))
            // 停止の書き直しが、ここで書く収録中を上書きしないよう、書く直前に取り下げる
            desiredStopPending = false
            try JSONFile.write(
                desiredState(.init(prefix: prefix, directory: sessionDirectory.path)),
                to: CaptureStatePaths.captureDesiredURL)
        } catch {
            await archive.abandonCurrent()
            await control.send(.error("failed to start session: \(error)"))
            await writeDesiredStopped()
            return false
        }
        guard
            await beginLive(
                prefix: prefix, sessionDirectory: sessionDirectory, startAtEnd: false, keepingCapture: keepingCapture,
                reconciler: Reconciler(), seq: 0)
        else {
            await writeDesiredStopped()
            return false
        }
        return true
    }

    /// sourceごとにライブの文字起こしを始め、収録中の状態へ移る。失敗したら始めた分を止めて`false`を返す。
    /// 先に全sourceの文字起こしを始め、状態を整えてから結果の受け取りを始める。
    /// 受け取りが先に動くと、確定した発話を保存先が無いまま落とす
    private func beginLive(
        prefix: String, sessionDirectory: URL, startAtEnd: Bool, keepingCapture: Bool, reconciler: Reconciler,
        seq: Int
    ) async -> Bool {
        var started: [StartedTranscription] = []
        for (source, ownerFor) in sourceOption.sources {
            do {
                let transcription = try await LiveTranscription(
                    source: source, sessionDirectory: sessionDirectory, locale: locale, startAtEnd: startAtEnd)
                let outputs = try await transcription.start()
                started.append(
                    StartedTranscription(
                        source: source, owner: ownerFor(owner), transcription: transcription, outputs: outputs))
            } catch {
                for item in started {
                    await item.transcription.stop()
                }
                await archive.abandonCurrent()
                await control.send(.error("failed to start live transcription: \(error)"))
                return false
            }
        }
        currentPrefix = prefix
        self.reconciler = reconciler
        self.seq = seq
        recording = true
        lastPrefix = prefix
        recordedPeerDevices = []
        if !keepingCapture {
            captureStatuses = []
            micInput = nil
        }
        captureWatcher.beginRecording(keepingSnapshot: keepingCapture)
        live = started.map { item in
            let source = item.source
            let streamOwner = item.owner
            let outputs = item.outputs
            let consumer = Task { [weak self] in
                for await output in outputs {
                    await self?.handle(output, source: source, owner: streamOwner)
                }
            }
            return LiveStream(source: source, transcription: item.transcription, consumer: consumer)
        }
        ensureCaptureWatch()
        return true
    }

    // MARK: - live transcription

    private func handle(_ output: LiveTranscription.Output, source: Source, owner: String) async {
        switch output {
        case .volatile(let text):
            await control.send(.volatile(source: source, text: text))
        case .final(let piece):
            await handleFinal(piece, source: source, owner: owner)
        case .log(let message):
            await control.send(.log(message))
        case .error(let message):
            await control.send(.error(message))
        }
    }

    private func handleFinal(_ piece: LiveTranscription.Piece, source: Source, owner: String) async {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let currentPrefix else {
            await control.send(.log("収録していないため発話を保存できません: \(piece.text)"))
            return
        }
        seq += 1
        let segment = Segment(
            id: UUID(),
            session: currentPrefix,
            seq: seq,
            device: device.id,
            deviceName: device.name,
            owner: owner,
            platform: .mac,
            source: source,
            input: piece.input,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: piece.levelDBFS,
            clockOffsetMS: 0,
            receivedAt: Self.ms(Date()))
        do {
            try await archive.appendLive(.segment(segment))
        } catch {
            await control.send(.error("failed to append segment: \(error)"))
            return
        }
        for utterance in reconciler.apply(.segment(segment)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - capture-daemon

    private func desiredState(_ recording: CaptureDesiredState.Recording?) -> CaptureDesiredState {
        CaptureDesiredState(
            recording: recording, sources: sourceOption.sources.map(\.source), pinnedInputUID: inputDeviceUID)
    }

    /// capture-daemonへ取り込みを止めるよう伝える
    /// 書けなければ、書けるまで実状態を読む繰り返しで書き直す
    private func writeDesiredStopped() async {
        do {
            try JSONFile.write(desiredState(nil), to: CaptureStatePaths.captureDesiredURL)
            desiredStopPending = false
        } catch {
            desiredStopPending = true
            ensureCaptureWatch()
            await control.send(.error("failed to write capture desired state: \(error)"))
        }
    }

    private func retryDesiredStopped() async {
        do {
            try JSONFile.write(desiredState(nil), to: CaptureStatePaths.captureDesiredURL)
            desiredStopPending = false
            await control.send(.log("capture desired stateを停止へ書き直しました"))
        } catch {
            // 失敗は書いた時に伝えてある。書けるまで1秒ごとに続ける
        }
    }

    /// 実状態を1秒ごとに読む処理を、まだ動いていなければ始める。
    /// actorの`init`ではselfを捕まえるTaskを作れないため、最初の収録で始める
    private func ensureCaptureWatch() {
        guard captureWatchTask == nil else { return }
        captureWatchTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollCaptureActual()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollCaptureActual() async {
        guard recording, let prefix = currentPrefix else {
            if desiredStopPending {
                await retryDesiredStopped()
            }
            return
        }
        let actual: CaptureActualState?
        do {
            actual = try JSONFile.read(CaptureActualState.self, from: CaptureStatePaths.captureActualURL)
            lastActualReadError = nil
        } catch {
            // 解釈できない実状態は、capture-daemonが応答していない時と同じに扱う。原因は1度だけlogへ出す
            actual = nil
            let message = "実状態を読めません: \(error)"
            if message != lastActualReadError {
                lastActualReadError = message
                await control.send(.log(message))
            }
        }
        let changes = captureWatcher.observe(
            actual, prefix: prefix, sources: sourceOption.sources.map(\.source), nowMS: Self.ms(Date()))
        if let snapshot = changes.snapshot {
            captureStatuses = snapshot.statuses
            micInput = snapshot.micInput
            await control.send(.status(statusEvent()))
        }
        if changes.inputReset {
            await control.send(.inputReset)
        }
        for message in changes.errors {
            await control.send(.error(message))
        }
    }

    private func statusEvent() -> StatusEvent {
        guard recording, let currentPrefix else {
            return StatusEvent(recording: false, sources: [], outputDirectory: outputDirectory.path)
        }
        return StatusEvent(
            recording: true, prefix: currentPrefix, sources: sourceOption.sources.map(\.source),
            inputName: micInput?.name, inputSpatial: micInput?.spatial, outputDirectory: outputDirectory.path,
            capture: captureStatuses.isEmpty ? nil : captureStatuses)
    }

    // MARK: - rename_speaker

    private func renameSpeaker(id: String, name: String) async {
        guard recording else {
            await control.send(.error("not recording"))
            return
        }
        let rename = SpeakerNameRecord(speaker: id, name: name)
        do {
            try await archive.appendLive(.speakerName(rename))
        } catch {
            await control.send(.error("failed to rename speaker: \(error)"))
            return
        }
        for utterance in reconciler.apply(.speakerName(rename)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - stop

    private func stop() async {
        guard recording else {
            await control.send(.error("not recording"))
            return
        }
        let ended = await finishRecording()
        captureStatuses = []
        micInput = nil
        await writeDesiredStopped()
        await control.send(.status(statusEvent()))
        if let ended {
            await finalizer.enqueue(.init(prefix: ended, speakers: nil))
        }
    }

    /// ライブの文字起こしを打ち切り、`session_end`を足して、ここまでの発話で`final.md`を書いて収録を閉じる。
    /// capture-daemonへの指示は呼び出し側が行う
    @discardableResult
    private func finishRecording() async -> String? {
        guard let prefix = currentPrefix else { return nil }
        for stream in live {
            await stream.transcription.stop()
            await stream.consumer.value
        }
        live = []
        do {
            try await archive.endCurrent(endedMS: Self.ms(Date()))
        } catch {
            await control.send(.error("failed to write final: \(error)"))
        }
        currentPrefix = nil
        recording = false
        return prefix
    }

    // MARK: - rotate

    /// 取り込みを止めずに新しい収録へ切り替える。望む状態の書き換えで、capture-daemonは書き込み先だけを切り替える。
    /// 中間の`recording:false`のstatusは出さない
    private func rotate() async {
        guard recording, let oldPrefix = currentPrefix else {
            await control.send(.error("not recording"))
            return
        }
        await finishRecording()
        if await startNewRecording(keepingCapture: true), let currentPrefix {
            await control.send(.status(statusEvent()))
            await control.send(.log("rotated \(oldPrefix) -> \(currentPrefix)"))
        } else {
            captureStatuses = []
            micInput = nil
            await control.send(.status(statusEvent()))
        }
        await finalizer.enqueue(.init(prefix: oldPrefix, speakers: nil))
    }

    // MARK: - quit

    private func quit() async {
        captureWatchTask?.cancel()
        if recording {
            await stop()
        }
        if let peerListener {
            for state in peerStates.values {
                state.pingTask?.cancel()
            }
            peerStates.removeAll()
            await peerListener.stop()
            self.peerListener = nil
        }
        await finalizer.shutdown()
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - peer: pairing / listener lifecycle

    /// `Command.pairCode`から呼ばれる。既存listenerがあれば止めてから、渡されたpairing codeで
    /// 新しいlistenerを起動し直す（appが「再生成」でcodeを変えた場合の再起動を兼ねる）
    private func setPairingCode(_ code: String) async {
        if let peerListener {
            for state in peerStates.values {
                state.pingTask?.cancel()
            }
            peerStates.removeAll()
            await peerListener.stop()
            self.peerListener = nil
        }

        let listener = PeerListener(
            pairingCode: code,
            serviceName: device.name,
            onMessage: { [weak self] connectionID, message in
                await self?.handlePeer(message, from: connectionID)
            },
            onDisconnect: { [weak self] connectionID in
                await self?.handlePeerDisconnect(connectionID)
            }
        )
        do {
            try await listener.start()
            peerListener = listener
            await control.send(.log("peer listener started"))
        } catch {
            await control.send(.error("failed to start peer listener: \(error)"))
        }
    }

    // MARK: - peer: message handling

    private func handlePeer(_ message: PeerMessage, from connectionID: PeerConnectionID) async {
        switch message {
        case .hello(let hello):
            await handleHello(hello, from: connectionID)
        case .pong(let pingID, let t0, let t1, let t2):
            await handlePong(pingID: pingID, t0: t0, t1: t1, t2: t2, from: connectionID)
        case .seg(let segment):
            await handleSeg(segment, from: connectionID)
        case .helloAck, .ping, .ack:
            // Macはserver側でこれらは送るだけなので、届いても無視する
            break
        }
    }

    private func handlePeerDisconnect(_ connectionID: PeerConnectionID) async {
        guard let state = peerStates[connectionID] else { return }
        state.pingTask?.cancel()
        peerStates[connectionID] = nil
        if let hello = state.hello {
            await control.send(
                .peer(device: hello.device, deviceName: hello.deviceName, connected: false))
        }
    }

    private func handleHello(_ hello: HelloMessage, from connectionID: PeerConnectionID) async {
        // 同じ接続へのhello再送（通常は無いはず）でping Taskを孤立させないよう、
        // 既存stateがあれば先にcancelしてから作り直す
        peerStates[connectionID]?.pingTask?.cancel()
        peerStates[connectionID] = PeerState(hello: hello)

        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let accepted = hello.protocolVersion == HelloMessage.currentProtocolVersion
        let reason: String? =
            accepted ? nil : "unsupported protocol_version \(hello.protocolVersion)"
        guard let peerListener else { return }
        await peerListener.send(
            .helloAck(HelloAckMessage(serverTimeMS: now, accepted: accepted, reason: reason)),
            to: connectionID)

        await control.send(
            .peer(device: hello.device, deviceName: hello.deviceName, connected: true))

        guard accepted else { return }

        for _ in 1...5 {
            await sendNextPing(to: connectionID)
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await self?.sendNextPing(to: connectionID)
            }
        }
        // 5回のimmediate ping送信中に切断されて既にstateが消えている場合、taskを
        // どこにも保持せず孤立させないようcancelする
        if peerStates[connectionID] != nil {
            peerStates[connectionID]?.pingTask = task
        } else {
            task.cancel()
        }
    }

    private func sendNextPing(to connectionID: PeerConnectionID) async {
        guard peerStates[connectionID] != nil, let peerListener else { return }
        peerStates[connectionID]!.pingID += 1
        let pingID = peerStates[connectionID]!.pingID
        let t0 = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        peerStates[connectionID]!.pingSent[pingID] = t0
        await peerListener.send(.ping(id: pingID, t0: t0), to: connectionID)
    }

    private func handlePong(
        pingID: Int, t0: Int64, t1: Int64, t2: Int64, from connectionID: PeerConnectionID
    ) async {
        guard var state = peerStates[connectionID] else { return }
        // 実際にこちらから送ったpingへの応答かを確認する（一致しなければ捨てる）
        guard state.pingSent.removeValue(forKey: pingID) != nil else {
            peerStates[connectionID] = state
            return
        }

        let t3 = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        state.offsetSamples.append(ClockOffset.sample(t0: t0, t1: t1, t2: t2, t3: t3))
        peerStates[connectionID] = state

        guard let best = ClockOffset.best(state.offsetSamples), let hello = state.hello else {
            return
        }
        guard recording, !recordedPeerDevices.contains(hello.device) else { return }

        let record = DeviceRecord(
            device: hello.device, deviceName: hello.deviceName, owner: hello.owner,
            platform: hello.platform, offsetMS: best.offsetMS)
        do {
            try await archive.appendLive(.device(record))
            recordedPeerDevices.insert(hello.device)
        } catch {
            await control.send(.error("failed to append device record: \(error)"))
        }
    }

    // MARK: - peer: seg / ack / routing

    private func handleSeg(_ segment: Segment, from connectionID: PeerConnectionID) async {
        guard let peerListener else { return }

        let cursor = cursorValue(for: segment.device)
        guard segment.seq > cursor else {
            // 既に受信済み: 破棄するがackはし直す（iPhone側が再送を止められるように）
            await peerListener.send(.ack(seq: segment.seq), to: connectionID)
            return
        }

        var seg = segment
        let bestOffsetMS = peerStates[connectionID].flatMap { ClockOffset.best($0.offsetSamples)?.offsetMS }
        seg.clockOffsetMS = ClockOffset.segmentOffsetMS(fromRemoteOffset: bestOffsetMS ?? 0)
        seg.receivedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())

        let normalizedStart = seg.start + seg.clockOffsetMS
        let matchedPrefix = SessionMatcher.match(
            segmentStartMS: normalizedStart, sessions: await archive.sessions(in: outputDirectory))

        if let matchedPrefix, recording, matchedPrefix == currentPrefix {
            do {
                try await archive.appendLive(.segment(seg))
                for utterance in reconciler.apply(.segment(seg)) {
                    await control.send(.utterance(utterance))
                }
            } catch {
                await control.send(.error("failed to append peer segment: \(error)"))
            }
        } else if let matchedPrefix {
            do {
                try await archive.appendAndRender([.segment(seg)], prefix: matchedPrefix, in: outputDirectory)
                await control.send(.log("appended peer seg to \(matchedPrefix), final.md regenerated"))
            } catch {
                await control.send(.error("failed to append peer seg to \(matchedPrefix): \(error)"))
            }
        } else {
            do {
                try await archive.appendOrphan(seg, in: outputDirectory)
                await control.send(
                    .log("no matching session for peer seg from \(seg.device), appended to orphans.jsonl"))
            } catch {
                await control.send(.error("failed to append orphan seg: \(error)"))
            }
        }

        updateCursor(device: seg.device, seq: seg.seq)
        await peerListener.send(.ack(seq: seg.seq), to: connectionID)
    }

    private func cursorValue(for device: String) -> Int {
        if let cached = receivedCursors[device] {
            return cached
        }
        let loaded = receivedCursorStore.load(device: device)
        receivedCursors[device] = loaded
        return loaded
    }

    private func updateCursor(device: String, seq: Int) {
        let current = receivedCursors[device] ?? 0
        guard seq > current else { return }
        receivedCursors[device] = seq
        try? receivedCursorStore.save(device: device, seq: seq)
    }
}
#endif
