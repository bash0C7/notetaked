import Foundation

/// 音量の1点。dbfsがnilなら欠測（測れなかった区間）
public struct LevelSample: Sendable, Equatable {
    public var atMS: Int64
    public var dbfs: Double?

    public init(atMS: Int64, dbfs: Double?) {
        self.atMS = atMS
        self.dbfs = dbfs
    }
}

/// 直近windowMS分の音量の履歴。古い順に持ち、窓より古い分は足すたびに捨てる
public struct LevelHistory: Sendable, Equatable {
    public let windowMS: Int64
    public private(set) var samples: [LevelSample] = []

    public init(windowMS: Int64 = 90_000) {
        self.windowMS = windowMS
    }

    public var latest: LevelSample? { samples.last }

    public mutating func append(atMS: Int64, dbfs: Double) {
        push(LevelSample(atMS: atMS, dbfs: dbfs))
    }

    /// 測れなかった時点を足す。無音の連続はここで途切れる（欠測は無音ではない）
    public mutating func appendGap(atMS: Int64) {
        push(LevelSample(atMS: atMS, dbfs: nil))
    }

    /// 末尾から連続する完全な無音の期間（ms）。連続の先頭のsampleの時刻からnowMSまで
    public func trailingSilenceMS(nowMS: Int64) -> Int64 {
        var runStartMS: Int64?
        for sample in samples.reversed() {
            guard let dbfs = sample.dbfs, LevelScale.isSilent(dbfs: dbfs) else { break }
            runStartMS = sample.atMS
        }
        guard let runStartMS else { return 0 }
        return max(nowMS - runStartMS, 0)
    }

    public func hasSound(above thresholdDBFS: Double, sinceMS: Int64) -> Bool {
        samples.contains { sample in
            guard sample.atMS >= sinceMS, let dbfs = sample.dbfs else { return false }
            return dbfs > thresholdDBFS
        }
    }

    private mutating func push(_ sample: LevelSample) {
        samples.append(sample)
        let dropCount = samples.prefix { sample.atMS - $0.atMS > windowMS }.count
        if dropCount > 0 { samples.removeFirst(dropCount) }
    }
}
