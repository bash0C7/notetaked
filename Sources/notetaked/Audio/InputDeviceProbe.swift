import AVFoundation
import CoreAudio
import NotetakeCore

/// 収録開始時に音声入力機材を調べる。FOA対応判定は許可なしで即時に返る
enum InputDeviceProbe {
    static func current() -> InputDevice {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return InputDevice(name: "unknown", uid: "unknown", spatial: false)
        }
        return makeInputDevice(from: device)
    }

    /// 現在接続中の音声入力機材一覧（内蔵マイク・AirPods等の外部マイク含む）
    static func all() -> [InputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return discovery.devices.map(makeInputDevice)
    }

    /// UIDから接続中デバイスを解決する。見つからなければnil
    static func resolve(uid: String) -> InputDevice? {
        all().first { $0.uid == uid }
    }

    /// UIDからCoreAudioの`AudioDeviceID`を解決する。`kAudioHardwarePropertyDevices`で
    /// 全デバイスを列挙し、各デバイスの`kAudioDevicePropertyDeviceUID`と照合する。
    /// 見つからなければnil
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize) == noErr
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, &deviceIDs)
                == noErr
        else { return nil }

        for deviceID in deviceIDs where deviceUID(of: deviceID) == uid {
            return deviceID
        }
        return nil
    }

    private static func deviceUID(of deviceID: AudioDeviceID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else { return nil }
        return cfUID as String
    }

    private static func makeInputDevice(from device: AVCaptureDevice) -> InputDevice {
        let spatial = (try? AVCaptureDeviceInput(device: device))?
            .isMultichannelAudioModeSupported(.firstOrderAmbisonics) ?? false
        return InputDevice(name: device.localizedName, uid: device.uniqueID, spatial: spatial)
    }
}
