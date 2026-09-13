import Foundation

public struct ClockOffsetSample: Sendable, Equatable {
    public var offsetMS: Int64
    public var rttMS: Int64

    public init(offsetMS: Int64, rttMS: Int64) {
        self.offsetMS = offsetMS
        self.rttMS = rttMS
    }
}

/// NTP式のclock offset計算
public enum ClockOffset {
    /// t0 = local送信, t1 = remote受信, t2 = remote送信, t3 = local受信
    /// offset = remote時計 - local時計 = ((t1 - t0) + (t2 - t3)) / 2
    /// rtt = (t3 - t0) - (t2 - t1)
    public static func sample(t0: Int64, t1: Int64, t2: Int64, t3: Int64) -> ClockOffsetSample {
        let offsetMS = ((t1 - t0) + (t2 - t3)) / 2
        let rttMS = (t3 - t0) - (t2 - t1)
        return ClockOffsetSample(offsetMS: offsetMS, rttMS: rttMS)
    }

    /// rtt最小のsample（同点は先勝ち）。空ならnil
    public static func best(_ samples: [ClockOffsetSample]) -> ClockOffsetSample? {
        guard var best = samples.first else { return nil }
        for sample in samples.dropFirst() where sample.rttMS < best.rttMS {
            best = sample
        }
        return best
    }

    /// segの`clock_offset_ms`に入れる値: remote時計の時刻をlocal(Mac)時刻へ直す加算量 = -offsetMS
    public static func segmentOffsetMS(fromRemoteOffset offsetMS: Int64) -> Int64 {
        -offsetMS
    }
}
