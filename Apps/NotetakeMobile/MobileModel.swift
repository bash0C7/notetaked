import Foundation
import NotetakeCore
import UIKit
import WatchConnectivity

/// `self`（`@MainActor`だがSendable宣言はしていないクラス）を、actor（`PeerClient`/`Recorder`）から
/// 呼ばれる`@Sendable`closureの中で弱参照するための薄いbox。
/// `value`への実際のアクセスは常に`Task { @MainActor in }`の中で行うため`@unchecked`は安全
/// （`AudioConverter`が同じ考え方で`@unchecked Sendable`にしているのに倣う）。
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// iPhone appの中心的な状態: 設定・outbox・PeerClient・Recorderをまとめ、UIへ状態を出す
@MainActor
@Observable
final class MobileModel {
    // ContentViewが`$model.settings.ownerName`のようにBindingを辿れるよう`var`にする
    // （実際に再代入することはない）
    var settings = MobileSettings()

    private(set) var isRecording = false
    private(set) var peerState: PeerClientState = .idle
    private(set) var pendingCount = 0
    private(set) var lastText = ""
    /// WatchRelayが現在扱っているWatch session（=収録）の数。ContentViewに「Watch: N stream」で出す
    private(set) var watchStreams = 0
    var lastError: String?
    /// 直近の取り込み音量。Recorderからの通知で伸び、取り込みの開始で作り直す
    private(set) var levelHistory = LevelHistory()
    /// 最後に確定した文字が出た時刻（epoch ms）。取り込みの開始で`nil`へ戻る
    private(set) var lastTextAtMS: Int64?
    /// iPhoneが組み立てたWatchの状態。小片の受領・記録・文字起こし・受け取り箱の件数で更新し、Macへも送る
    private(set) var watchStatus: WatchStatusSnapshot?

    private let outbox: Outbox
    private let recorder = Recorder()
    private var peerClient: PeerClient?
    private var recordingStartedAtMS: Int64?
    /// 開始と停止を1本の列にする。準備中の停止は開始が終わってから`recorder.stop()`へ届き、
    /// 再開は停止の完了を待つ（`Recorder.start`が`await`の間に再入されるのを避ける）
    private var lifecycleTask: Task<Void, Never>?
    /// 一度でも`connected`になったか。切断（黄）は、つながっていた後だけ出す
    private var hasEverConnected = false
    private var watchRelay: WatchRelay?
    // `WCSession.delegate`はweak参照のため、こちらで強参照を保持し続ける必要がある
    private var watchSessionDelegate: WatchSessionDelegate?
    private let inboxStore = WatchInboxStore.standard()
    /// Watchの小片を1本の列で処理する。`connectWatch`で作る
    private var watchIntake: WatchIntakeQueue?

    // 合図で起こされた時のbackground task（1本だけ）
    private var wakeResponder = WatchWakeResponder()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var wakeMonitorTask: Task<Void, Never>?

    // Watchの状態の組み立てとMacへの送信（間引き）
    private var watchTracker = WatchStatusTracker()
    private var lastSentStatus: WatchStatusSnapshot?
    private var lastStatusSentAtMS: Int64 = 0
    private var statusSendTask: Task<Void, Never>?
    private static let statusMinIntervalMS: Int64 = 5_000
    /// background taskを終える前にstreamを閉じる（`finishAll`は最大で数秒かかる）のに必要な残り時間
    private static let finishStreamsMinRemainingSeconds: Double = 10
    private var watchDeviceNames: [String: String] = [:]
    private static let retentionDefaultsKey = "watchRetentionLastRunMS"
    private static let retentionIntervalMS: Int64 = 86_400_000

    init() {
        outbox = Outbox(directory: Self.applicationSupportDirectory())
        // ペアリングコード未設定でもPeerClientは作っておく（`enqueue`がoutboxへのappendを
        // 兼ねるため、録音がペアリング前でも蓄積転送できるようにする）。browsingはコードが
        // あるときだけ始める
        if let data = try? Data(contentsOf: Self.watchStatusURL()),
            let json = String(data: data, encoding: .utf8),
            let saved = try? WatchStatusSnapshot.decode(json: json)
        {
            watchTracker = WatchStatusTracker(snapshot: saved)
            watchStatus = saved
        }
        connectPeer()
        connectWatch()
        Task { await self.refreshPendingCount() }
        didBecomeActive()
    }

    /// `Documents/watch-status.json`。更新のたびに保存し、起動時に読み戻す
    private static func watchStatusURL() -> URL {
        let base: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("watch-status.json")
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Notetake", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Peer connection

    /// 現在の設定でPeerClientを(再)生成し、browsingを開始する
    private func connectPeer() {
        let hello = HelloMessage(
            device: settings.deviceID,
            deviceName: settings.deviceName,
            owner: settings.ownerName,
            platform: .ios
        )
        let box = WeakBox(self)
        let client = PeerClient(
            hello: hello,
            pairingCode: settings.pairingCode,
            outbox: outbox,
            onState: { state in
                Task { @MainActor in
                    guard let model = box.value else { return }
                    model.peerState = state
                    if case .connected = state {
                        model.hasEverConnected = true
                        RelayTrace.record(.peerConnected)
                        // 接続の直後に1回、今のWatchの状態を送る
                        model.sendWatchStatusIfNeeded(force: true)
                    }
                    await model.refreshPendingCount()
                }
            },
            onAck: { seq in
                Task { @MainActor in
                    guard let model = box.value else { return }
                    model.wakeResponder.activity(atMS: Self.currentMS())
                    RelayTrace.record(.segAcked, seq: seq)
                    await model.refreshPendingCount()
                }
            }
        )
        peerClient = client
        if !settings.pairingCode.isEmpty {
            Task { await client.start() }
        }
    }

    /// ペアリングコード保存後に呼ぶ: 既存接続を止め、新しいコードで作り直す
    /// （PSKはPeerClientのinit時に固定されるため、コードが変わったら差し替える）
    func pairingCodeDidChange() {
        let previous = peerClient
        peerClient = nil
        peerState = .idle
        Task { await previous?.stop() }
        connectPeer()
    }

    // MARK: - Watch relay

    /// WatchRelayを起動し、`WCSession.isSupported()`ならdelegateを登録してactivateする。
    /// Watch非対応（実機がWatch非対応、または未ペアリング）の場合もrelay自体は作っておく
    /// （何も受信しないだけで無害。idleループも最初の小片が届くまで動かない）。
    private func connectWatch() {
        let box = WeakBox(self)
        let relay = WatchRelay(
            locale: Self.locale,
            store: inboxStore,
            ledgerURL: Self.applicationSupportDirectory().appendingPathComponent("watch-ledger.json"),
            onSegment: { segment in
                // WatchRelay側のpieceTaskはこのclosureの完了をawaitしてから次のpieceへ進む
                // （WatchRelay.init参照）。ここで内側のTaskを`await`せず`Task { @MainActor in }`
                // だけ積んで即returnすると、複数segmentのMainActor移送がFIFO順で実行される保証が
                // 無くなり、outbox.nextSeq()の採番順が届いた順と食い違いうる（HANDOFFに残る
                // DaemonClientの同種の懸念と同じ問題）。そのためTaskの完了を待ちきる
                let task = Task { @MainActor in
                    guard let model = box.value else { return }
                    await model.handleWatchSegment(segment)
                }
                await task.value
            },
            onStreamCount: { count in
                Task { @MainActor in
                    box.value?.watchStreams = count
                }
            },
            onChunkFed: { meta in
                RelayTrace.record(.chunkFed, device: meta.device, session: meta.session, index: meta.index)
                Task { @MainActor in
                    box.value?.wakeResponder.activity(atMS: Self.currentMS())
                }
            },
            onInboxChange: {
                Task { @MainActor in
                    box.value?.refreshInboxCount()
                }
            }
        )
        watchRelay = relay
        // 列は`relay`をfeederに作る。`relay`は列の未処理件数を後から受け取る
        let intake = WatchIntakeQueue(feeder: relay)
        watchIntake = intake
        Task { await relay.attach(backlog: { intake.backlog }) }
        guard WCSession.isSupported() else { return }
        let delegate = WatchSessionDelegate(
            store: inboxStore,
            intake: intake,
            onReceipt: { receipt, deviceName in
                Task { @MainActor in
                    guard let model = box.value else { return }
                    model.wakeResponder.activity(atMS: Self.currentMS())
                    model.watchDeviceNames[receipt.device] = deviceName
                    model.watchTracker.chunkReceived(receipt, deviceName: deviceName)
                    model.refreshInboxCount()
                    model.watchStatusChanged()
                }
            },
            onObs: { records, device in
                Task { @MainActor in
                    box.value?.handleWatchObs(records, device: device)
                }
            },
            onWake: { wake in
                // `box.value`は合図の時点で生きている。いなければ受領時刻だけ返す
                box.value?.watchWoke(wake) ?? Self.currentMS()
            }
        )
        watchSessionDelegate = delegate
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    // MARK: - Watchに起こされた時

    /// Watchの合図（`didReceiveMessage`）で呼ばれる。背面ならbackground taskを取り、起きている約30秒のうちに
    /// 受信→文字起こし→Macへの送信を済ませる。返す受領時刻は合図への返事に載る
    /// （background taskを取った後に返すので、返事の前にsuspendされない）
    func watchWoke(_ wake: WatchWakeMessage) -> Int64 {
        let nowMS = Self.currentMS()
        let application = UIApplication.shared
        let state = application.applicationState
        RelayTrace.record(
            .wakeMessage, appState: Self.appStateName(state), remainingSeconds: Self.remainingSeconds(application),
            device: wake.device, session: wake.session, index: wake.index)
        switch wakeResponder.woke(appIsActive: state == .active, atMS: nowMS) {
        case .beginTask:
            beginWakeTask(application)
        case .keepTask, .foreground:
            break
        }
        Task { await self.peerClient?.wake() }
        recoverInbox()
        return nowMS
    }

    private func beginWakeTask(_ application: UIApplication) {
        backgroundTaskID = application.beginBackgroundTask(withName: "watch-relay") { [weak self] in
            // 期限。重い処理はせず、taskを終えて記録するだけ
            MainActor.assumeIsolated { self?.wakeTaskExpired() }
        }
        RelayTrace.record(
            .taskBegan, appState: Self.appStateName(application.applicationState),
            remainingSeconds: Self.remainingSeconds(application))
        wakeMonitorTask?.cancel()
        wakeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if await self.endWakeTaskIfDone() { return }
            }
        }
    }

    /// 1秒ごと。仕事が済んだか期限が近ければtaskを終える。終えたらtrue
    private func endWakeTaskIfDone() async -> Bool {
        guard wakeResponder.holdsTask else { return true }
        let progress = await wakeProgress()
        guard wakeResponder.shouldEnd(progress) else { return false }
        // 台帳に処理済みと記録した小片の末尾の音声は、次の合図までanalyzerの中で確定せずに残る。
        // suspendの間に落とされると失われるので、期限に余裕がある時は、閉じて確定させてから終える。
        // 閉じて出たsegはoutboxに残り、接続中なら送られ、ackが間に合わなければ次の接続で再送される
        if progress.remainingSeconds > Self.finishStreamsMinRemainingSeconds {
            let generation = wakeResponder.taskGeneration
            await watchRelay?.finishAll()
            // finishAllの間に次の合図が来て、taskを取り直したり新しい小片を受けたりしうる。
            // 新しい進み具合で判定し直し、古い監視が新しいtaskを終えない
            switch wakeResponder.outcomeAfterFinalize(startedGeneration: generation, progress: await wakeProgress()) {
            case .endNow: break
            case .keepMonitoring: return false
            case .taskReplaced: return true
            }
        }
        guard wakeResponder.holdsTask else { return true }
        finishWakeTask(event: .taskEnded)
        return true
    }

    private func wakeProgress() async -> WatchWakeResponder.Progress {
        WatchWakeResponder.Progress(
            intakeBacklog: watchIntake?.backlog ?? 0,
            unackedSegments: await outbox.unacknowledgedCount,
            peerConnected: isPeerConnected,
            remainingSeconds: UIApplication.shared.backgroundTimeRemaining,
            nowMS: Self.currentMS())
    }

    private func wakeTaskExpired() {
        guard wakeResponder.holdsTask else { return }
        finishWakeTask(event: .taskExpired)
    }

    /// taskを終える（取り残すとiOSにappを殺される）。止まった小片は受け取り箱に残り、
    /// 次の合図か前面化の`recover`で続きから処理される
    private func finishWakeTask(event: RelayTraceEvent) {
        wakeMonitorTask?.cancel()
        wakeMonitorTask = nil
        let identifier = backgroundTaskID
        backgroundTaskID = .invalid
        wakeResponder.taskEnded()
        let application = UIApplication.shared
        RelayTrace.record(
            event, appState: Self.appStateName(application.applicationState),
            remainingSeconds: Self.remainingSeconds(application))
        if identifier != .invalid { application.endBackgroundTask(identifier) }
    }

    private static func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// 前面の時は残り時間が無限大に近いので記録しない
    private static func remainingSeconds(_ application: UIApplication) -> Double? {
        let remaining = application.backgroundTimeRemaining
        return remaining < 100_000 ? remaining : nil
    }

    // MARK: - 受け取り箱の回収と保持期間

    /// 起動時と前面になった時に呼ぶ。受け取り箱の小片を回収し、保持期間を過ぎたものを消す
    func didBecomeActive() {
        recoverInbox()
        applyRetentionIfDue()
    }

    private func recoverInbox() {
        guard let intake = watchIntake else { return }
        let store = inboxStore
        let nowMS = Self.currentMS()
        Task.detached {
            _ = store.recover(into: intake, nowMS: nowMS)
        }
        refreshInboxCount()
    }

    /// 受け取り箱の未処理件数をWatchの状態へ反映する
    private func refreshInboxCount() {
        watchTracker.inboxChanged(pendingCount: inboxStore.pendingCount(), atMS: Self.currentMS())
        watchStatusChanged()
    }

    /// 1日1回まで。`Documents/watch-obs`の記録と受領記録・`Documents/relay-trace`の計測の記録で30日を、
    /// `watch-inbox/failed`で7日を過ぎたものを消し、台帳の30日より古いsessionを消す
    private func applyRetentionIfDue() {
        let nowMS = Self.currentMS()
        let last = Int64(UserDefaults.standard.double(forKey: Self.retentionDefaultsKey))
        guard nowMS - last >= Self.retentionIntervalMS else { return }
        UserDefaults.standard.set(Double(nowMS), forKey: Self.retentionDefaultsKey)
        let store = inboxStore
        let relay = watchRelay
        let dayMS: Int64 = 86_400_000
        Task.detached {
            WatchInboxStore.prune(
                directory: WatchSessionDelegate.watchObsDirectory(), days: RetentionPolicy.receiptDays,
                nowMS: nowMS, matching: { $0.hasPrefix("receipts-") })
            WatchInboxStore.prune(
                directory: WatchSessionDelegate.watchObsDirectory(), days: RetentionPolicy.obsDays,
                nowMS: nowMS, matching: { !$0.hasPrefix("receipts-") })
            WatchInboxStore.prune(
                directory: RelayTrace.directory(), days: RetentionPolicy.obsDays, nowMS: nowMS)
            store.pruneFailed(nowMS: nowMS)
            await relay?.pruneLedger(olderThanMS: nowMS - Int64(RetentionPolicy.obsDays) * dayMS)
        }
    }

    // MARK: - Watchの状態

    private func handleWatchObs(_ records: [WatchObsRecord], device: String) {
        // 小片より先に記録が届いても（開始に失敗した時など）、snapshotを作って反映する
        let name = watchDeviceNames[device]
            ?? watchTracker.snapshot.flatMap { $0.device == device ? $0.deviceName : nil } ?? device
        watchTracker.obsReceived(records, device: device, deviceName: name)
        watchStatusChanged()
    }

    /// trackerの結果を画面・ファイルへ反映し、Macへ送る
    private func watchStatusChanged() {
        watchStatus = watchTracker.snapshot
        if let snapshot = watchStatus, let json = try? snapshot.encodedJSON() {
            try? Data(json.utf8).write(to: Self.watchStatusURL(), options: .atomic)
        }
        sendWatchStatusIfNeeded(force: false)
    }

    /// 変化があった時、最短5秒あけて送る。`force`は接続の直後の1回（間隔と変化の確認を飛ばす）。
    /// 間に合わなかった変化は、5秒たった時に最新の状態を1回送る
    private func sendWatchStatusIfNeeded(force: Bool) {
        guard let snapshot = watchStatus, case .connected = peerState else { return }
        if !force, let last = lastSentStatus {
            var normalized = snapshot
            normalized.updatedAtMS = last.updatedAtMS
            if normalized == last { return }
        }
        let nowMS = Self.currentMS()
        let wait = Self.statusMinIntervalMS - (nowMS - lastStatusSentAtMS)
        if force || wait <= 0 {
            statusSendTask?.cancel()
            statusSendTask = nil
            transmit(snapshot, atMS: nowMS)
            return
        }
        guard statusSendTask == nil else { return }
        statusSendTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.statusSendTask = nil
            if let latest = self.watchStatus { self.transmit(latest, atMS: Self.currentMS()) }
        }
    }

    private func transmit(_ snapshot: WatchStatusSnapshot, atMS: Int64) {
        lastSentStatus = snapshot
        lastStatusSentAtMS = atMS
        let client = peerClient
        Task { await client?.sendWatchStatus(snapshot) }
    }

    /// WatchRelayから届いたSegmentをoutboxへ積む。
    ///
    /// `segment.seq`はWatchRelay内では「そのWatch streamローカルな」連番でしかない。
    /// Outboxはこのiphone 1台につき1本の単調増加するseqカウンタしか持たないため
    /// （`nextSeq()` = ファイル中の最大seq + 1、deviceを区別しない）、ここで
    /// outbox全体のseqへ採番し直す。`device`はWatch自身のidのまま残す。
    ///
    /// Mac側はSegmentを`(device, seq)`でdedupし、deviceごとにseqのcursorを進める
    /// （`ack`はseqしか運ばない）。Watch deviceについて見えるseqは「iPhone全体seqの
    /// 部分列」になるが、部分列であっても厳密に単調増加である（一度採番したseqを
    /// 他のdeviceへ使い回すことはない）ため、Macの単調性チェック・重複排除・ack
    /// cursorの前進は壊れない。
    private func handleWatchSegment(_ segment: Segment) async {
        // seqの採番は`PeerClient.enqueue`→`Outbox.appendAssigningSeq`が原子的に行う
        wakeResponder.activity(atMS: Self.currentMS())
        let seq = await peerClient?.enqueue(segment)
        RelayTrace.record(.segEnqueued, device: segment.device, seq: seq, endAtMS: segment.end)
        watchTracker.textEmitted(segment.text, atMS: Self.currentMS())
        watchStatusChanged()
        await refreshPendingCount()
    }

    // MARK: - Indicator

    func indicator(nowMS: Int64) -> IndicatorMessage {
        IndicatorJudge.judge(SourceIndicatorInput(
            history: levelHistory,
            captureState: isRecording ? .recording : .off,
            captureReason: nil,
            recording: isRecording,
            recordingStartedAtMS: recordingStartedAtMS,
            lastTextAtMS: lastTextAtMS,
            nowMS: nowMS
        ))
    }

    private var isPeerConnected: Bool {
        if case .connected = peerState { return true }
        return false
    }

    var peerIndicator: IndicatorMessage? {
        var connected = false
        if case .connected = peerState { connected = true }
        return IndicatorJudge.judgePeer(wasConnected: hasEverConnected, connected: connected, peerName: "Mac")
    }

    /// 停止直後に遅れて届いた通知は、取り込み中ではないので捨てる
    private func handleLevel(atMS: Int64, dbfs: Double) {
        guard isRecording else { return }
        levelHistory.append(atMS: atMS, dbfs: dbfs)
    }

    private static func currentMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        lastError = nil
        isRecording = true
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            do {
                try await Transcriber.ensureAssets(locale: Self.locale)
                // 準備中に停止が押されたら、マイクを開かずに終える
                guard self.isRecording else { return }
                let session = SessionStore.prefix(for: Date(), timeZone: .current)
                let box = WeakBox(self)
                // 開始前に届く通知は無いので、ここで履歴を作り直す。失敗したらcatchで元へ戻す
                self.levelHistory = LevelHistory()
                self.lastTextAtMS = nil
                try await self.recorder.start(
                    locale: Self.locale,
                    onPiece: { piece, dbfs, direction in
                        Task { @MainActor in
                            guard let model = box.value else { return }
                            await model.handleFinalPiece(piece, dbfs: dbfs, direction: direction, session: session)
                        }
                    },
                    onLevel: { atMS, dbfs in
                        Task { @MainActor in
                            box.value?.handleLevel(atMS: atMS, dbfs: dbfs)
                        }
                    }
                )
                // recorder.startが戻ってから数える。開始前に停止が押されていたらマイクを閉じる
                if self.isRecording {
                    self.recordingStartedAtMS = Self.currentMS()
                } else {
                    try? await self.recorder.stop()
                }
            } catch {
                self.isRecording = false
                self.levelHistory = LevelHistory()
                self.recordingStartedAtMS = nil
                self.lastError = "録音の開始に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingStartedAtMS = nil
        // 取り込み中でないことを、無音と区別できる欠測として残す
        levelHistory.appendGap(atMS: Self.currentMS())
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            do {
                try await self.recorder.stop()
            } catch {
                self.lastError = "録音の停止に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func handleFinalPiece(_ piece: TranscriptPiece, dbfs: Double, direction: Direction?, session: String) async {
        guard !piece.text.isEmpty else { return }
        lastText = piece.text
        lastTextAtMS = Self.currentMS()
        // seqは`PeerClient.enqueue`→`Outbox.appendAssigningSeq`が原子的に採番する（ここでは0）
        let input = await recorder.currentInput()
        let segment = Segment(
            id: UUID(),
            session: session,
            seq: 0,
            device: settings.deviceID,
            deviceName: settings.deviceName,
            owner: settings.ownerName,
            platform: .ios,
            source: .mic,
            input: input,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: dbfs,
            direction: direction
        )
        await peerClient?.enqueue(segment)
        await refreshPendingCount()
    }

    private func refreshPendingCount() async {
        pendingCount = await outbox.unacknowledgedCount
    }

    private static let locale = Locale(identifier: "ja-JP")
}
