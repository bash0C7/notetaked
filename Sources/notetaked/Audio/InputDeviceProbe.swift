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

    /// 機器の接続種別。読めなければ`.other`
    static func transport(of deviceID: AudioDeviceID) -> InputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var fourCC: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &fourCC) == noErr else { return .other }
        return InputTransport(fourCC: fourCC)
    }

    /// 接続中の入力機器のUIDと接続種別。`AudioDeviceID`を引けない機器は`.other`として含める
    static func candidates() -> [InputCandidate] {
        all().map { device in
            let transport = audioDeviceID(forUID: device.uid).map(transport(of:)) ?? .other
            return InputCandidate(uid: device.uid, transport: transport)
        }
    }

    /// 選択肢に出す入力機器。Continuity（iPhone連携）を除く
    static func selectableInputs() -> [InputDevice] {
        let continuityUIDs = Set(candidates().filter { $0.transport == .continuity }.map(\.uid))
        return all().filter { !continuityUIDs.contains($0.uid) }
    }

    /// 取り込む機器。固定した機器が接続中ならそれ、無ければ既定の入力（Continuityならば内蔵）。使える機器が無ければnil
    static func captureTarget(pinnedUID: String?, pinnedUnusable: Bool) -> (id: AudioDeviceID, fellBackFromPinned: Bool)? {
        if !pinnedUnusable,
            let uid = InputDeviceResolution.resolvedUID(
                pinnedUID: pinnedUID, availableUIDs: Set(all().map(\.uid))),
            let id = audioDeviceID(forUID: uid)
        {
            return (id, false)
        }
        let osDefaultUID = defaultInputDeviceID().flatMap(deviceUID(of:))
        guard
            let uid = InputDeviceResolution.fallbackUID(
                osDefaultUID: osDefaultUID, candidates: candidates()),
            let id = audioDeviceID(forUID: uid)
        else { return nil }
        return (id, pinnedUID != nil)
    }

    /// OSの既定の入力機器の`AudioDeviceID`。無ければnil
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
                == noErr, deviceID != 0
        else { return nil }
        return deviceID
    }

    /// `AudioDeviceID`から機器の情報を作る。接続中の一覧にあればその情報、無ければCoreAudioの名前を使う
    static func inputDevice(forID deviceID: AudioDeviceID) -> InputDevice {
        let uid = deviceUID(of: deviceID)
        if let uid, let known = resolve(uid: uid) { return known }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "unknown" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0) }
        return InputDevice(name: status == noErr ? name as String : "unknown", uid: uid ?? "unknown", spatial: false)
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

    static func deviceUID(of deviceID: AudioDeviceID) -> String? {
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
