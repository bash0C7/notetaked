import AVFoundation

/// マイク・system audioなど、キャプチャ元を差し替え可能にするprotocol
protocol AudioCapture: AnyObject, Sendable {
    /// capture側のnative format
    var format: AVAudioFormat { get }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}
