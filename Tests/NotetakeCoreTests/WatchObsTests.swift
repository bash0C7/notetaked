import Foundation
import Testing
@testable import NotetakeCore

// MARK: - WatchObsRecord

@Test func recordRoundTripsThroughALine() throws {
    let record = WatchObsRecord(
        atMS: 1_700_000_000_123,
        event: .chunkClosed,
        session: "1700000000000",
        index: 3,
        detail: "ok",
        value: 0.5
    )
    let line = try record.encodedLine()
    #expect(WatchObsRecord.decodeLines(line) == [record])
}

@Test func recordLineOmitsNilFieldsAndSortsKeys() throws {
    let line = try WatchObsRecord(atMS: 5, event: .started).encodedLine()
    #expect(line == #"{"at_ms":5,"event":"started"}"#)
}

@Test func eventRawValuesAreSnakeCase() throws {
    let line = try WatchObsRecord(atMS: 1, event: .interruptionBegan).encodedLine()
    #expect(line.contains("\"interruption_began\""))
}

@Test func decodeLinesSkipsBlankBrokenAndUnknownLines() {
    let text = [
        #"{"at_ms":1,"event":"launched"}"#,
        "",
        #"{"at_ms":1,"ev"#,
        #"{"at_ms":2,"event":"future_event"}"#,
        #"{"at_ms":3,"event":"stopped"}"#,
    ].joined(separator: "\n")
    let records = WatchObsRecord.decodeLines(text)
    #expect(records == [
        WatchObsRecord(atMS: 1, event: .launched),
        WatchObsRecord(atMS: 3, event: .stopped),
    ])
}

@Test func decodeLinesKeepsUnicodeLineSeparatorsInsideALine() throws {
    let record = WatchObsRecord(atMS: 1, event: .writeFailed, detail: "a\u{2028}b\u{0085}c")
    let text = try record.encodedLine() + "\n"
    #expect(WatchObsRecord.decodeLines(text) == [record])
}

@Test func decodeLinesAcceptsCRLF() {
    let text = "{\"at_ms\":1,\"event\":\"launched\"}\r\n{\"at_ms\":2,\"event\":\"stopped\"}\r\n"
    #expect(WatchObsRecord.decodeLines(text).map(\.atMS) == [1, 2])
}

@Test func everyEventHasItsExpectedRawValue() {
    let expected: [(WatchObsEvent, String)] = [
        (.launched, "launched"), (.scenePhase, "scene_phase"), (.started, "started"),
        (.startFailed, "start_failed"), (.stopped, "stopped"), (.halted, "halted"),
        (.interruptionBegan, "interruption_began"), (.interruptionEnded, "interruption_ended"),
        (.configurationChanged, "configuration_changed"),
        (.mediaServicesReset, "media_services_reset"), (.chunkClosed, "chunk_closed"),
        (.writeFailed, "write_failed"), (.transferFinished, "transfer_finished"),
        (.transferFailed, "transfer_failed"), (.tapQueue, "tap_queue"),
    ]
    for (event, raw) in expected {
        #expect(event.rawValue == raw)
    }
}

@Test func tapQueueRecordCarriesDepthAndLag() throws {
    let record = WatchObsRecord(atMS: 9, event: .tapQueue, value: 4, lagMS: 1500)
    let line = try record.encodedLine()
    #expect(line == #"{"at_ms":9,"event":"tap_queue","lag_ms":1500,"value":4}"#)
    #expect(WatchObsRecord.decodeLines(line) == [record])
}

@Test func lagMSIsOmittedWhenNil() throws {
    let line = try WatchObsRecord(atMS: 9, event: .tapQueue, value: 4).encodedLine()
    #expect(!line.contains("lag_ms"))
}

// MARK: - WatchTransferKind

@Test func transferKindIsObsOnlyWithTheObsKind() {
    #expect(WatchTransferKind.of(["kind": "obs"]) == .obs)
    #expect(WatchTransferKind.of(legacyChunkMetadata()) == .chunk)
    #expect(WatchTransferKind.of(["kind": "other"]) == .chunk)
}

// MARK: - WatchObsFileMetadata

@Test func obsFileMetadataRoundTrips() {
    let meta = WatchObsFileMetadata(device: "W1", createdAtMS: 1_700_000_000_000)
    #expect(WatchObsFileMetadata(metadata: meta.metadata) == meta)

    var asNumber = meta.metadata
    asNumber["created_at_ms"] = NSNumber(value: 1_700_000_000_000 as Int64)
    #expect(WatchObsFileMetadata(metadata: asNumber) == meta)

    var asDouble = meta.metadata
    asDouble["created_at_ms"] = 1_700_000_000_000.0
    #expect(WatchObsFileMetadata(metadata: asDouble) == meta)
}

@Test func obsFileMetadataRejectsAChunk() {
    #expect(WatchObsFileMetadata(metadata: legacyChunkMetadata()) == nil)
}

@Test func obsFileMetadataRejectsMalformedMetadata() {
    #expect(WatchObsFileMetadata(metadata: ["kind": "obs", "created_at_ms": 1]) == nil)
    #expect(WatchObsFileMetadata(metadata: ["kind": "obs", "device": 5, "created_at_ms": 1]) == nil)
    #expect(WatchObsFileMetadata(metadata: ["kind": "obs", "device": "W1"]) == nil)
    #expect(WatchObsFileMetadata(metadata: ["kind": "obs", "device": "W1", "created_at_ms": "1"]) == nil)
    #expect(WatchObsFileMetadata(metadata: ["kind": "other", "device": "W1", "created_at_ms": 1]) == nil)
    #expect(WatchObsFileMetadata(metadata: ["device": "W1", "created_at_ms": 1]) == nil)
}

@Test func obsFileMetadataRejectsOutOfRangeNumbers() {
    for bad in [1e30, -1e30, Double.nan, Double.infinity] {
        #expect(WatchObsFileMetadata(metadata: ["kind": "obs", "device": "W1", "created_at_ms": bad]) == nil)
    }
}

@Test func obsMetadataIsNotAChunk() {
    let meta = WatchObsFileMetadata(device: "W1", createdAtMS: 1_700_000_000_000)
    #expect(WatchChunkMetadata(metadata: meta.metadata) == nil)
}

@Test func obsFileNameUsesDeviceAndCreationTime() {
    let meta = WatchObsFileMetadata(device: "W1", createdAtMS: 1_700_000_000_000)
    #expect(meta.fileName == "W1-1700000000000.jsonl")
}

/// `kind`を持たない旧形式の小片のmetadata
private func legacyChunkMetadata() -> [String: Any] {
    WatchChunkMetadata(
        session: "1700000000000",
        index: 0,
        startAtMS: 1_700_000_000_000,
        sampleRate: 16000,
        device: "watch-abc",
        deviceName: "Watch",
        owner: "owner"
    ).metadata
}
