import AppKit
import Foundation
import NotetakeCore

/// メニューバーアプリ全体の状態と、daemonプロセスのsupervision（起動・再起動・設定反映）を担う。
@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let outputDirectory = "outputDirectory"
        static let ownerName = "ownerName"
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

    var daemonRunning = false
    var isRecording = false
    var prefix: String?
    var utterances: [Utterance] = []
    var volatile: [Source: String] = [:]
    var lastError: String?

    private var client: DaemonClient?
    private var launchedArguments: [String]?
    private var restartTimestamps: [Date] = []
    /// 録音中である、または再起動処理が進行中であるために延期している再起動要求がある状態。
    private var restartPending = false
    /// 旧daemonの`terminate()`待ち〜新daemon起動までの間、再起動処理が同時に2つ走らないようにする排他フラグ。
    private var restartInFlight = false
    /// アプリ終了処理中は新規daemonを起動しない。
    private var isShuttingDown = false

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: DefaultsKey.outputDirectory), !path.isEmpty {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = nil
        }
        ownerName = defaults.string(forKey: DefaultsKey.ownerName) ?? "私"
    }

    private func persistOutputDirectory() {
        let defaults = UserDefaults.standard
        if let outputDirectory {
            defaults.set(outputDirectory.path, forKey: DefaultsKey.outputDirectory)
        } else {
            defaults.removeObject(forKey: DefaultsKey.outputDirectory)
        }
    }

    // MARK: - Daemon lifecycle

    private func desiredArguments(outputDirectory: URL) -> [String] {
        [
            "serve",
            "--output", outputDirectory.path,
            "--owner", ownerName,
            "--source", "both",
            "--control", "stdio",
        ]
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
        Task { @MainActor [weak self] in
            if let oldClient {
                await oldClient.terminate()
            }
            guard let self else { return }
            self.restartInFlight = false
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
    func shutdownDaemon() async {
        isShuttingDown = true
        guard let client else { return }
        self.client = nil
        await client.terminate()
        daemonRunning = false
    }

    // MARK: - Commands

    func startRecording() {
        client?.send(.start)
    }

    func stopRecording() {
        client?.send(.stop)
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

    // MARK: - Event handling

    private func handle(_ event: Event) {
        switch event {
        case .status(let status):
            if status.recording, status.prefix != prefix {
                utterances = []
                volatile = [:]
            }
            isRecording = status.recording
            prefix = status.prefix
            if !isRecording, restartPending {
                ensureDaemon()
            }
        case .utterance(let utterance):
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
            FileHandle.standardError.write(Data("notetaked log: \(message)\n".utf8))
        }
    }
}
