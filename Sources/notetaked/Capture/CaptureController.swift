import Foundation
import NotetakeCore

/// micかsystemの音声を取り込み、`CaptureSink`へ渡す。開始の失敗や途中の停止は投げずに
/// `noteState`で伝え、自分で再開を試みる
protocol SourceCapture: AnyObject, Sendable {
    func start(into sink: any CaptureSink) async
    func stop() async
}

/// capture-daemonの本体。望む状態に合わせて取り込みと書き込み先を揃え、実状態を返す。
/// 区切り（prefixだけが変わる）では取り込みを止めず、書き込み先だけを切り替える
actor CaptureController {
    typealias CaptureFactory = @Sendable (_ source: Source, _ pinnedInputUID: String?) -> any SourceCapture

    private struct Running {
        let recorder: SourceRecorder
        let capture: any SourceCapture
        let pinnedInputUID: String?
    }

    private let makeCapture: CaptureFactory
    private var running: [Source: Running] = [:]
    private var prefix: String?

    init(makeCapture: @escaping CaptureFactory) {
        self.makeCapture = makeCapture
    }

    func apply(_ desired: CaptureDesiredState) async {
        guard let recording = desired.recording else {
            await stopAll()
            return
        }
        let directory = URL(fileURLWithPath: recording.directory)
        let wanted = desired.sources.filter { $0 == .mic || $0 == .system }
        for source in Array(running.keys) where !wanted.contains(source) {
            await stop(source)
        }
        if let mic = running[.mic], mic.pinnedInputUID != desired.pinnedInputUID {
            await stop(.mic)
        }
        for source in wanted {
            if let current = running[source] {
                if recording.prefix != prefix {
                    current.recorder.open(directory: directory)
                }
                continue
            }
            let pinnedInputUID = source == .mic ? desired.pinnedInputUID : nil
            let recorder = SourceRecorder(source: source)
            recorder.open(directory: directory)
            let capture = makeCapture(source, pinnedInputUID)
            running[source] = Running(recorder: recorder, capture: capture, pinnedInputUID: pinnedInputUID)
            await capture.start(into: recorder)
        }
        prefix = recording.prefix
    }

    func stopAll() async {
        for source in Array(running.keys) {
            await stop(source)
        }
        prefix = nil
    }

    func actualState(pid: Int32, now: Date) -> CaptureActualState {
        CaptureActualState(
            pid: pid, prefix: prefix,
            sources: [Source.mic, .system].compactMap { running[$0]?.recorder.snapshot() },
            updated: Int64((now.timeIntervalSince1970 * 1000).rounded()))
    }

    private func stop(_ source: Source) async {
        guard let entry = running.removeValue(forKey: source) else { return }
        await entry.capture.stop()
        entry.recorder.close()
    }
}
