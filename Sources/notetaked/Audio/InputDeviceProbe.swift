import AVFoundation
import NotetakeCore

/// 収録開始時に既定の音声入力機材を調べる。FOA対応判定は許可なしで即時に返る
enum InputDeviceProbe {
    static func current() -> InputDevice {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return InputDevice(name: "unknown", uid: "unknown", spatial: false)
        }
        let spatial = (try? AVCaptureDeviceInput(device: device))?
            .isMultichannelAudioModeSupported(.firstOrderAmbisonics) ?? false
        return InputDevice(name: device.localizedName, uid: device.uniqueID, spatial: spatial)
    }
}
