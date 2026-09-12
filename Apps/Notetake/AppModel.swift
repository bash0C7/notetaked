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
    private var suppressNextExitHandling = false
    private var restartTimestamps: [Date] = []
    /// 録音中に設定が変わり再起動が必要になったが、録音終了まで延期している状態。
    private var restartPending = false

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
    /// 引数が変わっていれば旧daemonを終了して新daemonを起動するが、録音中は録音終了まで延期する
    /// （`handle(_:)`の`.status`で`recording == false`を受け取った時に自動的に適用される）。
    func ensureDaemon() {
        guard let outputDirectory else { return }
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
        performRestart(arguments: arguments)
    }

    private func performRestart(arguments: [String]) {
        if let client {
            suppressNextExitHandling = true
            self.client = nil
            Task { @MainActor [weak self] in
                await client.terminate()
                guard let self else { return }
                self.launchedArguments = arguments
                self.startClient(arguments: arguments)
            }
        } else {
            launchedArguments = arguments
            startClient(arguments: arguments)
        }
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
            onExit: { [weak self] code in self?.handleExit(code) }
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

    private func handleExit(_ code: Int32) {
        client = nil
        daemonRunning = false
        if suppressNextExitHandling {
            suppressNextExitHandling = false
            return
        }
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
    func shutdownDaemon() async {
        guard let client else { return }
        suppressNextExitHandling = true
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
