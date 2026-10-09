import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000
/// 2026-10-09 14:00 JST
private let base: Int64 = 1_791_522_000_000
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func sampleDocument() -> SignalsDocument {
    SignalsDocument(
        header: SignalsHeader(prefix: "p", start: base, end: base + 25 * minute, bucketMS: 600_000, requestedAt: base + 26 * minute),
        buckets: [
            SignalBucket(start: base, end: base + 10 * minute, place: "自宅", hr: HeartRateSummary(mean: 72, min: nil, max: nil, n: 1)),
            SignalBucket(
                start: base + 10 * minute, end: base + 20 * minute, place: "自宅",
                hr: HeartRateSummary(mean: 74, min: 64, max: 88, n: 3), hrv: HRVSummary(meanSDNNMS: 45.2, n: 1)),
            SignalBucket(start: base + 20 * minute, end: base + 25 * minute, partial: true, place: "不明"),
        ])
}

@Test func signalsFileWritesHeaderThenBucketsAndReadsThemBack() throws {
    let text = try SignalsFile.encode(sampleDocument())
    let lines = text.split(separator: "\n")
    #expect(lines.count == 4)
    #expect(lines[0] == "{\"bucket_ms\":600000,\"end\":1791523500000,\"prefix\":\"p\",\"requested_at\":1791523560000,\"start\":1791522000000,\"t\":\"signals\"}")
    #expect(lines[3] == "{\"end\":1791523500000,\"hr\":null,\"hrv\":null,\"partial\":true,\"place\":\"不明\",\"start\":1791523200000,\"t\":\"bucket\"}")
    #expect(try SignalsFile.decode(text) == sampleDocument())
}

@Test func signalsFileRejectsTextWithoutHeader() {
    #expect(throws: SignalsFileError.missingHeader) {
        try SignalsFile.decode("{\"t\":\"bucket\",\"start\":0,\"end\":600000}\n")
    }
}

@Test func signalsFileRejectsUnknownLineType() {
    #expect(throws: SignalsFileError.unknownType("x")) {
        try SignalsFile.decode("{\"t\":\"x\"}\n")
    }
}

@Test func contextRendererListsBucketsWithoutEmptyColumns() {
    let expected = """
        # 2026-10-09 14:00〜2026-10-09 14:25の体の状態と地点

        心拍はヘルスケアに記録された値（主にWatchのパッシブ計測）で、数分〜数十分おきの粒度。HRVは数時間に1回程度。

        - 14:00〜14:10　地点: 自宅　心拍: 平均72（1件）
        - 14:10〜14:20　地点: 自宅　心拍: 平均74（64〜88、3件）　HRV: 45ms（1件）
        - 14:20〜14:25　地点: 不明　心拍: データなし

        """
    #expect(ContextRenderer.markdown(sampleDocument(), timeZone: tokyo) == expected)
}

@Test func contextRendererPutsDatesOnBothEndsAcrossMidnight() {
    let start = base + 9 * 60 * minute + 50 * minute
    let document = SignalsDocument(
        header: SignalsHeader(prefix: "p", start: start, end: start + 20 * minute, bucketMS: 600_000, requestedAt: start),
        buckets: [])
    #expect(ContextRenderer.markdown(document, timeZone: tokyo).hasPrefix("# 2026-10-09 23:50〜2026-10-10 00:10の体の状態と地点\n"))
}

@Test func contextRendererOmitsPlaceColumnWhenBucketHasNoPlace() {
    let document = SignalsDocument(
        header: SignalsHeader(prefix: "p", start: base, end: base + 10 * minute, bucketMS: 600_000, requestedAt: base),
        buckets: [SignalBucket(start: base, end: base + 10 * minute)])
    #expect(ContextRenderer.markdown(document, timeZone: tokyo).contains("- 14:00〜14:10　心拍: データなし\n"))
}
