import AppKit
import Foundation
import NotetakeCore

/// メニューバーアプリ全体の状態と、daemonプロセスのsupervision（起動・再起動・設定反映）を担う。
/// 収録中は「自動で区切る」タイマー（`rotationIntervalHours`）も管理し、期限が来ると`rotate`を送る。
@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let outputDirectory = "outputDirectory"
        static let ownerName = "ownerName"
        static let rotationIntervalHours = "rotationIntervalHours"
        static let pairingCode = "pairingCode"
        static let preferredInputDeviceUID = "preferredInputDeviceUID"
    }

    private static let maxRestartsPerWindow = 5
    private static let restartWindow: TimeInterval = 60
    private static let restartDelay: TimeInterval = 1

    var outputDirectory: URL? {
        didSet { persistOutputDirectory() }
    }

    var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: DefaultsKey.ownerName) }
    }

    /// 固定したい入力デバイスのUID。nil=既定（OSに合わせる）。設定すると次のdaemon起動引数
    /// （`--input-device`）に乗る。daemonがpin先の切断でフォールバックした時（`.inputReset`）はnilに戻る
    var preferredInputDeviceUID: String? {
        didSet { persistPreferredInputDeviceUID() }
    }

    var rotationIntervalHours: Double {
        didSet {
            UserDefaults.standard.set(rotationIntervalHours, forKey: DefaultsKey.rotationIntervalHours)
            scheduleRotation()
        }
    }

    /// iPhoneアプリがMacを発見してペアリングする際に入力する6桁コード。変更のたびに永続化し、
    /// daemonが起動済みなら即座に`.pairCode`で伝える（daemon側は準備でき次第これを扱う）。
    var pairingCode: String {
        didSet {
            UserDefaults.standard.set(pairingCode, forKey: DefaultsKey.pairingCode)
            client?.send(.pairCode(pairingCode))
        }
    }

    var daemonRunning = false
    var isRecording = false
    var prefix: String?
    var utterances: [Utterance] = []
    var volatile: [Source: String] = [:]
    var sources: [Source] = []
    /// 現在の収録の入力機材（daemonの`status.input_name`）。停止中はnil
    var inputName: String?
    var inputSpatial: Bool?
    var lastError: String?
    /// 自動区切りの予定時刻。表示用。自動区切りが無効（間隔0、または未収録）ならnil。
    var nextRotationAt: Date?
    /// daemonから届いた直近の`.log`（話者分離モデルの取得進捗など）。表示用。
    var lastLog: String?
    /// 直前に完了した収録（停止、または区切りで置き換えられた収録）のprefix。「整形」の対象。
    var lastFinishedPrefix: String?
    /// `notetaked polish`の子processが実行中かどうか。多重起動防止。
    var isPolishing = false
    /// 接続中のiPhone等のpeer（device id → 表示名）。`.peer(connected: false)`で削除する。
    var connectedPeers: [String: String] = [:]

    private var client: DaemonClient?
    /// 現在の収録（`prefix`）が開始した時刻。自動区切りの期限計算の起点。
    private var recordingStartedAt: Date?
    /// 自動区切りを待機している`Task`。設定変更・収録状態の変化のたびに取り消して張り直す。
    private var rotationTask: Task<Void, Never>?
    private var launchedArguments: [String]?
    private var restartTimestamps: [Date] = []
    /// 録音中である、または再起動処理が進行中であるために延期している再起動要求がある状態。
    private var restartPending = false
    /// 旧daemonの`terminate()`待ち〜新daemon起動までの間、再起動処理が同時に2つ走らないようにする排他フラグ。
    private var restartInFlight = false
    /// アプリ終了処理中は新規daemonを起動しない。
    private var isShuttingDown = false
    /// 進行中の`performRestart()`のTask。`shutdownDaemon()`が旧daemonの終了完了を待つために保持する。
    private var restartTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: DefaultsKey.outputDirectory), !path.isEmpty {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = nil
        }
        ownerName = defaults.string(forKey: DefaultsKey.ownerName) ?? "私"
        if let uid = defaults.string(forKey: DefaultsKey.preferredInputDeviceUID), !uid.isEmpty {
            preferredInputDeviceUID = uid
        } else {
            preferredInputDeviceUID = nil
        }
        // didSetはinit中は発火しないため、ここでは正規化のみ行い、scheduleRotation()は呼ばない
        // （収録中でない起動直後は呼んでも何もしない）。
        if defaults.object(forKey: DefaultsKey.rotationIntervalHours) == nil {
            rotationIntervalHours = RotationSchedule.defaultIntervalHours
        } else {
            rotationIntervalHours = RotationSchedule.normalizedIntervalHours(
                defaults.double(forKey: DefaultsKey.rotationIntervalHours)
            )
        }
        if let existingCode = defaults.string(forKey: DefaultsKey.pairingCode), !existingCode.isEmpty {
            pairingCode = existingCode
        } else {
            let generated = Self.generatePairingCode()
            defaults.set(generated, forKey: DefaultsKey.pairingCode)
            pairingCode = generated
        }
    }

    private static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// 現在接続中のpeer名（表示用に安定した順序でソート済み）。
    var connectedPeerNames: [String] {
        connectedPeers.values.sorted()
    }

    private func persistOutputDirectory() {
        let defaults = UserDefaults.standard
        if let outputDirectory {
            defaults.set(outputDirectory.path, forKey: DefaultsKey.outputDirectory)
        } else {
            defaults.removeObject(forKey: DefaultsKey.outputDirectory)
        }
    }

    private func persistPreferredInputDeviceUID() {
        let defaults = UserDefaults.standard
        if let preferredInputDeviceUID {
            defaults.set(preferredInputDeviceUID, forKey: DefaultsKey.preferredInputDeviceUID)
        } else {
            defaults.removeObject(forKey: DefaultsKey.preferredInputDeviceUID)
        }
    }

    // MARK: - Daemon lifecycle

    private func desiredArguments(outputDirectory: URL) -> [String] {
        var arguments = [
            "serve",
            "--output", outputDirectory.path,
            "--owner", ownerName,
            "--source", "both",
            "--control", "stdio",
        ]
        if let preferredInputDeviceUID {
            arguments += ["--input-device", preferredInputDeviceUID]
        }
        return arguments
    }

    /// 保存先が設定されていればdaemonを起動する。既に起動中で設定（引数）が変わっていなければ何もしない。
    /// 引数が変わっていれば旧daemonを終了して新daemonを起動するが、次のいずれかの場合は延期し、
    /// `restartPending`を立てて後で再度`ensureDaemon()`が呼ばれた時に適用する:
    /// - 録音中（`handle(_:)`の`.status`で`recording == false`を受け取った時に自動適用）
    /// - 既に再起動処理が進行中（`performRestart()`完了時に自動適用）
    /// 再起動が実際に走る時点の設定を反映するため、引数は要求時ではなく起動直前（`launchLatest()`内）で
    /// 都度計算し直す。
    func ensureDaemon() {
        guard !isShuttingDown else { return }
        guard let outputDirectory else { return }
        if restartInFlight {
            restartPending = true
            return
        }
        let arguments = desiredArguments(outputDirectory: outputDirectory)
        if daemonRunning, launchedArguments == arguments {
            restartPending = false
            return
        }
        if isRecording {
            restartPending = true
            return
        }
        restartPending = false
        performRestart()
    }

    /// 旧daemon（あれば）を終了してから、その時点の最新設定で新daemonを起動する。
    /// `restartInFlight`により、この処理が完了するまで新たな再起動は`ensureDaemon()`側で延期される。
    private func performRestart() {
        restartInFlight = true
        let oldClient = client
        client = nil
        let wasRecording = isRecording
        restartTask = Task { @MainActor [weak self] in
            if let oldClient {
                await oldClient.terminate(wasRecording: wasRecording)
            }
            guard let self else { return }
            self.restartInFlight = false
            self.restartTask = nil
            guard !self.isShuttingDown else { return }
            self.launchLatest()
            if self.restartPending {
                self.restartPending = false
                self.ensureDaemon()
            }
        }
    }

    private func launchLatest() {
        guard let outputDirectory else { return }
        let arguments = desiredArguments(outputDirectory: outputDirectory)
        launchedArguments = arguments
        startClient(arguments: arguments)
    }

    private func startClient(arguments: [String]) {
        guard let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("notetaked")
        else {
            lastError = "notetakedの実行ファイルが見つかりません"
            return
        }
        let newClient = DaemonClient(
            executable: executable,
            arguments: arguments,
            onEvent: { [weak self] event in self?.handle(event) },
            onExit: { [weak self] exitedClient, code in self?.handleExit(exitedClient, code) }
        )
        do {
            try newClient.start()
            client = newClient
            daemonRunning = true
            newClient.send(.pairCode(pairingCode))
        } catch {
            lastError = "daemonの起動に失敗しました: \(error.localizedDescription)"
            daemonRunning = false
        }
    }

    /// 終了したclientが現在`self.client`が保持しているものと一致する場合のみ処理する。
    /// 置き換え済み（`performRestart()`で`client = nil`にした後の旧client）や意図的に終了させた
    /// （`shutdownDaemon()`で`client = nil`にした後の）clientのexitは、その時点で既に`self.client`と
    /// 一致しなくなっているため自動的に無視され、誤った再起動カウントやクラッシュ扱いを防げる。
    private func handleExit(_ exitedClient: DaemonClient, _ code: Int32) {
        guard exitedClient === client else { return }
        client = nil
        daemonRunning = false
        // 予期せぬ終了でdaemonが持っていた録音状態は失われるため、UI側もリセットする。
        // これをしないと、録音中を理由に再起動が永久に延期されてしまう。
        isRecording = false
        prefix = nil
        connectedPeers = [:]
        clearRotation()
        if code != 0 {
            lastError = "daemonが予期せず終了しました (code \(code))"
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let now = Date()
        restartTimestamps.removeAll { now.timeIntervalSince($0) >= Self.restartWindow }
        guard restartTimestamps.count < Self.maxRestartsPerWindow else {
            lastError = "daemonの再起動回数が上限（\(Int(Self.restartWindow))秒間に\(Self.maxRestartsPerWindow)回）に達したため停止しました"
            return
        }
        restartTimestamps.append(now)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.restartDelay * 1_000_000_000))
            self?.ensureDaemon()
        }
    }

    /// アプリ終了時にdaemonを止める（再起動はしない）。MainActorをブロックせず、quit送信〜終了待ちを待機できる。
    /// `isShuttingDown`を立てることで、進行中の`performRestart()`が完了しても新daemonを起動しないようにする。
    /// 再起動が進行中（`client == nil`だが旧daemonの`terminate()`をまだ待っている状態）の場合に備えて、
    /// まず`restartTask`の完了を待ってから、その時点で残っている`client`（あれば）を終了させる。
    /// こうしないと、旧daemonがまだforce-terminateされる前にアプリが終了し、孤児daemonが残る。
    func shutdownDaemon() async {
        clearRotation()
        isShuttingDown = true
        await restartTask?.value
        restartInFlight = false
        restartPending = false
        guard let client else { return }
        self.client = nil
        await client.terminate(wasRecording: isRecording)
        daemonRunning = false
    }

    // MARK: - Commands

    func startRecording() {
        lastError = nil
        client?.send(.start)
    }

    func stopRecording() {
        client?.send(.stop)
    }

    func rotateRecording() {
        lastError = nil
        client?.send(.rotate)
    }

    func renameSpeaker(id: String, name: String) {
        client?.send(.renameSpeaker(id: id, name: name))
    }

    func copyAllToPasteboard() {
        let markdown = TranscriptRenderer.markdown(utterances, timeZone: .current)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    func openOutputFolder() {
        guard let outputDirectory else { return }
        NSWorkspace.shared.open(outputDirectory)
    }

    func regeneratePairingCode() {
        pairingCode = Self.generatePairingCode()
    }

    /// 直前に完了した収録（`lastFinishedPrefix`）の`timed.jsonl`を`notetaked polish`にかけ、
    /// `<prefix>.polished.md`を生成する。子processなので多重起動は`isPolishing`で防ぐ。
    func polishLastRecording() {
        guard !isPolishing else { return }
        guard let prefix = lastFinishedPrefix else { return }
        guard let outputDirectory else { return }
        guard let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("notetaked")
        else {
            lastError = "notetakedの実行ファイルが見つかりません"
            return
        }
        let inputPath = outputDirectory.appendingPathComponent("\(prefix).timed.jsonl").path
        let process = Process()
        process.executableURL = executable
        process.arguments = ["polish", inputPath]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // terminationHandlerは@Sendable。Pipeではなく（Sendableな）FileHandleをcaptureする
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.terminationHandler = { [weak self] finishedProcess in
            let status = finishedProcess.terminationStatus
            _ = stdoutHandle.readDataToEndOfFile()
            let stderrData = stderrHandle.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.isPolishing = false
                if status == 0 {
                    self.lastLog = "整形完了: \(prefix).polished.md"
                } else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    let lastLine = stderrText
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .last
                        .map(String.init) ?? ""
                    self.lastError = "整形に失敗しました (code \(status)): \(lastLine)"
                }
            }
        }
        do {
            try process.run()
            isPolishing = true
            lastLog = "整形中: \(prefix)"
        } catch {
            lastError = "整形の起動に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto rotation

    /// 収録開始時刻（`recordingStartedAt`）と設定間隔（`rotationIntervalHours`）から次の区切り期限を計算し、
    /// 期限まで待ってから`rotateRecording()`を呼ぶ`Task`を張り直す。
    /// `ContinuousClock`で待つため、Macがスリープしている間も時間は経過し続け、
    /// スリープ復帰時点で既に期限を過ぎていればその直後に区切られる（`Task.sleep`はほぼ即座に返る）。
    /// 設定変更（`rotationIntervalHours`のdidSet）や収録状態の変化のたびに呼ばれ、
    /// 同じ`recordingStartedAt`からの再計算になるため、間隔の変更は次の区切り予定に即座に反映される。
    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        guard isRecording, let start = recordingStartedAt,
              let due = RotationSchedule.nextRotation(recordingStartedAt: start, intervalHours: rotationIntervalHours)
        else {
            nextRotationAt = nil
            return
        }
        nextRotationAt = due
        rotationTask = Task { @MainActor [weak self] in
            let delay = max(0, due.timeIntervalSinceNow)
            try? await Task.sleep(until: .now + .seconds(delay), clock: .continuous)
            guard !Task.isCancelled, let self, self.isRecording, self.nextRotationAt == due else { return }
            self.rotateRecording()
        }
    }

    private func clearRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        recordingStartedAt = nil
        nextRotationAt = nil
    }

    // MARK: - Event handling

    private func handle(_ event: Event) {
        switch event {
        case .status(let status):
            let previousPrefix = prefix
            let isNewRecording = status.recording && status.prefix != previousPrefix
            if isNewRecording {
                utterances = []
                volatile = [:]
            }
            if status.recording {
                lastError = nil
            } else {
                volatile = [:]
            }
            if let previousPrefix, !status.recording || isNewRecording {
                // 停止（!recording）、または区切り（recordingのままprefixが変わった）のいずれかで
                // 直前の収録が完了したとみなす。
                lastFinishedPrefix = previousPrefix
            }
            isRecording = status.recording
            prefix = status.prefix
            sources = status.sources
            inputName = status.inputName
            inputSpatial = status.inputSpatial
            if isNewRecording {
                recordingStartedAt = Date()
                scheduleRotation()
            }
            if !status.recording {
                clearRotation()
            }
            if !isRecording, restartPending {
                ensureDaemon()
            }
        case .utterance(let utterance):
            volatile[utterance.source] = nil
            if let index = utterances.firstIndex(where: { $0.id == utterance.id }) {
                utterances[index] = utterance
            } else {
                utterances.append(utterance)
            }
            utterances.sort { $0.start < $1.start }
        case .volatile(let source, let text):
            volatile[source] = text
        case .error(let message):
            lastError = message
            FileHandle.standardError.write(Data("notetaked error: \(message)\n".utf8))
        case .log(let message):
            lastLog = message
            FileHandle.standardError.write(Data("notetaked log: \(message)\n".utf8))
        case .peer(let device, let deviceName, let connected):
            if connected {
                connectedPeers[device] = deviceName
            } else {
                connectedPeers.removeValue(forKey: device)
            }
        case .inputReset:
            preferredInputDeviceUID = nil
        }
    }
}
