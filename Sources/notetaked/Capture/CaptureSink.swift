import AVFoundation
import Foundation
import NotetakeCore

/// 取り込み（MicCaptureとSystemAudioCapture）が、音声と状態の変化を渡す先
protocol CaptureSink: AnyObject, Sendable {
    /// 音声のcallbackから呼ぶ。bufferの写しを取るだけで、変換と書き込みは記録用のqueueで行う
    func ingest(_ buffer: AVAudioPCMBuffer)
    func noteState(_ state: CaptureSourceState, reason: String?)
    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool)
    /// 取り込みの途中で音声を失った失敗を、実状態の`lastError`へ残す
    func noteError(_ message: String)
}
