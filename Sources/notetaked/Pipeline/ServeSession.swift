#if canImport(Speech)
import FluidAudio
import Foundation
import NotetakeCore

/// serve daemonの収録状態（store / reconciler / seq / 起動中のCaptureStream）を保持し、
/// stdinのCommandとcapture eventが競合しないよう1つのactorへ直列化する
@available(macOS 26, iOS 26, *)
actor ServeSession {
    enum SourceOption: String {
        case mic, system, both

        var sources: [(source: Source, owner: (_ configuredOwner: String) -> String)] {
            switch self {
            case .mic:
                return [(.mic, { $0 })]
            case .system:
                return [(.system, { _ in "リモート" })]
            case .both:
                return [(.mic, { $0 }), (.system, { _ in "リモート" })]
            }
        }
    }

    private struct RunningStream {
        let source: Source
        let owner: String
        let input: InputDevice
        let stream: CaptureStream
        let consumer: Task<Void, Never>
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
    private let diarizerModels: DiarizerModels?
    private let profileStore: SpeakerProfileStore?

    private var store: SessionStore?
    private var reconciler = Reconciler()
    private var seq = 0
    private var streams: [RunningStream] = []
    /// 現在収録中のmic streamの入力機材。mic無しならnil。収録停止でnilに戻す
    private var currentInput: InputDevice?
    private var recording = false
    /// 直前に使ったprefix。同一秒内でのstart/rotateがprefixを衝突させないよう、
    /// startCaptureで開始日時をずらすのに使う
    private var lastPrefix: String?
    /// mic/systemのlocal話者idをMac横断の大域idへ束ねる。1回のserve起動（プロセス）の間、
    /// stop→startやrotateをまたいで保持する（同じ人には同じ大域idを付け続けるため、
    /// startCapture()ではリセットしない）
    private var registry: SpeakerRegistry
    /// profile由来の話者名を、そのcaptureで大域idが初めて出た時に1回だけ発話へ流すための判定。
    /// captureごと（startCapture）にリセットする
    private var nameAnnouncer = ProfileNameAnnouncer()

    // MARK: - peer (iPhone/Watch)

    private var peerListener: PeerListener?
    private var peerStates: [PeerConnectionID: PeerState] = [:]
    /// 出力ディレクトリの`*.timed.jsonl`から作った収録一覧。start/stop/rotateのたびに
    /// 更新する（受信seg以外のタイミングでは変わらないため常時再scanはしない）。
    /// 進行中の収録は`endMS == nil`にして`SessionMatcher`へ渡す
    private var sessions: [SessionSpan] = []
    /// device単位の受信済み最大seq（`ReceivedCursor`のin-memory mirror）
    private var receivedCursors: [String: Int] = [:]
    private let receivedCursorStore = ReceivedCursor.default()
    /// 進行中の収録で既にDeviceRecordを書いたdevice id集合。新しいprefixで開始するたびリセットする
    private var recordedPeerDevices: Set<String> = []

    init(
        outputDirectory: URL, owner: String, sourceOption: SourceOption, locale: Locale,
        control: StdioControl, device: DeviceIdentity, diarizerModels: DiarizerModels?,
        registry: SpeakerRegistry, profileStore: SpeakerProfileStore?
    ) {
        self.outputDirectory = outputDirectory
        self.owner = owner
        self.sourceOption = sourceOption
        self.locale = locale
        self.control = control
        self.device = device
        self.diarizerModels = diarizerModels
        self.registry = registry
        self.profileStore = profileStore
        self.sessions = SessionIndex.scan(directory: outputDirectory)
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

        if await startCapture(), let store {
            await control.send(
                .status(
                    StatusEvent(
                        recording: true, prefix: store.prefix,
                        sources: streams.map(\.source),
                        inputName: currentInput?.name, inputSpatial: currentInput?.spatial,
                        outputDirectory: outputDirectory.path)))
        }
    }

    /// storeの作成・session/deviceレコード書き込み・CaptureStream起動までを行い、
    /// 成功時は`store` / `reconciler` / `seq` / `streams` / `recording` / `lastPrefix`を更新する。
    /// 失敗時は今までと同じ`.error(...)`を送って`false`を返す（呼び出し元がstatusを出す）
    private func startCapture() async -> Bool {
        var startDate = Date()
        while SessionStore.prefix(for: startDate, timeZone: .current) == lastPrefix {
            startDate.addTimeInterval(1)
        }
        let store = SessionStore(directory: outputDirectory, start: startDate)
        do {
            try await store.append(
                .session(
                    SessionRecord(
                        id: store.prefix,
                        started: Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
                        owner: owner)))
            try await store.append(
                .device(
                    DeviceRecord(
                        device: device.id, deviceName: device.name, owner: owner,
                        platform: .mac, offsetMS: 0)))
        } catch {
            await store.close()
            await control.send(.error("failed to start session: \(error)"))
            return false
        }

        var started: [RunningStream] = []
        var startError: Error?

        for (source, ownerFor) in sourceOption.sources {
            do {
                let capture: any AudioCapture
                switch source {
                case .mic:
                    capture = MicCapture()
                case .system:
                    capture = try SystemAudioCapture()
                case .watch:
                    throw CaptureStreamError.sourceNotImplemented(source)
                }
                let captureStream = try await CaptureStream(
                    source: source, capture: capture, locale: locale,
                    diarizerModels: diarizerModels)
                let events = try await captureStream.start()
                let streamOwner = ownerFor(owner)
                let input: InputDevice = source == .system ? .system : InputDeviceProbe.current()
                let consumer = Task { [weak self] in
                    for await event in events {
                        await self?.handle(streamEvent: event, source: source, owner: streamOwner, input: input)
                    }
                }
                started.append(
                    RunningStream(
                        source: source, owner: streamOwner, input: input, stream: captureStream,
                        consumer: consumer))
            } catch {
                startError = error
                break
            }
        }

        if let startError {
            for running in started {
                try? await running.stream.stop()
                await running.consumer.value
            }
            await store.close()
            await control.send(.error("failed to start capture: \(startError)"))
            return false
        }

        self.store = store
        self.reconciler = Reconciler()
        self.nameAnnouncer = ProfileNameAnnouncer()
        self.seq = 0
        self.streams = started
        self.currentInput = started.first(where: { $0.source == .mic })?.input
        self.recording = true
        self.lastPrefix = store.prefix
        self.recordedPeerDevices = []
        refreshSessions()

        return true
    }

    // MARK: - stream events

    private func handle(streamEvent: StreamEvent, source: Source, owner: String, input: InputDevice) async {
        switch streamEvent {
        case .volatile(let text):
            await control.send(.volatile(source: source, text: text))
        case .final(let piece, let levelDBFS):
            await handleFinal(piece, levelDBFS: levelDBFS, source: source, owner: owner, input: input)
        case .log(let message):
            await control.send(.log(message))
        }
    }

    private func handleFinal(
        _ piece: AlignedPiece, levelDBFS: Double, source: Source, owner: String, input: InputDevice
    ) async {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let store else { return }

        seq += 1
        let receivedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())

        var speaker: SpeakerTag?
        var profileName: SpeakerNameRecord?
        if let local = piece.localSpeaker, let embedding = piece.embedding {
            let global = registry.assign(
                streamKey: source.rawValue, localID: local, embedding: embedding)
            speaker = SpeakerTag(local: local, global: global, embedding: embedding)
            profileName = nameAnnouncer.record(for: global, in: registry)
        }

        let segment = Segment(
            id: UUID(),
            session: store.prefix,
            seq: seq,
            device: device.id,
            deviceName: device.name,
            owner: owner,
            platform: .mac,
            source: source,
            input: input,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: levelDBFS,
            speaker: speaker,
            clockOffsetMS: 0,
            receivedAt: receivedAt)

        if let profileName {
            do {
                try await store.append(.speakerName(profileName))
            } catch {
                await control.send(.error("failed to append speaker name: \(error)"))
                return
            }
            for utterance in reconciler.apply(.speakerName(profileName)) {
                await control.send(.utterance(utterance))
            }
        }

        do {
            try await store.append(.segment(segment))
        } catch {
            await control.send(.error("failed to append segment: \(error)"))
            return
        }

        for utterance in reconciler.apply(.segment(segment)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - rename_speaker

    private func renameSpeaker(id: String, name: String) async {
        guard recording, let store else {
            await control.send(.error("not recording"))
            return
        }

        let rename = SpeakerNameRecord(speaker: id, name: name)
        do {
            try await store.append(.speakerName(rename))
        } catch {
            await control.send(.error("failed to rename speaker: \(error)"))
            return
        }

        registry.setName(name, for: id)
        nameAnnouncer.markAnnounced(id)
        do {
            try await store.writeSpeakers(registry.profiles)
        } catch {
            await control.send(.error("failed to write speakers: \(error)"))
        }
        if let profileStore {
            do {
                try profileStore.save(registry.namedProfiles)
            } catch {
                await control.send(.error("failed to save speaker profiles: \(error)"))
            }
        }

        for utterance in reconciler.apply(.speakerName(rename)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - stop

    private func stop() async {
        guard recording, store != nil else {
            await control.send(.error("not recording"))
            return
        }

        await stopCapture()

        await control.send(
            .status(
                StatusEvent(
                    recording: false, prefix: nil, sources: [],
                    outputDirectory: outputDirectory.path)))
    }

    /// streamsの停止・final書き出し・storeのcloseを行い、`store` / `recording`をリセットする
    private func stopCapture() async {
        guard let store else { return }

        for running in streams {
            do {
                try await running.stream.stop()
            } catch {
                await control.send(.error("failed to stop capture: \(error)"))
                // CaptureStream.stop()はfailure時もevent streamをfinishさせるが、
                // 万一終わらなかった場合にconsumerのfor-awaitが無限にwedgeしないよう保険で
                // cancelしてからawaitする
                running.consumer.cancel()
            }
            await running.consumer.value
        }
        streams = []

        let markdown = TranscriptRenderer.markdown(reconciler.utterances, timeZone: .current)
        do {
            try await store.writeFinal(markdown)
        } catch {
            await control.send(.error("failed to write final: \(error)"))
        }

        if !registry.profiles.isEmpty {
            do {
                try await store.writeSpeakers(registry.profiles)
            } catch {
                await control.send(.error("failed to write speakers: \(error)"))
            }
        }
        if let profileStore {
            do {
                try profileStore.save(registry.namedProfiles)
            } catch {
                await control.send(.error("failed to save speaker profiles: \(error)"))
            }
        }

        await store.close()

        self.store = nil
        currentInput = nil
        recording = false
        refreshSessions()
    }

    // MARK: - rotate

    /// 収録を止めて新しいprefixで直ちに開始し直す。中間の`recording:false`statusは出さない
    /// （appの`restartPending`再起動と競合しないため）
    private func rotate() async {
        guard recording, let store else {
            await control.send(.error("not recording"))
            return
        }
        let oldPrefix = store.prefix

        await stopCapture()

        if await startCapture(), let store = self.store {
            await control.send(
                .status(
                    StatusEvent(
                        recording: true, prefix: store.prefix,
                        sources: streams.map(\.source),
                        inputName: currentInput?.name, inputSpatial: currentInput?.spatial,
                        outputDirectory: outputDirectory.path)))
            await control.send(.log("rotated \(oldPrefix) -> \(store.prefix)"))
        } else {
            await control.send(
                .status(
                    StatusEvent(
                        recording: false, prefix: nil, sources: [],
                        outputDirectory: outputDirectory.path)))
        }
    }

    // MARK: - quit

    private func quit() async {
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
        guard let store, recording, !recordedPeerDevices.contains(hello.device) else { return }

        let record = DeviceRecord(
            device: hello.device, deviceName: hello.deviceName, owner: hello.owner,
            platform: hello.platform, offsetMS: best.offsetMS)
        do {
            try await store.append(.device(record))
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
        let matchedPrefix = SessionMatcher.match(segmentStartMS: normalizedStart, sessions: sessions)

        if let matchedPrefix, let store, recording, matchedPrefix == store.prefix {
            do {
                try await store.append(.segment(seg))
                for utterance in reconciler.apply(.segment(seg)) {
                    await control.send(.utterance(utterance))
                }
            } catch {
                await control.send(.error("failed to append peer segment: \(error)"))
            }
        } else if let matchedPrefix {
            await appendToPastSession(prefix: matchedPrefix, segment: seg)
        } else {
            await appendOrphan(seg)
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

    /// 停止済みの収録`prefix`のtimed.jsonlへ`segment`を追記し、その収録のfinal.mdを
    /// 全recordの再foldから再生成する
    private func appendToPastSession(prefix: String, segment: Segment) async {
        let timedURL = SessionIndex.timedURL(directory: outputDirectory, prefix: prefix)
        do {
            let line = try NDJSON.encode(.segment(segment)) + "\n"
            if !FileManager.default.fileExists(atPath: timedURL.path) {
                FileManager.default.createFile(atPath: timedURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: timedURL)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()

            let text = try String(contentsOf: timedURL, encoding: .utf8)
            let utterances = Reconciler.fold(NDJSON.decodeAll(text))
            let markdown = TranscriptRenderer.markdown(utterances, timeZone: .current)
            let finalURL = SessionIndex.finalURL(directory: outputDirectory, prefix: prefix)
            try Data(markdown.utf8).write(to: finalURL, options: .atomic)

            await control.send(.log("appended peer seg to \(prefix), final.md regenerated"))
        } catch {
            await control.send(.error("failed to append peer seg to \(prefix): \(error)"))
        }
    }

    /// どの収録にも入らないsegを`<output>/orphans.jsonl`へ追記して捨てない
    private func appendOrphan(_ segment: Segment) async {
        let orphansURL = outputDirectory.appendingPathComponent("orphans.jsonl")
        do {
            let line = try NDJSON.encode(.segment(segment)) + "\n"
            if !FileManager.default.fileExists(atPath: orphansURL.path) {
                FileManager.default.createFile(atPath: orphansURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: orphansURL)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
            await control.send(
                .log("no matching session for peer seg from \(segment.device), appended to orphans.jsonl"))
        } catch {
            await control.send(.error("failed to append orphan seg: \(error)"))
        }
    }

    // MARK: - peer: session index cache

    /// `sessions`をディスクの`*.timed.jsonl`から再構成する。進行中の収録があれば
    /// `endMS`をnilへ差し替え、それ以降のstart/stop/rotateまでこの状態で使い続ける
    private func refreshSessions() {
        var scanned = SessionIndex.scan(directory: outputDirectory)
        if let store, recording, let index = scanned.firstIndex(where: { $0.prefix == store.prefix }) {
            scanned[index].endMS = nil
        }
        sessions = scanned
    }
}
#endif
