import AVFoundation
import Foundation
import NotetakeCore
import SwiftUI
import Synchronization
import WatchConnectivity
import WatchKit

/// Watchの録音状態と、AVAudioEngine → 20秒ごとのAAC小片 → `WCSession.transferFile`の一連を管理する。
/// v1は前面のみで録音する前提（バックグラウンド録音の継続は保証しない）。
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
    }

    private enum DefaultsKey {
        static let ownerName = "ownerName"
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
    private(set) var elapsedSeconds: Int = 0
    /// 転送完了（`didFinish`のsuccess）がまだ届いていない小片の数。起動時に再送をキューした
    /// leftoverも含む。
    private(set) var pendingTransfers: Int = 0
    var lastError: String?

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

    private let engine = AVAudioEngine()
    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var writer: ChunkWriter?
    private var queueCounter = QueueDepthCounter()
    private let obsLog: WatchObsLog
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
        ownerName = UserDefaults.standard.string(forKey: DefaultsKey.ownerName) ?? "私"
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        // 前回の異常終了などで送り切れなかった小片をsidecarのmetadataから復元して再送する。
        pendingTransfers = ChunkTransfer.resendLeftovers(in: Self.chunksDirectory())
        let launchedAtMS = Self.currentMS()
        obsLog.resendLeftovers(nowMS: launchedAtMS)
        obsLog.record(.init(atMS: launchedAtMS, event: .launched))
        observeAudioNotifications()
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

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .default)
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
                sessionStartMS: sessionStartMS,
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
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            // yieldの前に増やす（feedTaskの`decrement()`が先に走って一瞬負になるのを防ぐ）
            counter.increment()
            continuation.yield(CapturedBuffer(buffer: buffer))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            bufferContinuation = nil
            self.writer = nil
            Task { _ = await writer.finish() }
            try? audioSession.setActive(false)
            startFailed("録音の開始に失敗しました: \(error.localizedDescription)", session: sessionID)
            return
        }

        currentSessionID = sessionID
        let sampleRate: Double = inputFormat.sampleRate
        feedTask = Task { @MainActor [weak self] in
            var lastSampledAtMS: Int64 = 0
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
                let context = ChunkAppendContext(batteryLevel: self.cachedBatteryLevel, queueDepth: depth)
                let outcome = await writer.append(captured.buffer, context: context)
                switch outcome {
                case .ok:
                    break
                case .chunkQueued(let metadata):
                    self.chunkClosed(metadata)
                case .chunkQueuedThenWriteFailed(let metadata, let message):
                    self.chunkClosed(metadata)
                    self.writeFailed(message, session: sessionID)
                case .writeFailed(let message):
                    self.writeFailed(message, session: sessionID)
                }
            }
        }

        elapsedSeconds = 0
        nowMS = sessionStartMS
        dispatch(.started(atMS: sessionStartMS))
        obsLog.record(.init(atMS: sessionStartMS, event: .started, session: sessionID))
        startElapsedTimer()
    }

    func stop() {
        guard isRecording else { return }
        let stoppedAtMS = Self.currentMS()
        dispatch(.stopped(atMS: stoppedAtMS))
        obsLog.record(.init(atMS: stoppedAtMS, event: .stopped, session: currentSessionID))
        tearDown()
    }

    /// 録音の後始末。`stop()`と、録音中に`.halted`へ移った時（`dispatch`）の両方から呼ぶ。
    /// 音声の入口を止め、積み残しのbufferを書き切って最後の小片を閉じ、記録をiPhoneへ送る
    private func tearDown() {
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
        currentSessionID = nil

        // feedTaskが積み残しのbufferを全部writerへ渡し終えるのを待ってから、最後の小片を
        // 閉じて転送する（そうしないと末尾の数百msが失われる）。
        tearDownTask = Task { @MainActor [weak self] in
            await feedTask?.value
            if let metadata = await writer?.finish() {
                self?.chunkClosed(metadata)
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self?.obsLog.ship(nowMS: Self.currentMS())
            self?.tearDownTask = nil
        }
    }

    /// 唯一の`phase`の更新口。録音中から`.halted`へ移った時は、止まった理由を記録して後始末する。
    /// `phase`は`.halted`のまま残し、画面に「止まりました」を出し続ける。中断が終わっても自動では再開しない
    private func dispatch(_ event: WatchRecordingEvent) {
        let previous = phase
        let next = WatchRecordingReducer.reduce(previous, event, queueDepth: max(0, queueCounter.value))
        phase = next
        guard case .recording = previous, case .halted(let reason, let atMS, let detail) = next else { return }
        obsLog.record(
            .init(atMS: atMS, event: .halted, session: currentSessionID, detail: Self.haltDetail(reason, detail)))
        tearDown()
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
        let configuration: NSObjectProtocol = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] (_: Notification) in
            Task { @MainActor [weak self] in
                self?.configurationChanged()
            }
        }
        notificationObservers = [interruption, reset, configuration]
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
        let startedAt = Date()
        elapsedTask = Task { @MainActor [weak self] in
            while let self, self.isRecording {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isRecording else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
                // `nowMS`の更新で`display`が再評価される。bufferが途絶えて`dispatch`が呼ばれない間も
                // 「録音中」のまま固まらず、noAudioHaltMSを超えたら警告に変わる
                self.nowMS = Self.currentMS()
                self.cachedBatteryLevel = Self.currentBatteryLevel()
            }
        }
    }

    /// 小片が閉じて転送に入った時の後始末。記録に残し、区切りごとにiPhoneへ送る
    private func chunkClosed(_ metadata: WatchChunkMetadata) {
        pendingTransfers += 1
        let closedAtMS: Int64 = Self.currentMS()
        obsLog.record(
            .init(
                atMS: closedAtMS, event: .chunkClosed, session: metadata.session, index: metadata.index,
                value: metadata.maxDBFS))
        if (metadata.index + 1) % WatchObsLog.shipEveryChunks == 0 {
            obsLog.ship(nowMS: closedAtMS)
        }
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

    /// 電池残量（0...1）。監視が無効などで負の値が返る時はnil
    private static func currentBatteryLevel() -> Double? {
        let level = Double(WKInterfaceDevice.current().batteryLevel)
        return level < 0 ? nil : level
    }

    private static func currentMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
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
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.lastError = "WCSessionの有効化に失敗しました: \(error.localizedDescription)"
        }
    }

    /// `transferFile`の完了通知。小片は成功なら本体とsidecarを削除し、失敗ならファイルを残して
    /// （`WCSession`が自動で再試行するが、アプリ再起動時にも`resendLeftovers`から拾えるように）
    /// `lastError`に記録するだけにとどめる。記録ファイル（obs）は`pendingTransfers`に数えず、
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
            if failure == nil {
                ChunkTransfer.cleanup(fileURL: url)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure {
                    self.lastError = "小片の転送に失敗しました: \(failure)"
                } else {
                    self.pendingTransfers = max(0, self.pendingTransfers - 1)
                }
                self.recordTransferResult(session: chunkSession, index: chunkIndex, failure: failure)
            }
        }
    }
}

extension WatchRecorder {
    fileprivate func recordTransferResult(session: String?, index: Int?, failure: String?) {
        obsLog.record(
            .init(
                atMS: Self.currentMS(),
                event: failure == nil ? .transferFinished : .transferFailed,
                session: session, index: index, detail: failure))
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
/// 閉じて次のファイルへrotateする。閉じた小片は`ChunkTransfer`でsidecar付きの転送キューに入れる。
/// `AVAudioFile`はcompressed(AAC)設定で開き、`commonFormat`/`interleaved`はtapのnative formatに
/// 合わせるため変換無しで書き込める（sample rateもtapのnative rateをそのまま使い、Watch側では
/// 16kHzへのresampleをしない。実際のsample rateは`WatchChunkMetadata.sampleRate`でiPhone側へ伝える）。
actor ChunkWriter {
    enum AppendOutcome: Sendable, Equatable {
        case ok
        case chunkQueued(WatchChunkMetadata)
        /// 小片は閉じて転送に入ったが、次の小片を開けなかった
        case chunkQueuedThenWriteFailed(WatchChunkMetadata, String)
        case writeFailed(String)
    }

    private let session: String
    private let sessionStartMS: Int64
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
    private var currentChunkStartMS: Int64
    private var framesWrittenInChunk: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var telemetry = ChunkTelemetry()

    init(
        session: String,
        sessionStartMS: Int64,
        inputFormat: AVAudioFormat,
        device: String,
        deviceName: String,
        owner: String,
        chunkDurationSeconds: Double,
        chunksDirectory: URL
    ) throws {
        self.session = session
        self.sessionStartMS = sessionStartMS
        self.sampleRate = inputFormat.sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.chunkFrameLimit = AVAudioFramePosition(
            (chunkDurationSeconds * inputFormat.sampleRate).rounded())
        self.chunksDirectory = chunksDirectory
        self.commonFormat = inputFormat.commonFormat
        self.interleaved = inputFormat.isInterleaved
        self.currentChunkStartMS = sessionStartMS
        self.fileSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 32000,
        ]
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        self.currentFile = file
        self.currentURL = url
    }

    /// bufferを現在のfileへ書き込む。rotationの閾値に達したら閉じて転送キューへ入れ、次のfileを開く。
    func append(_ buffer: sending AVAudioPCMBuffer, context: ChunkAppendContext) -> AppendOutcome {
        guard let currentFile else {
            return .writeFailed("録音ファイルが開かれていません")
        }
        do {
            try currentFile.write(from: buffer)
        } catch {
            return .writeFailed("小片の書き込みに失敗しました: \(error.localizedDescription)")
        }
        framesWrittenInChunk += AVAudioFramePosition(buffer.frameLength)
        telemetry.add(
            dbfs: AudioLevel.dbfs(buffer), batteryLevel: context.batteryLevel, queueDepth: context.queueDepth)
        guard framesWrittenInChunk >= chunkFrameLimit else {
            return .ok
        }

        let queued = closeAndTransferCurrentFile()
        totalFrames += framesWrittenInChunk
        framesWrittenInChunk = 0
        index += 1
        currentChunkStartMS = sessionStartMS + Int64((Double(totalFrames) / sampleRate * 1000).rounded())
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
            return AppendOutcome.chunkQueued(queued)
        }
        return AppendOutcome.ok
    }

    /// 収録停止時。書きかけの最後の小片があれば閉じて転送する。戻り値は転送をキューした小片のmetadata。
    func finish() -> WatchChunkMetadata? {
        closeAndTransferCurrentFile()
    }

    /// 非asyncなactor initはnonisolatedで隔離メソッドを呼べないため、
    /// ファイルを開く処理はstaticにしてinitと`openNextFile()`の両方から使う
    private static func openFile(
        directory: URL, session: String, index: Int, settings: [String: Any],
        commonFormat: AVAudioCommonFormat, interleaved: Bool
    ) throws -> (AVAudioFile, URL) {
        let url = directory.appendingPathComponent("\(session)-\(index).m4a")
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
    }

    private func closeAndTransferCurrentFile() -> WatchChunkMetadata? {
        guard let url = currentURL else { return nil }
        currentFile = nil
        currentURL = nil
        guard framesWrittenInChunk > 0 else {
            // 何も書けていない（開始直後に停止した等）空fileは転送せず捨てる。
            try? FileManager.default.removeItem(at: url)
            telemetry.reset()
            return nil
        }
        let base = WatchChunkMetadata(
            session: session, index: index, startAtMS: currentChunkStartMS,
            sampleRate: sampleRate, device: device, deviceName: deviceName, owner: owner)
        let metadata: WatchChunkMetadata = telemetry.applied(to: base)
        telemetry.reset()
        ChunkTransfer.send(fileURL: url, metadata: metadata)
        return metadata
    }
}

// MARK: - ChunkTransfer

/// `WCSession.transferFile`まわりの共通処理。sidecar(`<file>.json`)にmetadataを書いてから転送し、
/// 転送完了で両方消す。sidecarがあるおかげで、送信できないまま次回起動を迎えた小片も
/// metadataを失わずに再送できる。`WCSession`のAPI自体はスレッドセーフなのでactor化不要。
enum ChunkTransfer {
    private static func sidecarURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("json")
    }

    /// sidecarを書いてから`transferFile`を呼ぶ。sidecarの書き込みに失敗しても転送自体は試みる
    /// （その場合は再送に必要なmetadataが復元できないだけで、初回の転送は失敗しない）。
    static func send(fileURL: URL, metadata: WatchChunkMetadata) {
        if let data = try? JSONSerialization.data(withJSONObject: metadata.metadata) {
            try? data.write(to: sidecarURL(for: fileURL))
        }
        WCSession.default.transferFile(fileURL, metadata: metadata.metadata)
    }

    /// 転送完了後の後始末。
    static func cleanup(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: fileURL))
    }

    /// 起動時: `directory`配下に残っている`.m4a`のうちsidecarからmetadataを復元できるものを
    /// 再送キューに入れる。復元できない孤児（sidecarが無い/壊れている）は掃除のため削除する。
    /// 戻り値: 再送をキューした件数（`pendingTransfers`の初期値に使う）。
    @discardableResult
    static func resendLeftovers(in directory: URL) -> Int {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else {
            return 0
        }
        var queued = 0
        for url in files where url.pathExtension == "m4a" {
            let sidecar = sidecarURL(for: url)
            guard
                let data = try? Data(contentsOf: sidecar),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let metadata = WatchChunkMetadata(metadata: object)
            else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: sidecar)
                continue
            }
            WCSession.default.transferFile(url, metadata: metadata.metadata)
            queued += 1
        }
        return queued
    }
}
