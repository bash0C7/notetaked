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
    global: String? = nil,
    input: InputDevice = .test,
    direction: Direction? = nil
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
        input: input,
        start: start,
        end: end,
        text: text,
        confidence: confidence,
        levelDBFS: nil,
        speaker: global.map { SpeakerTag(global: $0) },
        direction: direction,
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

@Test func toleranceMergeWithinGapButNotBeyond() {
    var withinTolerance = Reconciler()
    withinTolerance.apply(seg(device: "mac1", start: 0, end: 3000, text: "明日の会議は十時からです"))
    let merged = withinTolerance.apply(seg(device: "iphone1", start: 2000, end: 5000, text: "明日の会議は十時からです"))
    #expect(merged.count == 1)
    #expect(withinTolerance.utterances.count == 1)
    #expect(merged[0].start == 0)
    #expect(merged[0].end == 5000)

    var beyondTolerance = Reconciler()
    beyondTolerance.apply(seg(device: "mac1", start: 0, end: 3000, text: "明日の会議は十時からです"))
    beyondTolerance.apply(seg(device: "iphone1", start: 3600, end: 6600, text: "明日の会議は十時からです"))
    #expect(beyondTolerance.utterances.count == 2)
}

@Test func mergesIntoCandidateWithLargestOverlap() {
    var r = Reconciler()
    let macID = UUID()
    let iphoneID = UUID()
    r.apply(seg(id: macID, device: "mac1", start: 0, end: 3000, text: "明日の会議は十時からです"))
    r.apply(seg(id: iphoneID, device: "iphone1", start: 3200, end: 6200, text: "明日の会議は十時からです"))
    #expect(r.utterances.count == 2)

    let result = r.apply(
        seg(device: "watch1", source: .watch, start: 1000, end: 5000, text: "明日の会議は10時からです"))
    #expect(result.count == 1)
    #expect(result[0].id == macID)
    #expect(r.utterances.count == 2)
    #expect(r.utterances.first { $0.id == iphoneID }?.sources.count == 1)
}

@Test func losingSegmentStillSuppliesSpeakerID() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", source: .mic, start: 0, end: 3000, text: "明日の会議は十時からです", confidence: 0.9))
    let result = r.apply(
        seg(
            device: "iphone1", source: .mic, start: 200, end: 3100, text: "明日の会議は10時からです",
            confidence: 0.1, global: "話者1"))
    #expect(result.count == 1)
    #expect(result[0].text == "明日の会議は十時からです")
    #expect(result[0].speakerID == "話者1")
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

@Test func utteranceCarriesInputPlatformAndDirectionOfSegment() {
    var r = Reconciler()
    let d = Direction(azimuthDeg: 90, confidence: 0.9)
    let out = r.apply(seg(device: "ip", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                          input: InputDevice(name: "iPhone マイク", uid: "m", spatial: true), direction: d))
    #expect(out[0].input == "iPhone マイク")
    #expect(out[0].platform == .ios)
    #expect(out[0].direction == d)
}

@Test func mergeKeepsDirectionFromSpatialSegmentEvenWhenTextComesFromOther() {
    var r = Reconciler()
    let d = Direction(azimuthDeg: 90, confidence: 0.9)
    r.apply(seg(device: "ip", platform: .ios, start: 0, end: 1000, text: "こんにちは", confidence: 0.5,
                input: InputDevice(name: "iPhone マイク", uid: "m", spatial: true), direction: d))
    let out = r.apply(seg(device: "mac", start: 100, end: 1100, text: "こんにちは。", confidence: 0.9))
    #expect(out[0].text == "こんにちは。")
    #expect(out[0].input == "MacBook Airのマイク")
    #expect(out[0].platform == .mac)
    #expect(out[0].direction == d)
}

@Test func mergePrefersHigherConfidenceDirection() {
    var r = Reconciler()
    let weak = Direction(azimuthDeg: 10, confidence: 0.3)
    let strong = Direction(azimuthDeg: 200, confidence: 0.8)
    r.apply(seg(device: "a", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                input: InputDevice(name: "a", uid: "a", spatial: true), direction: weak))
    let out = r.apply(seg(device: "b", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                          input: InputDevice(name: "b", uid: "b", spatial: true), direction: strong))
    #expect(out[0].direction == strong)
}
