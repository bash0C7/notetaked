import Foundation

/// `.meta.jsonl`のanchorとdevice行から、sample番号を壁時計と入力機器へ対応させる
public struct CaptureTimeline: Equatable, Sendable {
    public struct DeviceChange: Equatable, Sendable {
        public var sample: Int64
        public var device: InputDevice
    }

    /// sample番号の昇順
    public private(set) var anchors: [CaptureAnchor] = []
    /// sample番号の昇順
    public private(set) var devices: [DeviceChange] = []

    public init(lines: [CaptureMetaLine] = []) {
        for line in lines {
            apply(line)
        }
    }

    public mutating func apply(_ line: CaptureMetaLine) {
        switch line {
        case .anchor(let anchor):
            let index = anchors.firstIndex { $0.sample > anchor.sample } ?? anchors.count
            anchors.insert(anchor, at: index)
        case .device(let sample, let device):
            let index = devices.firstIndex { $0.sample > sample } ?? devices.count
            devices.insert(DeviceChange(sample: sample, device: device), at: index)
        case .state:
            break
        }
    }

    /// sampleの壁時計。そのsample以前で最後のanchorから16kHzで進めて求める。
    /// 最初のanchorより前のsampleは、最初のanchorから戻して求める。anchorが無ければnil
    public func ms(atSample sample: Int64) -> Int64? {
        guard let anchor = Self.last(in: anchors, atOrBefore: sample, key: \.sample) ?? anchors.first else {
            return nil
        }
        return anchor.ms + CapturePCM.ms(forSamples: sample - anchor.sample)
    }

    /// sampleを拾った入力機器。device行が無ければnil
    public func device(atSample sample: Int64) -> InputDevice? {
        (Self.last(in: devices, atOrBefore: sample, key: \.sample) ?? devices.first)?.device
    }

    private static func last<Element>(
        in elements: [Element], atOrBefore sample: Int64, key: (Element) -> Int64
    ) -> Element? {
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if key(elements[middle]) <= sample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : elements[low - 1]
    }
}

/// 書き手のanchorの判定。bufferの先頭sampleの壁時計が、直前のanchorから16kHzで進めた時刻と
/// 250msを超えてずれたら新しいanchorを返す。音声が途切れた場合も、音声の時計が壁時計からずれた場合も
/// この規則で扱う。250msはcallbackの揺らぎより大きく、別の機器の発話を統合する許容幅（1秒）より小さい
public struct AnchorClock: Sendable {
    public static let toleranceMS: Int64 = 250

    private var last: CaptureAnchor?

    public init() {}

    public mutating func anchor(forBufferStartingAt sample: Int64, wallClockMS: Int64) -> CaptureAnchor? {
        if let last {
            let predicted = last.ms + CapturePCM.ms(forSamples: sample - last.sample)
            if abs(wallClockMS - predicted) <= Self.toleranceMS {
                return nil
            }
        }
        let anchor = CaptureAnchor(sample: sample, ms: wallClockMS)
        last = anchor
        return anchor
    }

    /// 書き込み先を開いた時に呼ぶ。次のbufferで必ずanchorを返す
    public mutating func reset() {
        last = nil
    }
}
