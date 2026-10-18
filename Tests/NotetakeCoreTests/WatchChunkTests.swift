import Foundation
import Testing
@testable import NotetakeCore

private func fixtureMeta(
    session: String = "1700000000000",
    index: Int = 0,
    startAtMS: Int64 = 1_700_000_000_000,
    sampleRate: Double = 16000,
    device: String = "watch-abc",
    deviceName: String = "小芝のApple Watch",
    owner: String = "小芝"
) -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: session,
        index: index,
        startAtMS: startAtMS,
        sampleRate: sampleRate,
        device: device,
        deviceName: deviceName,
        owner: owner
    )
}

// MARK: - WatchChunkMetadata

@Test func metadataRoundTripsThroughDictionary() {
    let meta = fixtureMeta()
    let restored = WatchChunkMetadata(metadata: meta.metadata)
    #expect(restored == meta)
}

@Test func metadataDictionaryUsesSnakeCaseKeys() {
    let meta = fixtureMeta()
    let dict = meta.metadata
    #expect(dict["session"] as? String == meta.session)
    #expect(dict["index"] as? Int == meta.index)
    #expect(dict["start_at_ms"] as? Int64 == meta.startAtMS)
    #expect(dict["sample_rate"] as? Double == meta.sampleRate)
    #expect(dict["device"] as? String == meta.device)
    #expect(dict["device_name"] as? String == meta.deviceName)
    #expect(dict["owner"] as? String == meta.owner)
}

@Test func metadataRoundTripsWithStartAtMSAsNSNumber() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = NSNumber(value: meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataRoundTripsWithStartAtMSAsDouble() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = Double(meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataRoundTripsWithStartAtMSAsInt() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = Int(meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataInitFailsWhenKeyIsMissing() {
    var dict = fixtureMeta().metadata
    dict.removeValue(forKey: "owner")
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsWhenTypeIsWrong() {
    var dict = fixtureMeta().metadata
    dict["index"] = "0" // should be Int, not String
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsWhenStartAtMSIsNotNumeric() {
    var dict = fixtureMeta().metadata
    dict["start_at_ms"] = "not-a-number"
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsOnEmptyDictionary() {
    #expect(WatchChunkMetadata(metadata: [:]) == nil)
}

private let legacyMetadataKeys: Set<String> = [
    "session", "index", "start_at_ms", "sample_rate", "device", "device_name", "owner",
]

@Test func oldMetadataWithoutSummaryStillDecodes() {
    let dict: [String: Any] = [
        "session": "1700000000000",
        "index": 0,
        "start_at_ms": Int64(1_700_000_000_000),
        "sample_rate": 16000.0,
        "device": "watch-abc",
        "device_name": "小芝のApple Watch",
        "owner": "小芝",
    ]
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored != nil)
    #expect(restored?.maxDBFS == nil)
    #expect(restored?.meanDBFS == nil)
    #expect(restored?.batteryLevel == nil)
    #expect(restored?.maxQueueDepth == nil)
}

@Test func metadataWithSummaryRoundTrips() {
    var meta = fixtureMeta()
    meta.maxDBFS = -12.5
    meta.meanDBFS = -40.25
    meta.batteryLevel = 0.8
    meta.maxQueueDepth = 3
    let restored = WatchChunkMetadata(metadata: meta.metadata)
    #expect(restored == meta)
}

@Test func metadataWithoutSummaryOmitsTheNewKeys() {
    let keys = Set(fixtureMeta().metadata.keys)
    #expect(keys == legacyMetadataKeys)
}

@Test func summaryWithWrongTypesIsIgnoredNotRejected() {
    var dict = fixtureMeta().metadata
    dict["max_dbfs"] = "x"
    dict["max_queue_depth"] = "y"
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored != nil)
    #expect(restored?.maxDBFS == nil)
    #expect(restored?.maxQueueDepth == nil)
}

@Test func summaryNumbersAcceptNSNumberAndInt() {
    var dict = fixtureMeta().metadata
    dict["max_dbfs"] = NSNumber(value: -20.5)
    dict["battery_level"] = Int(1)
    dict["max_queue_depth"] = NSNumber(value: 4)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored?.maxDBFS == -20.5)
    #expect(restored?.batteryLevel == 1.0)
    #expect(restored?.maxQueueDepth == 4)
}

@Test func negativeQueueDepthIsIgnored() {
    var dict = fixtureMeta().metadata
    dict["max_queue_depth"] = -1
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored != nil)
    #expect(restored?.maxQueueDepth == nil)

    dict["max_queue_depth"] = NSNumber(value: -3)
    #expect(WatchChunkMetadata(metadata: dict)?.maxQueueDepth == nil)
}

@Test func boolIsNotReadAsNumber() {
    var dict = fixtureMeta().metadata
    dict["max_queue_depth"] = true
    dict["battery_level"] = NSNumber(value: true)
    dict["max_dbfs"] = false
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored != nil)
    #expect(restored?.maxQueueDepth == nil)
    #expect(restored?.batteryLevel == nil)
    #expect(restored?.maxDBFS == nil)
}

@Test func nonFiniteSummaryDoublesAreIgnored() {
    var dict = fixtureMeta().metadata
    dict["max_dbfs"] = Double.nan
    dict["mean_dbfs"] = -Double.infinity
    dict["battery_level"] = Double.infinity
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored != nil)
    #expect(restored?.maxDBFS == nil)
    #expect(restored?.meanDBFS == nil)
    #expect(restored?.batteryLevel == nil)
}

// MARK: - duration_ms / is_final / JSON

@Test func metadataWithDurationAndFinalRoundTrips() {
    var meta = fixtureMeta()
    meta.durationMS = 20_000
    meta.isFinal = true
    #expect(WatchChunkMetadata(metadata: meta.metadata) == meta)
}

@Test func oldMetadataHasNoDurationOrFinal() {
    let dict: [String: Any] = [
        "session": "1", "index": 0, "start_at_ms": 1_700_000_000_000, "sample_rate": 16000.0,
        "device": "d", "device_name": "n", "owner": "o",
        "max_dbfs": -20.0, "mean_dbfs": -30.0, "battery_level": 0.5, "max_queue_depth": 1,
    ]
    let meta = WatchChunkMetadata(metadata: dict)
    #expect(meta != nil)
    #expect(meta?.durationMS == nil)
    #expect(meta?.isFinal == nil)
}

@Test func nilDurationAndFinalAreOmitted() {
    let keys = Set(fixtureMeta().metadata.keys)
    #expect(!keys.contains("duration_ms"))
    #expect(!keys.contains("is_final"))
}

@Test func finalAcceptsNSNumberBool() {
    var dict = fixtureMeta().metadata
    dict["is_final"] = NSNumber(value: true)
    dict["duration_ms"] = NSNumber(value: 1234)
    let meta = WatchChunkMetadata(metadata: dict)
    #expect(meta?.isFinal == true)
    #expect(meta?.durationMS == 1234)
}

private func fullMeta() -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: "1700000000000", index: 7, startAtMS: 4_000_000_000_000, sampleRate: 48000,
        device: "watch-abc", deviceName: "小芝のApple Watch", owner: "小芝",
        maxDBFS: -12.5, meanDBFS: -30.25, batteryLevel: 0.75, maxQueueDepth: 2,
        durationMS: 20_000, isFinal: true)
}

@Test func metadataRoundTripsThroughJSON() throws {
    let meta = fullMeta()
    #expect(WatchChunkMetadata(json: try meta.encodedJSON()) == meta)
}

@Test func legacySidecarJSONStillDecodes() throws {
    let meta = fixtureMeta()
    let data = try JSONSerialization.data(withJSONObject: meta.metadata)
    #expect(WatchChunkMetadata(json: String(decoding: data, as: UTF8.self)) == meta)
}

@Test func brokenJSONIsNil() {
    #expect(WatchChunkMetadata(json: "{not json") == nil)
    #expect(WatchChunkMetadata(json: "[]") == nil)
    #expect(WatchChunkMetadata(json: "{}") == nil)
}
