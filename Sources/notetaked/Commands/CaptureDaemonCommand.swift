import ArgumentParser
import Foundation
import NotetakeCore

struct CaptureDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-daemon",
        abstract: "Capture mic and system audio into the raw audio directory named by the desired state")

    func run() async throws {
        // 2つのcapture-daemonが同じ生音声へ書かないよう、状態ディレクトリのlockを取れなければ終わる
        let lockURL = CaptureStatePaths.stateDirectory().appendingPathComponent("capture-daemon.lock")
        guard let instanceLock = try InstanceLock.acquire(at: lockURL) else {
            Self.log("別のcapture-daemonが動いているため終了します")
            throw ExitCode.failure
        }
        defer { withExtendedLifetime(instanceLock) {} }
        let controller = CaptureController { source, pinnedInputUID -> any SourceCapture in
            if source == .system {
                return SystemAudioCapture()
            }
            return MicCapture(pinnedUID: pinnedInputUID)
        }
        let pid = getpid()
        let parent = getppid()

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task { await Self.shutdown(controller, pid: pid) }
        }
        sigtermSource.resume()

        var watcher = DesiredStateWatcher(url: CaptureStatePaths.captureDesiredURL)
        // 実状態の書き込みの間隔は、時計の巻き戻りに左右されない単調な時計で測る
        let clock = ContinuousClock()
        var lastActualWrite: ContinuousClock.Instant?
        while true {
            // 起動したprocess（appかscript）が終わったら止める。動き続けると、次に起動したcapture-daemonと同じ生音声へ書くため
            if getppid() != parent {
                await Self.shutdown(controller, pid: pid)
            }
            switch watcher.poll() {
            case .changed(let desired):
                await controller.apply(desired)
                lastActualWrite = nil
            case .unreadable(let message):
                Self.log("望む状態を読めないため、いまの取り込みを続けます: \(message)")
            case nil:
                break
            }
            let now = Date()
            if lastActualWrite.map({ clock.now - $0 >= .seconds(1) }) ?? true {
                Self.writeActual(await controller.actualState(pid: pid, now: now))
                lastActualWrite = clock.now
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 取り込みを止め、止まった実状態を書いて終える
    private static func shutdown(_ controller: CaptureController, pid: Int32) async -> Never {
        await controller.stopAll()
        writeActual(await controller.actualState(pid: pid, now: Date()))
        Foundation.exit(0)
    }

    private static func writeActual(_ state: CaptureActualState) {
        do {
            try JSONFile.write(state, to: CaptureStatePaths.captureActualURL)
        } catch {
            log("実状態を書けません: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("capture-daemon: \(message)\n".utf8))
    }
}
