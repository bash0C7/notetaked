import AVFoundation
import Foundation
import NotetakeCore
import SwiftUI
import Synchronization
import WatchConnectivity
import WatchKit

/// Watchの録音状態と、AVAudioEngine → 20秒ごとのAAC小片 → `WCSession.transferFile`の一連を管理する。
/// 録音の継続は`.playAndRecord`と`UIBackgroundModes: [audio]`に頼る（G1で確かめた版）。
///
/// 並行性: 本体は`@MainActor`。`WCSessionDelegate`のメソッド（watchOSでは`activationDidCompleteWith`が
/// 必須、`didFinish fileTransfer:`は自前で使う）はバックグラウンドの任意スレッドから呼ばれるため、
/// 下の`extension`で`nonisolated`として実装し、`Task { @MainActor [weak self] in ... }`経由でのみ
/// 本体の状態に触れる。実際のPCM書き込みとrotation判定は`ChunkWriter`（actor）に切り出し、
/// AVAudioEngineのtap callback（real-time thread）からは`AsyncStream`へ`yield`するだけにして、
/// 1本の`Task`が順番に`await writer.append(buffer)`する（buffer到着順を保つため。tap callbackから
/// bufferごとに個別の`Task`を積むとスケジューリング順序がFIFOである保証がない）。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    /// tap callback（audioスレッド）からfeedTaskへbufferを渡すための値型wrapper。
    /// `@unchecked Sendable`の根拠: tapはyield後にbufferへ触れず、受け取ったfeedTaskだけが読む（`Recorder.CapturedBuffer`と同じ）
    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        /// tapの`when.hostTime`。feedTaskが壁時計へ写して小片の開始時刻にする
        let hostTime: UInt64
    }

    private enum DefaultsKey {
        static let ownerName = "ownerName"
        static let recordingIntent = "recordingIntent"
    }

    private static let chunkDurationSeconds: Double = 20
    /// `tapQueue`の記録と電池残量の読み直しの間隔
    private static let sampleIntervalMS: Int64 = 1000

    /// 録音の状態。`dispatch(_:)`だけが書き換える（reducerを通さず直接触らない）
    private(set) var phase: WatchRecordingPhase = .idle
    /// 画面の再評価用の現在時刻（ms）。経過時間のtimerが毎秒更新する。
    /// reducerにtickは無いので、前面のままbufferが途絶えた時に`display`が「音声が届いていません」へ
    /// 変わるのは、この更新で`display`が再評価されるため（bufferのたびには更新しない）
    private(set) var nowMS: Int64 = WatchRecorder.currentMS()
    /// 転送が終わっていない小片のfile名。起動時に`outstandingFileTransfers`や再送へ載せたものも含む。
    /// 転送の完了は`didFinish`と`progress`の確認の早い方が、ここから取り除けた時だけ後始末する
    private(set) var pendingNames: Set<String> = []
    /// 前回の録音が終わらないまま閉じられた（録音したい状態が残っている）。開始すると消える
    private(set) var interruptedOnLaunch = false
    var lastError: String?

    var pendingTransfers: Int {
        pendingNames.count
    }

    var display: WatchRecordingDisplay {
        WatchRecordingReducer.display(phase, nowMS: nowMS, queueDepth: max(0, queueCounter.value))
    }

    /// 停止ボタンを出すか。音声が途絶えて警告中でも`true`（止まった扱いにするのは`.halted`だけ）
    var isRecording: Bool {
        display.isActive
    }

    /// 収録に載せる自分の名前。今はUserDefaultsのみ（`WCSession.applicationContext`経由でiPhoneから
    /// 受け取るのは将来の拡張）。
    var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: DefaultsKey.ownerName) }
    }

    /// `mediaServicesWereReset`の後は作り直す（同じengineを使い回さない）
    @ObservationIgnored private var engine = AVAudioEngine()
    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var writer: ChunkWriter?
    private var queueCounter = QueueDepthCounter()
    private let obsLog: WatchObsLog
    private let notifier: DeadManNotifier
    private let chunkStore: ChunkStore
    /// 送った小片のfile名 → 転送。`progress`を見て、`didFinish`が来なくても完了を拾う
    @ObservationIgnored private var transfers: [String: WCSessionFileTransfer] = [:]
    /// 失敗して1回だけ個別に送り直した小片。2回目以降の失敗は再送を`isReachable`の変化か`recover`に任せる
    @ObservationIgnored private var retriedNames: Set<String> = []
    /// 活性化の前に閉じた小片。活性化の後に送る
    @ObservationIgnored private var deferredTransfers: [(url: URL, metadata: WatchChunkMetadata)] = []
    @ObservationIgnored private var transferWatcher: Task<Void, Never>?
    @ObservationIgnored private var wakeGate = WatchWakeGate()
    /// 最後に閉じた小片。到達できるようになった時の合図に使う
    @ObservationIgnored private var lastClosedChunk: (device: String, session: String, index: Int)?
    /// 後始末で積み残しのbufferを書いている間のsession。`recoverChunks`が録音中として扱う
    @ObservationIgnored private var drainingSessionID: String?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    /// 録音したい状態。開始で立て、停止・自動停止で下ろす
    @ObservationIgnored private var intent = WatchRecordingIntent(wantsRecording: false, session: nil, startedAtMS: nil)
    /// 録音中のsession ID。記録の`session`に載せる
    private var currentSessionID: String?
    /// 実行中の`tearDown`の後始末。終わるまで`start()`を始めない（前のsessionの`setActive(false)`が
    /// 新しいsessionを巻き込まないように）
    private var tearDownTask: Task<Void, Never>?
    /// timerが毎秒読み直す電池残量（0...1）。負の値（監視が無効など）はnil
    @ObservationIgnored private var cachedBatteryLevel: Double?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

    override init() {
        obsLog = WatchObsLog(directory: Self.obsDirectory(), device: WatchIdentity.deviceID())
        notifier = DeadManNotifier()
        chunkStore = ChunkStore(directory: Self.chunksDirectory())
        ownerName = UserDefaults.standard.string(forKey: DefaultsKey.ownerName) ?? "私"
        super.init()
        intent = Self.loadIntent()
        interruptedOnLaunch = intent.interruptedOnLaunch(isRecording: false)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        // 前回の異常終了などで送り切れなかった小片は、活性化の後の`recoverChunks()`が
        // diskの小片から決めて再送・確認・破棄する（`session(_:activationDidCompleteWith:error:)`）
        let launchedAtMS = Self.currentMS()
        obsLog.resendLeftovers(nowMS: launchedAtMS)
        obsLog.record(.init(atMS: launchedAtMS, event: .launched))
        observeAudioNotifications()
        startTransferWatcher()
    }

    // MARK: - Recording

    func start() {
        guard !isRecording else { return }
        if let pending = tearDownTask {
            Task { @MainActor [weak self] in
                await pending.value
                self?.start()
            }
            return
        }
        lastError = nil
        interruptedOnLaunch = false
        notifier.requestAuthorizationIfNeeded()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 手首を下げても録れ続けるか（G1）を確かめた版。通知音を消さないため`.record`でなく`.playAndRecord`
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            startFailed("マイクの初期化に失敗しました: \(error.localizedDescription)", session: nil)
            return
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let sessionStartMS = Self.currentMS()
        let sessionID: String = String(sessionStartMS)

        let writer: ChunkWriter
        do {
            writer = try ChunkWriter(
                session: sessionID,
                inputFormat: inputFormat,
                device: WatchIdentity.deviceID(),
                deviceName: WatchIdentity.deviceName,
                owner: ownerName,
                chunkDurationSeconds: Self.chunkDurationSeconds,
                chunksDirectory: Self.chunksDirectory()
            )
        } catch {
            try? audioSession.setActive(false)
            startFailed("録音ファイルの作成に失敗しました: \(error.localizedDescription)", session: sessionID)
            return
        }
        self.writer = writer

        let (stream, continuation) = AsyncStream<CapturedBuffer>.makeStream()
        bufferContinuation = continuation
        let counter = QueueDepthCounter()
        queueCounter = counter
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        cachedBatteryLevel = Self.currentBatteryLevel()
        // このclosureはreal-time audio threadから呼ばれる。`AVAudioNodeTapBlock`はSDK上`@Sendable`で
        // ないため、`@MainActor`なこのクラスの中で書いたclosureはそのままだとMainActor隔離と推論され、
        // 実行時にexecutor検査で落ちる（2026-09-13の実機クラッシュ）。`@Sendable`を明示して隔離を外す。
        // `continuation`と`counter`はSendableで、`self`やactorには触れない。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, when in
            // yieldの前に増やす（feedTaskの`decrement()`が先に走って一瞬負になるのを防ぐ）
            counter.increment()
            continuation.yield(CapturedBuffer(buffer: buffer, hostTime: when.hostTime))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            bufferContinuation = nil
            self.writer = nil
            Task { _ = await writer.finish(isFinal: false) }
            try? audioSession.setActive(false)
            startFailed("録音の開始に失敗しました: \(error.localizedDescription)", session: sessionID)
            return
        }

        currentSessionID = sessionID
        let sampleRate: Double = inputFormat.sampleRate
        feedTask = Task { @MainActor [weak self] in
            var lastSampledAtMS: Int64 = 0
            var overflowGate = WatchOverflowGate()
            for await captured in stream {
                counter.decrement()
                let depth: Int = max(0, counter.value)
                let bufferMS: Int64 = Int64((Double(captured.buffer.frameLength) / sampleRate * 1000).rounded())
                let arrivedAtMS: Int64 = Self.currentMS()
                guard let self else { return }
                // 毎bufferでは`@Observable`の状態を変えない。1秒に1回だけreducerへ渡し、
                // 深さの記録もその時だけ行う（feedTaskが詰まっている間は記録が飛ぶ）
                // 止まった後に始め直した別sessionの状態を、古いfeedTaskの残りbufferで動かさない
                if arrivedAtMS - lastSampledAtMS >= Self.sampleIntervalMS, self.currentSessionID == sessionID {
                    lastSampledAtMS = arrivedAtMS
                    self.dispatch(.bufferArrived(atMS: arrivedAtMS))
                    self.obsLog.record(
                        .init(
                            atMS: arrivedAtMS, event: .tapQueue, session: sessionID,
                            detail: "est:depth*bufferMS", value: Double(depth), lagMS: Int64(depth) * bufferMS))
                }
                switch overflowGate.decide(depth: depth) {
                case .write:
                    break
                case .drop:
                    continue
                case .dropStartingOverflow:
                    // 待ち行列が上限を超えた。このbufferを捨てて今の小片を閉じ、下限まで捨て続ける
                    self.handle(await writer.closeForOverflow(), session: sessionID)
                    continue
                case .resume(let droppedBuffers, let maxDepth):
                    self.obsLog.record(
                        .init(
                            atMS: arrivedAtMS, event: .queueOverflow, session: sessionID,
                            detail: "dropped_buffers=\(droppedBuffers)", value: Double(maxDepth)))
                }
                let wallMS: Int64 = Self.wallMS(forHostTime: captured.hostTime)
                let context = ChunkAppendContext(batteryLevel: self.cachedBatteryLevel, queueDepth: depth)
                self.handle(await writer.append(captured.buffer, wallMS: wallMS, context: context), session: sessionID)
            }
        }

        nowMS = sessionStartMS
        dispatch(.started(atMS: sessionStartMS))
        saveIntent(WatchRecordingIntent(wantsRecording: true, session: sessionID, startedAtMS: sessionStartMS))
        obsLog.record(.init(atMS: sessionStartMS, event: .started, session: sessionID, detail: "category=playAndRecord"))
        startElapsedTimer()
    }

    func stop() {
        guard isRecording else { return }
        let stoppedAtMS = Self.currentMS()
        dispatch(.stopped(atMS: stoppedAtMS))
        saveIntent(WatchRecordingIntent(wantsRecording: false, session: nil, startedAtMS: nil))
        obsLog.record(.init(atMS: stoppedAtMS, event: .stopped, session: currentSessionID))
        tearDown(isFinal: true)
    }

    /// 録音の後始末。`stop()`と、録音中に`.halted`へ移った時（`dispatch`）の両方から呼ぶ。
    /// 音声の入口を止め、積み残しのbufferを書き切って最後の小片を閉じ、記録をiPhoneへ送る。
    /// `isFinal`は利用者の停止と自動停止の時だけ`true`（haltedで閉じた小片には付けない）
    private func tearDown(isFinal: Bool) {
        elapsedTask?.cancel()
        elapsedTask = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil

        let writer = self.writer
        self.writer = nil
        let feedTask = self.feedTask
        self.feedTask = nil
        drainingSessionID = currentSessionID
        currentSessionID = nil

        // feedTaskが積み残しのbufferを全部writerへ渡し終えるのを待ってから、最後の小片を
        // 閉じて転送する（そうしないと末尾の数百msが失われる）。
        tearDownTask = Task { @MainActor [weak self] in
            await feedTask?.value
            if let metadata = await writer?.finish(isFinal: isFinal) {
                self?.chunkClosed(metadata)
            }
            self?.drainingSessionID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self?.obsLog.ship(nowMS: Self.currentMS())
            // 止まった記録をshipした後に、最後の合図を1回送る。最後の小片が空で小片ごとの合図が
            // 0回でも、小片ごとの合図が間隔で捨てられていても、iPhoneを起こして止まりを処理させる
            self?.sendFinalWake()
            self?.recoverChunks()
            self?.tearDownTask = nil
        }
    }

    /// 唯一の`phase`の更新口。録音中から`.halted`へ移った時は、止まった理由を記録して後始末する。
    /// `phase`は`.halted`のまま残し、画面に「止まりました」を出し続ける。中断が終わっても自動では再開しない
    private func dispatch(_ event: WatchRecordingEvent) {
        let previous = phase
        let next = WatchRecordingReducer.reduce(previous, event, queueDepth: max(0, queueCounter.value))
        phase = next
        notifier.apply(
            WatchDeadMan.action(for: event, chunkClosedAtMS: nil, previous: previous, next: next),
            nowMS: Self.currentMS())
        guard case .recording = previous, case .halted(let reason, let atMS, let detail) = next else { return }
        if reason == .autoStopped {
            // 自動停止は`auto_stopped`の1行だけを書く（同じ時刻の`halted`は書かない）
            obsLog.record(
                .init(atMS: atMS, event: .autoStopped, session: currentSessionID, haltReason: .autoStopped))
            saveIntent(WatchRecordingIntent(wantsRecording: false, session: nil, startedAtMS: nil))
        } else {
            obsLog.record(
                .init(
                    atMS: atMS, event: .halted, session: currentSessionID, detail: Self.haltDetail(reason, detail),
                    haltReason: reason))
        }
        notifier.notifyHalted(reason: reason)
        if WKApplication.shared().applicationState == .active {
            WKInterfaceDevice.current().play(.failure)
        }
        tearDown(isFinal: reason == .autoStopped)
    }

    private static func haltDetail(_ reason: WatchHaltReason, _ detail: String?) -> String {
        guard let detail else { return reason.rawValue }
        return "\(reason.rawValue): \(detail)"
    }

    private func startFailed(_ message: String, session: String?) {
        lastError = message
        let failedAtMS = Self.currentMS()
        dispatch(.startFailed(atMS: failedAtMS, message: message))
        obsLog.record(.init(atMS: failedAtMS, event: .startFailed, session: session, detail: message))
    }

    /// 前面のscenePhaseを記録し、前面へ戻った時はbufferが途絶えていないかをreducerに判定させる
    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        let changedAtMS = Self.currentMS()
        let name: String
        switch scenePhase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        obsLog.record(.init(atMS: changedAtMS, event: .scenePhase, session: currentSessionID, detail: name))
        if scenePhase == .active {
            nowMS = changedAtMS
            dispatch(.becameActive(atMS: changedAtMS))
        }
    }

    /// `ChunkWriter`の結果を受ける。小片が閉じていれば転送と記録、書き込みの失敗なら停止へ
    private func handle(_ outcome: ChunkWriter.AppendOutcome, session: String) {
        switch outcome {
        case .ok:
            break
        case .chunkQueued(let metadata):
            chunkClosed(metadata)
        case .chunkQueuedThenWriteFailed(let metadata, let message):
            chunkClosed(metadata)
            writeFailed(message, session: session)
        case .writeFailed(let message):
            writeFailed(message, session: session)
        }
    }

    // MARK: - Recording intent

    private func saveIntent(_ newIntent: WatchRecordingIntent) {
        intent = newIntent
        if let data = try? JSONEncoder().encode(newIntent) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.recordingIntent)
        }
    }

    private static func loadIntent() -> WatchRecordingIntent {
        guard
            let data = UserDefaults.standard.data(forKey: DefaultsKey.recordingIntent),
            let stored = try? JSONDecoder().decode(WatchRecordingIntent.self, from: data)
        else {
            return WatchRecordingIntent(wantsRecording: false, session: nil, startedAtMS: nil)
        }
        return stored
    }

    /// 経過時間のtimerと、小片を閉じた時の両方で見る（背面でtimerが遅れても小片の区切りで止まる）
    private func autoStopIfDue(nowMS: Int64) {
        guard case .recording = phase, intent.shouldAutoStop(nowMS: nowMS) else { return }
        dispatch(.autoStopped(atMS: nowMS))
    }

    // MARK: - Notifications

    /// 中断・音声サービスの再起動・engineの構成変更を、initで1回だけ購読する。
    /// closureは通知を投げたスレッドで呼ばれるため`@Sendable`を明示し、値だけ取り出してMainActorへ渡す
    private func observeAudioNotifications() {
        let center = NotificationCenter.default
        let interruption: NSObjectProtocol = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { @Sendable [weak self] (notification: Notification) in
            let typeValue: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue: UInt = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume: Bool = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            // 復帰時のsuspend由来のbeganを通話と区別するため、reasonとwasSuspendedを記録に残す。
            // wasSuspendedのキーはSDK上で非推奨のため、定数を使わず文字列で読む（warningを出さない）
            let reasonValue: UInt? = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let wasSuspended: Bool? = notification.userInfo?["AVAudioSessionInterruptionWasSuspendedKey"] as? Bool
            let beganDetail: String = "reason:\(reasonValue.map { String($0) } ?? "nil") wasSuspended:\(wasSuspended.map { String($0) } ?? "nil")"
            Task { @MainActor [weak self] in
                guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    self?.interruptionBegan(detail: beganDetail)
                case .ended:
                    self?.interruptionEnded(shouldResume: shouldResume)
                @unknown default:
                    break
                }
            }
        }
        let reset: NSObjectProtocol = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { @Sendable [weak self] (_: Notification) in
            Task { @MainActor [weak self] in
                self?.mediaServicesReset()
            }
        }
        notificationObservers = [interruption, reset]
        observeConfigurationChange()
    }

    /// engineの構成変更の購読。engineを作り直したら付け直す（`object: engine`が古いengineのままにならないように）
    private func observeConfigurationChange() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] (_: Notification) in
            Task { @MainActor [weak self] in
                self?.configurationChanged()
            }
        }
    }

    private func interruptionBegan(detail: String) {
        let atMS = Self.currentMS()
        obsLog.record(.init(atMS: atMS, event: .interruptionBegan, session: currentSessionID, detail: detail))
        dispatch(.interruptionBegan(atMS: atMS))
    }

    private func interruptionEnded(shouldResume: Bool) {
        let atMS = Self.currentMS()
        obsLog.record(
            .init(
                atMS: atMS, event: .interruptionEnded, session: currentSessionID,
                detail: "shouldResume:\(shouldResume)"))
        // 自動では再開しない（reducerも`.halted`から戻さない）
        dispatch(.interruptionEnded(atMS: atMS, shouldResume: shouldResume))
    }

    private func mediaServicesReset() {
        let atMS = Self.currentMS()
        obsLog.record(.init(atMS: atMS, event: .mediaServicesReset, session: currentSessionID))
        dispatch(.mediaServicesReset(atMS: atMS))
        // 録音中なら上の`dispatch`の後始末が古いengineを止めている。同じengineは使い回さず、新しく作る
        engine = AVAudioEngine()
        observeConfigurationChange()
    }

    private func configurationChanged() {
        let atMS = Self.currentMS()
        // 通知はTask経由で遅れて届く。停止直後の始め直しで、前の`setActive`由来の通知が新しいsessionへ
        // 届いても、engineが動いていれば健全な録音なので記録だけして止めない
        if engine.isRunning {
            obsLog.record(
                .init(
                    atMS: atMS, event: .configurationChanged, session: currentSessionID,
                    detail: "ignored: engine_running"))
            return
        }
        obsLog.record(.init(atMS: atMS, event: .configurationChanged, session: currentSessionID))
        dispatch(.configurationChanged(atMS: atMS))
    }


    // MARK: - Timer

    private func startElapsedTimer() {
        elapsedTask = Task { @MainActor [weak self] in
            while let self, self.isRecording {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isRecording else { return }
                // `nowMS`の更新で`display`が再評価される。bufferが途絶えて`dispatch`が呼ばれない間も
                // 「録音中」のまま固まらず、noAudioHaltMSを超えたら警告に変わる
                let now = Self.currentMS()
                self.nowMS = now
                self.cachedBatteryLevel = Self.currentBatteryLevel()
                self.autoStopIfDue(nowMS: now)
            }
        }
    }

    // MARK: - Chunks

    /// 小片が閉じた時の後始末。転送に載せ、記録に残し、iPhoneを起こす合図を送り、止まった通知の予約を延ばす。
    /// 合図は`transferFile`の後に送る（起きたiPhoneに小片が先に積まれているように）
    private func chunkClosed(_ metadata: WatchChunkMetadata) {
        let closedAtMS: Int64 = Self.currentMS()
        let fileURL = ChunkFiles.audioURL(
            directory: Self.chunksDirectory(), session: metadata.session, index: metadata.index)
        queueTransfer(fileURL: fileURL, metadata: metadata)
        lastClosedChunk = (metadata.device, metadata.session, metadata.index)
        let reachable = isReachableNow()
        obsLog.record(
            .init(
                atMS: closedAtMS, event: .chunkClosed, session: metadata.session, index: metadata.index,
                value: metadata.maxDBFS, batteryLevel: metadata.batteryLevel ?? cachedBatteryLevel,
                isReachable: reachable))
        sendWake(device: metadata.device, session: metadata.session, index: metadata.index, isReachable: reachable)
        notifier.apply(
            WatchDeadMan.action(for: nil, chunkClosedAtMS: closedAtMS, previous: phase, next: phase),
            nowMS: closedAtMS)
        if (metadata.index + 1) % WatchObsLog.shipEveryChunks == 0 {
            obsLog.ship(nowMS: closedAtMS)
        }
        autoStopIfDue(nowMS: closedAtMS)
    }

    private func writeFailed(_ message: String, session: String) {
        // 同じsessionの初回だけ扱う。止まった後（tearDownでnilになる）に積み残しのbufferが
        // 失敗しても、重複して記録せず、始め直した別sessionも止めない
        guard currentSessionID == session else { return }
        lastError = message
        let failedAtMS = Self.currentMS()
        obsLog.record(.init(atMS: failedAtMS, event: .writeFailed, session: session, detail: message))
        // 録音中でなければreducerが無視する（停止の後始末中に届いた失敗で止まった表示にしない）
        dispatch(.writeFailed(atMS: failedAtMS, message: message))
    }

    // MARK: - Transfer

    private func queueTransfer(fileURL: URL, metadata: WatchChunkMetadata) {
        guard WCSession.isSupported() else { return }
        let name = fileURL.lastPathComponent
        pendingNames.insert(name)
        guard WCSession.default.activationState == .activated else {
            deferredTransfers.append((fileURL, metadata))
            return
        }
        transfers[name] = WCSession.default.transferFile(fileURL, metadata: metadata.metadata)
    }

    private func flushDeferredTransfers() {
        let queued = deferredTransfers
        deferredTransfers = []
        for item in queued where FileManager.default.fileExists(atPath: item.url.path) {
            queueTransfer(fileURL: item.url, metadata: item.metadata)
        }
    }

    /// diskの小片から再送・確認・破棄を決めて実行する。録音中のsessionの小片は対象にしない
    /// （書きかけを送らない、閉じる途中の小片を二重に送らない）。活性化の前は何もしない
    private func recoverChunks() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var outstanding: [String: WCSessionFileTransfer] = [:]
        for transfer in WCSession.default.outstandingFileTransfers {
            guard WatchTransferKind.of(transfer.file.metadata ?? [:]) == .chunk else { continue }
            outstanding[transfer.file.fileURL.lastPathComponent] = transfer
        }
        for (name, transfer) in transfers { outstanding[name] = transfer }
        // 起動時に残っていた転送も`progress`の見張りの対象にする
        transfers = outstanding
        pendingNames.formUnion(outstanding.keys)
        chunkStore.recover(
            activeSession: WatchChunkStorePolicy.activeSession(current: currentSessionID, draining: drainingSessionID),
            outstanding: outstanding,
            transferFile: { url, metadata in self.queueTransfer(fileURL: url, metadata: metadata) },
            record: { record in self.obsLog.record(record) },
            nowMS: Self.currentMS())
        // 破棄した小片を未転送の数から外す
        let directory = Self.chunksDirectory()
        pendingNames = pendingNames.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        transfers = transfers.filter { pendingNames.contains($0.key) }
    }

    /// `didFinish`が来ない不具合への備え。送った転送の`progress`が完了なら、成功と同じ後始末をする
    private func startTransferWatcher() {
        transferWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.reapFinishedTransfers()
            }
        }
    }

    private func reapFinishedTransfers() {
        for (name, transfer) in transfers {
            let progress = transfer.progress
            guard progress.totalUnitCount > 0, progress.isFinished || progress.fractionCompleted >= 1 else { continue }
            let metadata: [String: Any] = transfer.file.metadata ?? [:]
            transferDidFinish(
                fileURL: transfer.file.fileURL, fileName: name, session: metadata["session"] as? String,
                index: metadata["index"] as? Int, failure: nil)
        }
    }

    /// 小片の転送の完了。`didFinish`とtimerのどちらからも呼ばれ、未転送の表から取り除けた方だけが後始末する
    fileprivate func transferDidFinish(fileURL: URL, fileName: String, session: String?, index: Int?, failure: String?) {
        transfers.removeValue(forKey: fileName)
        guard let failure else {
            ChunkTransfer.cleanup(fileURL: fileURL)
            retriedNames.remove(fileName)
            guard pendingNames.remove(fileName) != nil else { return }
            recordTransferResult(session: session, index: index, failure: nil)
            return
        }
        lastError = "小片の転送に失敗しました: \(failure)"
        recordTransferResult(session: session, index: index, failure: failure)
        // 録音中のsessionの小片でも、完了済みなら1回だけ個別に送り直す（`recover`は録音中のsessionを対象にしない）。
        // 続けて失敗する時は`isReachable`の変化か次の`recover`に任せる
        guard retriedNames.insert(fileName).inserted else { return }
        guard
            let sidecar = chunkStore.loadSidecar(of: fileURL), sidecar.complete, let metadata = sidecar.metadata,
            FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return
        }
        queueTransfer(fileURL: fileURL, metadata: metadata)
    }

    fileprivate func recordTransferResult(session: String?, index: Int?, failure: String?) {
        obsLog.record(
            .init(
                atMS: Self.currentMS(),
                event: failure == nil ? .transferFinished : .transferFailed,
                session: session, index: index, detail: failure))
    }

    // MARK: - Wake

    private func isReachableNow() -> Bool {
        guard WCSession.isSupported() else { return false }
        return WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// 小片を閉じたiPhoneを起こす合図（`sendMessage`）。届かない・返事が無い合図で録音・転送を止めず、
    /// 失敗を`lastError`にも出さない
    private func sendWake(device: String, session: String, index: Int, isReachable: Bool, isFinal: Bool = false) {
        let nowMS = Self.currentMS()
        let result =
            isFinal
            ? wakeGate.decideFinal(isReachable: isReachable, nowMS: nowMS)
            : wakeGate.decide(isReachable: isReachable, nowMS: nowMS)
        recordWakeNote(result.note, session: session, index: index, atMS: nowMS)
        guard case .send(let attempt) = result.decision else { return }
        let message = WatchWakeMessage(device: device, session: session, index: index, sentAtMS: nowMS).message
        // handlerは任意のthreadで呼ばれるので`@Sendable`を明示し、値だけ取り出してMainActorへ移る。
        // 返事の中身は読まない（届いたことが分かれば足りる）
        WCSession.default.sendMessage(
            message,
            replyHandler: { @Sendable [weak self] (_: [String: Any]) in
                Task { @MainActor [weak self] in
                    self?.wakeReplied(attempt: attempt, session: session, index: index)
                }
            },
            errorHandler: { @Sendable [weak self] (error: Error) in
                let detail: String = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.wakeFailed(attempt: attempt, session: session, index: index, detail: detail)
                }
            })
    }

    /// 後始末の最後の合図。間隔・返事待ちを無視する（`WatchWakeGate.decideFinal`）。
    /// 小片が一度も閉じていない時も、起こすことが目的なので送る（`session`・`index`は参考値）
    private func sendFinalWake() {
        let last = lastClosedChunk ?? (WatchIdentity.deviceID(), "", 0)
        sendWake(
            device: last.0, session: last.1, index: last.2, isReachable: isReachableNow(), isFinal: true)
    }

    private func wakeReplied(attempt: Int, session: String, index: Int) {
        let atMS = Self.currentMS()
        recordWakeNote(wakeGate.replied(attempt: attempt, atMS: atMS), session: session, index: index, atMS: atMS)
    }

    private func wakeFailed(attempt: Int, session: String, index: Int, detail: String) {
        let atMS = Self.currentMS()
        recordWakeNote(
            wakeGate.failed(attempt: attempt, atMS: atMS, detail: detail), session: session, index: index, atMS: atMS)
    }

    private func recordWakeNote(_ note: WatchWakeGate.Note, session: String, index: Int, atMS: Int64) {
        switch note {
        case .none:
            break
        case .firstFailure(let detail):
            obsLog.record(.init(atMS: atMS, event: .wakeFailed, session: session, index: index, detail: detail))
        case .recovered(let failures):
            obsLog.record(
                .init(atMS: atMS, event: .wakeRecovered, session: session, index: index, value: Double(failures)))
        }
    }

    /// 到達できるようになった時。溜まった小片を先に処理させ、録音中か転送待ちがあれば合図を送る
    fileprivate func reachabilityChanged() {
        guard isReachableNow() else { return }
        recoverChunks()
        guard isRecording || !WCSession.default.outstandingFileTransfers.isEmpty, let last = lastClosedChunk else {
            return
        }
        sendWake(device: last.device, session: last.session, index: last.index, isReachable: true)
    }

    // MARK: - Helpers

    /// 電池残量（0...1）。監視が無効などで負の値が返る時はnil
    private static func currentBatteryLevel() -> Double? {
        let level = Double(WKInterfaceDevice.current().batteryLevel)
        return level < 0 ? nil : level
    }

    private static func currentMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// bufferのhostTimeを壁時計（epoch ms）へ写す
    private static func wallMS(forHostTime hostTime: UInt64) -> Int64 {
        WatchChunkClock.wallMS(
            hostTime: hostTime, nowHostTime: mach_absolute_time(), nowWallMS: currentMS(),
            ticksToNanos: { UInt64(AVAudioTime.seconds(forHostTime: $0) * 1_000_000_000) })
    }

    private static func chunksDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("chunks", isDirectory: true)
    }

    private static func obsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("obs", isDirectory: true)
    }
}

// MARK: - WCSessionDelegate

extension WatchRecorder: WCSessionDelegate {
    /// watchOSで必須のdelegateメソッド。バックグラウンドの任意スレッドから呼ばれるため`nonisolated`。
    /// 活性化できたら、活性化の前に閉じた小片を送り、diskの小片を`recoverChunks()`で見直す
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated: Bool = activationState == .activated
        let failure: String? = error.map { "WCSessionの有効化に失敗しました: \($0.localizedDescription)" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let failure { self.lastError = failure }
            guard activated else { return }
            self.flushDeferredTransfers()
            self.recoverChunks()
        }
    }

    /// `transferFile`の完了通知。小片は`transferDidFinish`で後始末する（成功なら本体とsidecarを削除、
    /// 失敗ならfileを残して1回だけ個別に送り直す）。記録ファイル（obs）は`pendingNames`に数えず、
    /// 成功なら消し、失敗なら残して次の起動の`obsLog.resendLeftovers`に任せる。
    /// どちらも結果を`transferFinished` / `transferFailed`として記録する。
    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let url: URL = fileTransfer.file.fileURL
        let metadata: [String: Any] = fileTransfer.file.metadata ?? [:]
        let kind: WatchTransferKind = WatchTransferKind.of(metadata)
        // metadataは[String: Any]でSendableでないため、Taskへ渡す前にここで値だけ取り出す
        let chunkSession: String? = metadata["session"] as? String
        let chunkIndex: Int? = metadata["index"] as? Int
        let failure: String? = error?.localizedDescription

        switch kind {
        case .obs:
            if failure == nil {
                try? FileManager.default.removeItem(at: url)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordTransferResult(session: nil, index: nil, failure: failure)
            }
        case .chunk:
            Task { @MainActor [weak self] in
                self?.transferDidFinish(
                    fileURL: url, fileName: url.lastPathComponent, session: chunkSession, index: chunkIndex,
                    failure: failure)
            }
        }
    }

    /// 到達できるようになった時に、溜まった小片を処理させる合図を送る
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.reachabilityChanged()
        }
    }
}

// MARK: - QueueDepthCounter

/// tapが積んだ未処理のbuffer数。tapのclosure（audio thread）は`yield`の直前に`increment()`だけを呼び、
/// feedTaskがbufferを受けたら`decrement()`する。ロックを取らずにaudio threadから触れるよう`Atomic`にする
final class QueueDepthCounter: Sendable {
    private let count = Atomic<Int>(0)

    func increment() {
        count.add(1, ordering: .relaxed)
    }

    func decrement() {
        count.subtract(1, ordering: .relaxed)
    }

    var value: Int {
        count.load(ordering: .relaxed)
    }
}

// MARK: - ChunkWriter

/// `ChunkWriter.append`へ渡す、小片の要約に足す値
struct ChunkAppendContext: Sendable {
    let batteryLevel: Double?
    let queueDepth: Int
}

/// 現在の小片ファイルへPCM bufferを直列に書き込み、累積frame数が`chunkDurationSeconds`分に達したら
/// 閉じて次のファイルへrotateする。小片は開いた時点でsidecar（未完了）を書き、閉じた時に完了へ書き直す。
/// 閉じた小片の転送は呼び出し側（`WatchRecorder.chunkClosed`）が行う。
/// `AVAudioFile`はcompressed(AAC)設定で開き、`commonFormat`/`interleaved`はtapのnative formatに
/// 合わせるため変換無しで書き込める（sample rateもtapのnative rateをそのまま使い、Watch側では
/// 16kHzへのresampleをしない。実際のsample rateは`WatchChunkMetadata.sampleRate`でiPhone側へ伝える）。
actor ChunkWriter {
    enum AppendOutcome: Sendable, Equatable {
        case ok
        case chunkQueued(WatchChunkMetadata)
        /// 小片は閉じたが、次の小片を開けなかった
        case chunkQueuedThenWriteFailed(WatchChunkMetadata, String)
        case writeFailed(String)
    }

    private let session: String
    private let sampleRate: Double
    private let device: String
    private let deviceName: String
    private let owner: String
    private let chunkFrameLimit: AVAudioFramePosition
    private let chunksDirectory: URL
    private let fileSettings: [String: Any]
    private let commonFormat: AVAudioCommonFormat
    private let interleaved: Bool

    private var index = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentOpenedAtMS: Int64
    private var framesWrittenInChunk: AVAudioFramePosition = 0
    /// 待ち行列の溢れで閉じたい。次のbufferを書く直前に閉じる（停止の時に空の小片を作らない）
    private var closeBeforeNextWrite = false
    private var clock: WatchChunkClock
    private var telemetry = ChunkTelemetry()

    init(
        session: String,
        inputFormat: AVAudioFormat,
        device: String,
        deviceName: String,
        owner: String,
        chunkDurationSeconds: Double,
        chunksDirectory: URL
    ) throws {
        self.session = session
        self.sampleRate = inputFormat.sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.chunkFrameLimit = AVAudioFramePosition(
            (chunkDurationSeconds * inputFormat.sampleRate).rounded())
        self.chunksDirectory = chunksDirectory
        self.commonFormat = inputFormat.commonFormat
        self.interleaved = inputFormat.isInterleaved
        self.clock = WatchChunkClock(sampleRate: inputFormat.sampleRate)
        self.fileSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 32000,
        ]
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let openedAtMS = Self.nowMS()
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: 0, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        self.currentFile = file
        self.currentURL = url
        self.currentOpenedAtMS = openedAtMS
        Self.writeSidecar(
            for: url, complete: false,
            metadata: Self.makeMetadata(
                session: session, index: 0, startAtMS: openedAtMS, sampleRate: inputFormat.sampleRate,
                device: device, deviceName: deviceName, owner: owner),
            openedAtMS: openedAtMS, durationMS: nil)
    }

    /// bufferを現在のfileへ書き込む。`wallMS`はそのbufferの壁時計での時刻。小片の最初のbufferなら、
    /// それを小片の開始にする。rotationの閾値に達したら閉じて次のfileを開く。
    func append(_ buffer: sending AVAudioPCMBuffer, wallMS: Int64, context: ChunkAppendContext) -> AppendOutcome {
        // 上限に達していても、次のbufferが来るまで閉じない。停止で閉じる小片が空にならず`isFinal`を付けられる
        var rotated: WatchChunkMetadata?
        if WatchChunkRotation.shouldCloseBeforeWriting(
            framesInChunk: Int64(framesWrittenInChunk), limit: Int64(chunkFrameLimit), overflowPending: closeBeforeNextWrite)
        {
            closeBeforeNextWrite = false
            let outcome = rotate()
            switch outcome {
            case .chunkQueued(let metadata):
                rotated = metadata
            case .ok:
                break
            case .chunkQueuedThenWriteFailed, .writeFailed:
                return outcome
            }
        }
        guard let currentFile, let currentURL else {
            if let rotated { return .chunkQueuedThenWriteFailed(rotated, "録音ファイルが開かれていません") }
            return .writeFailed("録音ファイルが開かれていません")
        }
        do {
            try currentFile.write(from: buffer)
        } catch {
            let message = "小片の書き込みに失敗しました: \(error.localizedDescription)"
            if let rotated { return .chunkQueuedThenWriteFailed(rotated, message) }
            return .writeFailed(message)
        }
        let frames = AVAudioFramePosition(buffer.frameLength)
        framesWrittenInChunk += frames
        if clock.bufferArrived(wallMS: wallMS, frames: Int(frames)) {
            // 開いた時の仮の`startAtMS`を、最初のbufferの時刻で1回だけ書き直す
            Self.writeSidecar(
                for: currentURL, complete: false, metadata: baseMetadata(startAtMS: wallMS),
                openedAtMS: currentOpenedAtMS, durationMS: nil)
        }
        telemetry.add(
            dbfs: AudioLevel.dbfs(buffer), batteryLevel: context.batteryLevel, queueDepth: context.queueDepth)
        if let rotated { return .chunkQueued(rotated) }
        return .ok
    }

    /// 待ち行列の溢れで今の小片を閉じる印を付ける（最後の小片ではないので`isFinal`は付けない）。
    /// 実際に閉じるのは次のbufferを書く直前で、次の小片はそのbufferで始まる
    func closeForOverflow() -> AppendOutcome {
        closeBeforeNextWrite = true
        return .ok
    }

    /// 収録停止時。書きかけの最後の小片があれば閉じる。戻り値は閉じた小片のmetadata。
    /// `isFinal`は利用者の停止と自動停止の時だけ`true`
    func finish(isFinal: Bool) -> WatchChunkMetadata? {
        sealCurrentFile(isFinal: isFinal)
    }

    private func rotate() -> AppendOutcome {
        let queued = sealCurrentFile(isFinal: false)
        // 何も書けていない小片は消えて番号を使わない（indexに穴を作らない）
        if queued != nil { index += 1 }
        do {
            try openNextFile()
        } catch {
            let message = "次の小片ファイルの作成に失敗しました: \(error.localizedDescription)"
            if let queued {
                return .chunkQueuedThenWriteFailed(queued, message)
            }
            return .writeFailed(message)
        }
        if let queued {
            return .chunkQueued(queued)
        }
        return .ok
    }

    /// 非asyncなactor initはnonisolatedで隔離メソッドを呼べないため、
    /// ファイルを開く処理はstaticにしてinitと`openNextFile()`の両方から使う
    private static func openFile(
        directory: URL, session: String, index: Int, settings: [String: Any],
        commonFormat: AVAudioCommonFormat, interleaved: Bool
    ) throws -> (AVAudioFile, URL) {
        let url = ChunkFiles.audioURL(directory: directory, session: session, index: index)
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: commonFormat, interleaved: interleaved)
        return (file, url)
    }

    private func openNextFile() throws {
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        currentFile = file
        currentURL = url
        currentOpenedAtMS = Self.nowMS()
        Self.writeSidecar(
            for: url, complete: false, metadata: baseMetadata(startAtMS: currentOpenedAtMS),
            openedAtMS: currentOpenedAtMS, durationMS: nil)
    }

    /// 今の小片を閉じてsidecarを完了にする。何も書けていなければfileとsidecarを消して`nil`
    private func sealCurrentFile(isFinal: Bool) -> WatchChunkMetadata? {
        guard let url = currentURL else { return nil }
        currentFile = nil
        currentURL = nil
        framesWrittenInChunk = 0
        guard let closed = clock.closeChunk() else {
            // 何も書けていない（開始直後に停止した等）空fileは転送せず捨てる。
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: ChunkFiles.sidecarURL(for: url))
            telemetry.reset()
            return nil
        }
        var base = baseMetadata(startAtMS: closed.startMS)
        base.durationMS = closed.durationMS
        base.isFinal = isFinal ? true : nil
        let metadata: WatchChunkMetadata = telemetry.applied(to: base)
        telemetry.reset()
        Self.writeSidecar(
            for: url, complete: true, metadata: metadata, openedAtMS: currentOpenedAtMS,
            durationMS: closed.durationMS)
        return metadata
    }

    private func baseMetadata(startAtMS: Int64) -> WatchChunkMetadata {
        Self.makeMetadata(
            session: session, index: index, startAtMS: startAtMS, sampleRate: sampleRate,
            device: device, deviceName: deviceName, owner: owner)
    }

    private static func makeMetadata(
        session: String, index: Int, startAtMS: Int64, sampleRate: Double,
        device: String, deviceName: String, owner: String
    ) -> WatchChunkMetadata {
        WatchChunkMetadata(
            session: session, index: index, startAtMS: startAtMS,
            sampleRate: sampleRate, device: device, deviceName: deviceName, owner: owner)
    }

    /// sidecarを`.atomic`で書く。失敗しても録音は止めない（その小片は強制終了の時に救えないだけ）
    private static func writeSidecar(
        for url: URL, complete: Bool, metadata: WatchChunkMetadata, openedAtMS: Int64, durationMS: Int64?
    ) {
        guard let json = try? metadata.encodedJSON() else { return }
        let sidecar = WatchChunkSidecar(
            complete: complete, session: metadata.session, index: metadata.index, openedAtMS: openedAtMS,
            durationMS: durationMS, metadataJSON: json)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: ChunkFiles.sidecarURL(for: url), options: .atomic)
    }

    private static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - ChunkTransfer

/// 転送完了後の後始末。`WCSession`のAPI自体はスレッドセーフなのでactor化不要。
enum ChunkTransfer {
    static func cleanup(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: ChunkFiles.sidecarURL(for: fileURL))
    }
}
