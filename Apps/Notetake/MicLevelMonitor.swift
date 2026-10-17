import AVFoundation
import Foundation
import NotetakeCore
import Observation
import os

/// 停止中、ライブパネルが開いている間だけマイクを開いて音量の履歴を作る。
/// 収録中はcapture-daemonがマイクを持つため、`AppModel`が収録の開始前に`stop()`を呼ぶ
@MainActor
@Observable
final class MicLevelMonitor {
    private(set) var history = LevelHistory()
    /// 使える入力が無い時の文言。取り込めている間はnil
    private(set) var unavailableReason: String?

    @ObservationIgnored private var capture: AUHALInputCapture?
    @ObservationIgnored private var sink: MicLevelSink?
    @ObservationIgnored private var gapTask: Task<Void, Never>?
    /// 動作中（取れず欠測を足している間も含む）か。その時の固定先は`runningUID`
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runningUID: String?

    /// 同じ固定先で動作中なら何もしない（`AppModel`はstatusのたびに呼ぶ）。固定先が変わっていれば開き直す
    func start(preferredUID: String?) {
        if isRunning, runningUID == preferredUID { return }
        stop()
        isRunning = true
        runningUID = preferredUID
        guard
            let target = InputDeviceProbe.captureTarget(
                pinnedUID: preferredUID ?? InputDeviceResolution.builtInUID, pinnedUnusable: false),
            let newCapture = AUHALInputCapture(deviceID: target.id)
        else {
            markUnavailable()
            return
        }
        let newSink = MicLevelSink { [weak self] atMS, dbfs in
            Task { @MainActor in self?.history.append(atMS: atMS, dbfs: dbfs) }
        }
        do {
            try newCapture.start(into: newSink)
        } catch {
            newCapture.stop()
            markUnavailable()
            return
        }
        capture = newCapture
        sink = newSink
    }

    /// AUHALをこの場で閉じる（収録の開始前に、capture-daemonとマイクを取り合わないため）。`history`は残す
    func stop() {
        gapTask?.cancel()
        gapTask = nil
        sink?.invalidate()
        sink = nil
        capture?.stop()
        capture = nil
        isRunning = false
        runningUID = nil
        unavailableReason = nil
    }

    /// 取れない間は500msごとに欠測を足し、グラフに古い値が残らないようにする
    private func markUnavailable() {
        unavailableReason = "使える入力機器がありません"
        history.appendGap(atMS: Self.nowMS())
        gapTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.history.appendGap(atMS: Self.nowMS())
            }
        }
    }

    private nonisolated static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// AUHALのcallback（約10msごと）の小さなbufferを溜め、100ms以上たってから1回だけdBFSを計算して渡す。
/// 溜める状態はaudioのthreadとmain actorの両方から触るため、lockで守る
private final class MicLevelSink: CaptureSink, @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var lastEmitMS: Int64 = 0
        var isActive = true
    }

    private static let emitIntervalMS: Int64 = 100

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onLevel: @Sendable (Int64, Double) -> Void

    init(onLevel: @escaping @Sendable (Int64, Double) -> Void) {
        self.onLevel = onLevel
        state.withLock { $0.lastEmitMS = Self.nowMS() }
    }

    /// 以後のcallbackは何も出さない。stop後に遅れて届くbufferを捨てるため
    func invalidate() {
        state.withLock { $0.isActive = false }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        let nowMS = Self.nowMS()
        // channelは生ポインタでSendableではないため、Sendableを要求しないwithLockUncheckedを使う
        let ready: [Float]? = state.withLockUnchecked { state in
            guard state.isActive else { return nil }
            for frame in 0..<frames {
                state.samples.append(channel[frame * stride])
            }
            guard nowMS - state.lastEmitMS >= Self.emitIntervalMS else { return nil }
            state.lastEmitMS = nowMS
            let taken = state.samples
            state.samples.removeAll(keepingCapacity: true)
            return taken
        }
        guard let ready, !ready.isEmpty else { return }
        onLevel(nowMS, AudioLevel.dbfs(ready))
    }

    func noteState(_ state: CaptureSourceState, reason: String?) {}
    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool) {}
    func noteError(_ message: String) {}

    private static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
