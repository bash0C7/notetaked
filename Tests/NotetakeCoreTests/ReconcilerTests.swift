import Foundation
import Testing
@testable import NotetakeCore

private func seg(
    id: UUID = UUID(),
    device: String,
    owner: String = "小芝",
    source: Source = .mic,
    platform: Platform = .mac,
    start: Int64,
    end: Int64,
    text: String,
    confidence: Double? = nil,
    offset: Int64 = 0,
    global: String? = nil
) -> Record {
    .segment(Segment(
        id: id,
        session: "s1",
        seq: 0,
        device: device,
        deviceName: device,
        owner: owner,
        platform: platform,
        source: source,
        start: start,
        end: end,
        text: text,
        confidence: confidence,
        levelDBFS: nil,
        speaker: global.map { SpeakerTag(global: $0) },
        clockOffsetMS: offset,
        receivedAt: nil
    ))
}

@Test func singleSegmentBecomesUtterance() {
    let id = UUID()
    var r = Reconciler()
    let result = r.apply(seg(id: id, device: "mac1", owner: "小芝", start: 0, end: 1000, text: "こんにちは"))
    #expect(result.count == 1)
    #expect(result[0].speaker == "小芝")
    #expect(result[0].sources == [id])
    #expect(result[0].id == id)
}

@Test func sameDeviceNeverMerges() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", start: 0, end: 3000, text: "こんにちは"))
    r.apply(seg(device: "mac1", start: 0, end: 3000, text: "こんにちは"))
    #expect(r.utterances.count == 2)
}

@Test func differentDevicesOverlappingSimilarMerge() {
    var r = Reconciler()
    let macID = UUID()
    r.apply(seg(id: macID, device: "mac1", source: .mic, start: 0, end: 3000, text: "明日の会議は十時からです", confidence: 0.8))
    let result = r.apply(seg(device: "iphone1", source: .mic, start: 200, end: 3100, text: "明日の会議は10時からです", confidence: 0.9))
    #expect(result.count == 1)
    #expect(result[0].text == "明日の会議は10時からです")
    #expect(result[0].start == 0)
    #expect(result[0].end == 3100)
    #expect(result[0].id == macID)
    #expect(result[0].sources.count == 2)
}

@Test func systemBeatsMicOnEqualConfidence() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", owner: "リモート", source: .system, start: 0, end: 3000, text: "こんにちは", confidence: 0.8))
    let result = r.apply(seg(device: "iphone1", owner: "小芝", source: .mic, start: 0, end: 3000, text: "こんにちは", confidence: 0.8))
    #expect(result.count == 1)
    #expect(result[0].text == "こんにちは")
    #expect(result[0].speaker == "リモート")
}

@Test func nonOverlappingStaySeparate() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", start: 0, end: 3000, text: "こんにちは"))
    r.apply(seg(device: "iphone1", start: 5000, end: 8000, text: "こんにちは"))
    #expect(r.utterances.count == 2)
}

@Test func dissimilarTextStaysSeparate() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", start: 0, end: 3000, text: "明日の会議は十時からです"))
    r.apply(seg(device: "iphone1", start: 0, end: 3000, text: "資料を送っておきますね"))
    #expect(r.utterances.count == 2)
}

@Test func clockOffsetApplied() {
    var r = Reconciler()
    let result = r.apply(seg(device: "mac1", start: 1000, end: 2000, text: "こんにちは", offset: -1000))
    #expect(result[0].start == 0)
    #expect(r.utterances[0].start == 0)
}

@Test func lateSegmentUpsertsExistingUtterance() {
    var r = Reconciler()
    let firstResult = r.apply(seg(device: "mac1", source: .mic, start: 0, end: 3000, text: "明日の会議は十時からです", confidence: 0.7))
    let u = firstResult[0]
    let secondResult = r.apply(seg(device: "iphone1", source: .mic, start: 200, end: 3100, text: "明日の会議は10時からです", confidence: 0.95))
    #expect(secondResult.count == 1)
    #expect(secondResult[0].id == u.id)
    #expect(secondResult[0].text == "明日の会議は10時からです")
    #expect(r.utterances.count == 1)
}

@Test func speakerNameRenamesLabel() {
    var r = Reconciler()
    let resultA = r.apply(seg(device: "mac1", start: 0, end: 1000, text: "こんにちは", global: "話者1"))
    #expect(resultA[0].speaker == "話者1")

    let renameResult = r.apply(.speakerName(SpeakerNameRecord(speaker: "話者1", name: "田中")))
    #expect(renameResult.count == 1)
    #expect(renameResult[0].speaker == "田中")

    let resultB = r.apply(seg(device: "mac2", start: 5000, end: 6000, text: "さようなら", global: "話者1"))
    #expect(resultB[0].speaker == "田中")
}

@Test func duplicateIdIgnored() {
    var r = Reconciler()
    let record = seg(device: "mac1", start: 0, end: 1000, text: "こんにちは")
    r.apply(record)
    let second = r.apply(record)
    #expect(second == [])
    #expect(r.utterances.count == 1)
}

@Test func emptyTextIgnored() {
    var r = Reconciler()
    let result = r.apply(seg(device: "mac1", start: 0, end: 1000, text: "  "))
    #expect(result == [])
}

@Test func insertKeepsStartOrder() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", start: 5000, end: 6000, text: "明日の会議は十時からです"))
    r.apply(seg(device: "iphone1", start: 1000, end: 2000, text: "資料を送っておきますね"))
    #expect(r.utterances[0].start == 1000)
}

@Test func foldEqualsSequentialApply() {
    let macID = UUID()
    let records: [Record] = [
        seg(id: macID, device: "mac1", source: .mic, start: 0, end: 3000, text: "明日の会議は十時からです", confidence: 0.7, global: "話者1"),
        .speakerName(SpeakerNameRecord(speaker: "話者1", name: "田中")),
        seg(device: "iphone1", source: .mic, start: 200, end: 3100, text: "明日の会議は10時からです", confidence: 0.95),
        seg(device: "watch1", source: .watch, start: 5000, end: 6000, text: "資料を送っておきますね"),
    ]

    let folded = Reconciler.fold(records)

    var manual = Reconciler()
    for record in records {
        manual.apply(record)
    }

    #expect(folded == manual.utterances)
}
