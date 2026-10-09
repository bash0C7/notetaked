import Foundation

/// 心拍・HRV・滞在を、epoch msの10分の格子で区切ったバケットへ集計する
public enum SignalBucketing {
    public static let bucketMS: Int64 = 600_000

    /// `[startMS, endMS)`を格子で区切る。先頭と末尾は区間で切り詰めて`partial`にする
    public static func buckets(
        startMS: Int64, endMS: Int64, bucketMS: Int64 = SignalBucketing.bucketMS,
        heartRates: [HeartRateSample], hrv: [HRVSample], stays: [PlaceStay]
    ) -> [SignalBucket] {
        guard endMS > startMS, bucketMS > 0 else { return [] }
        var result: [SignalBucket] = []
        var gridStart = floorDivide(startMS, bucketMS) * bucketMS
        while gridStart < endMS {
            let gridEnd = gridStart + bucketMS
            let range = Swift.max(gridStart, startMS)..<Swift.min(gridEnd, endMS)
            result.append(
                SignalBucket(
                    start: range.lowerBound, end: range.upperBound,
                    partial: range.lowerBound != gridStart || range.upperBound != gridEnd,
                    place: place(in: range, stays: stays, openStayEndMS: endMS),
                    hr: heartRateSummary(heartRates.filter { range.contains($0.at) }.map(\.bpm)),
                    hrv: hrvSummary(hrv.filter { range.contains($0.at) }.map(\.sdnnMS))))
            gridStart = gridEnd
        }
        return result
    }

    /// 新しい結果をバケットごとに重ねる。新しいバケットにある値だけを使い、無い値は前の値を残す。
    /// 空の応答や拒否の応答が、取れていた結果を消さないようにするため
    public static func overlay(existing: [SignalBucket], incoming: [SignalBucket]) -> [SignalBucket] {
        var byStart = Dictionary(existing.map { ($0.start, $0) }, uniquingKeysWith: { _, last in last })
        for bucket in incoming {
            guard var merged = byStart[bucket.start] else {
                byStart[bucket.start] = bucket
                continue
            }
            merged.end = bucket.end
            merged.partial = bucket.partial
            merged.place = bucket.place ?? merged.place
            merged.hr = bucket.hr ?? merged.hr
            merged.hrv = bucket.hrv ?? merged.hrv
            byStart[bucket.start] = merged
        }
        return byStart.values.sorted { $0.start < $1.start }
    }

    /// `[startMS, endMS)`からはみ出すバケットを捨てる
    public static func clip(_ buckets: [SignalBucket], startMS: Int64, endMS: Int64) -> [SignalBucket] {
        buckets.filter { $0.start >= startMS && $0.end <= endMS && $0.start < $0.end }
    }

    static func heartRateSummary(_ values: [Double]) -> HeartRateSummary? {
        guard !values.isEmpty else { return nil }
        let hasRange = values.count >= 3
        return HeartRateSummary(
            mean: rounded(values.reduce(0, +) / Double(values.count)),
            min: hasRange ? values.min() : nil, max: hasRange ? values.max() : nil, n: values.count)
    }

    static func hrvSummary(_ values: [Double]) -> HRVSummary? {
        guard !values.isEmpty else { return nil }
        return HRVSummary(meanSDNNMS: rounded(values.reduce(0, +) / Double(values.count)), n: values.count)
    }

    /// バケットと重なる時間が最も長い滞在のラベル。同じ長さなら先に始まった滞在
    static func place(in range: Range<Int64>, stays: [PlaceStay], openStayEndMS: Int64) -> String? {
        var best: (label: String, overlap: Int64, start: Int64)?
        for stay in stays {
            let overlap =
                Swift.min(stay.end ?? openStayEndMS, range.upperBound) - Swift.max(stay.start, range.lowerBound)
            guard overlap > 0 else { continue }
            if let current = best, current.overlap > overlap || (current.overlap == overlap && current.start <= stay.start) {
                continue
            }
            best = (stay.label, overlap, stay.start)
        }
        return best?.label
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor != 0 && (value < 0) != (divisor < 0) ? quotient - 1 : quotient
    }
}
