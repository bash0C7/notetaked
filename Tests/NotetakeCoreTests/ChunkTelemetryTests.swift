import Foundation
import Testing
@testable import NotetakeCore

private func baseMetadata() -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: "s", index: 0, startAtMS: 0, sampleRate: 48000, device: "d", deviceName: "n", owner: "o")
}

@Test func emptyTelemetryLeavesMetadataUntouched() {
    let telemetry = ChunkTelemetry()
    let metadata = telemetry.applied(to: baseMetadata())
    #expect(metadata.maxDBFS == nil)
    #expect(metadata.meanDBFS == nil)
    #expect(metadata.batteryLevel == nil)
    #expect(metadata.maxQueueDepth == nil)
}

@Test func telemetryKeepsMaxQueueDepthAndLastBattery() {
    var telemetry = ChunkTelemetry()
    telemetry.add(dbfs: -50, batteryLevel: 0.8, queueDepth: 2)
    telemetry.add(dbfs: -30, batteryLevel: 0.7, queueDepth: 5)
    telemetry.add(dbfs: -40, batteryLevel: nil, queueDepth: 1)
    let metadata = telemetry.applied(to: baseMetadata())
    #expect(metadata.maxDBFS == -30)
    #expect(metadata.meanDBFS == -40)
    #expect(metadata.maxQueueDepth == 5)
    #expect(metadata.batteryLevel == 0.7)
}

@Test func telemetryResetStartsTheNextChunkClean() {
    var telemetry = ChunkTelemetry()
    telemetry.add(dbfs: -50, batteryLevel: 0.8, queueDepth: 3)
    telemetry.reset()
    let metadata = telemetry.applied(to: baseMetadata())
    #expect(metadata.maxDBFS == nil)
    #expect(metadata.batteryLevel == nil)
    #expect(metadata.maxQueueDepth == nil)
}
