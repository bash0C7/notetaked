import Foundation
import NotetakeCore

/// notetaked capture-daemonを子processとして起動・監視する。stdio連携は無く、
/// heartbeatファイルのmtimeだけで生存確認する（クラッシュ・ハング両方をこの一本の仕組みで検知する。
/// notetaked serveのDaemonClientと違い、Process.terminationHandlerによる即時クラッシュ検知は行わない —
/// クラッシュしてもheartbeatが15秒以内に古くなるため、同じ経路でカバーされる）
@MainActor
final class CaptureDaemonSupervisor {
    private static let heartbeatThreshold: TimeInterval = 15
    private static let gracefulTimeout: TimeInterval = 5

    private let executableURL: URL
    private var process: Process?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// 既に起動中なら何もしない（冪等）
    func start() {
        guard process == nil else { return }
        let newProcess = Process()
        newProcess.executableURL = executableURL
        newProcess.arguments = ["capture-daemon"]
        newProcess.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.process = nil }
        }
        do {
            try newProcess.run()
            process = newProcess
        } catch {
            process = nil
        }
    }

    var isHealthy: Bool {
        Heartbeat.currentStatus(of: CaptureStatePaths.captureHeartbeatURL, threshold: Self.heartbeatThreshold) == .alive
    }

    /// SIGTERMで猶予を与えて止め、それでも生きていればSIGKILLしてから再起動する
    func gracefulRestart() async {
        await terminate()
        start()
    }

    /// アプリ終了時に呼ぶ。SIGTERM→猶予→SIGKILLで止めるが、再起動はしない
    func stop() async {
        await terminate()
    }

    private func terminate() async {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(Self.gracefulTimeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        self.process = nil
    }
}
