import AVFoundation
import Foundation

/// Watch受信モードの無音再生。`.playback` + `.mixWithOthers`で無音を繰り返し再生し、背面で生き続ける。
/// iPhoneのmic収録中は呼び出し側が`stop()`する（`Recorder`のaudio sessionの設定は変えない）
@MainActor
final class WatchListener {
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    private let onInterruptionEnded: @MainActor () -> Void

    var isPlaying: Bool { player?.isPlaying ?? false }

    init(onInterruptionEnded: @escaping @MainActor () -> Void) {
        self.onInterruptionEnded = onInterruptionEnded
    }

    /// 既に再生中なら何もしない。中断の後は`isPlaying`が偽になっているので、作り直して再開する
    func play() {
        if isPlaying { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            guard player.play() else {
                Diag.log("watch listener: play() returned false")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            self.player = player
            observeInterruptions()
            RelayTrace.record(.listeningStarted)
        } catch {
            Diag.log("watch listener: start failed \(error)")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        // 他のappの音を戻させる。mic収録のaudio sessionは`Recorder`の`AVCaptureSession`が自動で設定する
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        RelayTrace.record(.listeningStopped)
    }

    private func observeInterruptions() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated { self?.onInterruptionEnded() }
        }
    }

    /// 1秒・8kHz・mono・16bitの無音のWAV
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let dataSize = sampleRate * 2
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
