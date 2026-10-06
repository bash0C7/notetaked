import Foundation
import Testing
@testable import NotetakeCore

private func state(_ prefix: String, _ phase: FinalizePhase, detail: String? = nil) -> FinalizeStateEvent {
    FinalizeStateEvent(prefix: prefix, phase: phase, detail: detail)
}

@Test func statusTextCoversEveryPhase() {
    #expect(FinalizeStatusLabel.text(for: state("p", .waiting)) == "確定待ち")
    #expect(FinalizeStatusLabel.text(for: state("p", .running, detail: "mic 文字起こし 35%")) == "確定中（mic 文字起こし 35%）")
    #expect(FinalizeStatusLabel.text(for: state("p", .finalized)) == "確定済み")
    #expect(FinalizeStatusLabel.text(for: state("p", .failed, detail: "進捗が途絶えました")) == "確定に失敗（再試行待ち）: 進捗が途絶えました")
    #expect(FinalizeStatusLabel.text(for: state("p", .gaveUp)) == "確定を諦めました")
}

@Test func menuLinesListRunningWaitingAndFailedButNotFinalized() {
    let states = [
        "a": state("a", .finalized),
        "b": state("b", .running, detail: "system 話者分離 10%"),
        "c": state("c", .waiting),
        "d": state("d", .waiting),
        "e": state("e", .gaveUp, detail: "model"),
    ]
    #expect(
        FinalizeStatusLabel.menuLines(states: states) == [
            "b: 確定中（system 話者分離 10%）", "確定待ち 2件", "e: 確定を諦めました: model",
        ])
    #expect(FinalizeStatusLabel.menuLines(states: [:]).isEmpty)
}

private func controls(
    recording: Bool = false, prefix: String? = "p", polishing: Bool = false,
    states: [String: FinalizeStateEvent] = [:]
) -> RecordingControls {
    RecordingControls(
        isRecording: recording, hasOutputDirectory: true, isPolishing: polishing, lastFinishedPrefix: prefix,
        finalizeStates: states)
}

@Test func recordingButtonsFollowTheRecordingState() {
    let idle = controls()
    #expect(idle.canStart && !idle.canStop && !idle.canRotate)
    let recording = controls(recording: true)
    #expect(!recording.canStart && recording.canStop && recording.canRotate)
    let noDirectory = RecordingControls(
        isRecording: false, hasOutputDirectory: false, isPolishing: false, lastFinishedPrefix: nil,
        finalizeStates: [:])
    #expect(!noDirectory.canStart && !noDirectory.canPolish)
}

@Test func polishIsAvailableOnlyAfterFinalizationOrGivingUp() {
    func canPolish(_ phase: FinalizePhase?) -> RecordingControls {
        controls(states: phase.map { ["p": state("p", $0)] } ?? [:])
    }
    #expect(!canPolish(.waiting).canPolish)
    #expect(!canPolish(.running).canPolish)
    #expect(!canPolish(.failed).canPolish)
    #expect(canPolish(.finalized).canPolish)
    #expect(canPolish(.finalized).polishNote == nil)
    #expect(canPolish(.gaveUp).canPolish)
    #expect(canPolish(.gaveUp).polishNote == "確定を諦めたため、暫定版を整形します")
    #expect(canPolish(nil).canPolish)
    #expect(!controls(polishing: true).canPolish)
    #expect(!controls(prefix: nil).canPolish)
}

@Test func catalogListsRecordingsNewestFirstWithTheirFinalizationFacts() throws {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-raw-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: base)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for prefix in ["2026-10-05_090000", "2026-10-06_090000", "2026-10-06_100000"] {
        try Data().write(to: SessionFiles.timedURL(prefix: prefix, directory: output))
    }
    try SpeakersFile(run: 2, speakers: []).write(to: SpeakersFile.url(prefix: "2026-10-06_090000", directory: output))
    try Data(#"[{"id":"g1"}]"#.utf8).write(to: SpeakersFile.url(prefix: "2026-10-05_090000", directory: output))
    try JSONFile.write(
        CaptureSessionInfo(outputDirectory: output.path, device: "d", deviceName: "n", owner: "o"),
        to: CaptureSessionPaths.sessionInfoURL(
            sessionDirectory: CaptureSessionPaths.sessionDirectory(
                prefix: "2026-10-06_100000", baseTemporaryDirectory: base)))

    let entries = RecordingCatalog.scan(outputDirectory: output, rawBase: base)
    #expect(entries.map(\.prefix) == ["2026-10-06_100000", "2026-10-06_090000", "2026-10-05_090000"])
    #expect(entries.map(\.finalizedRun) == [nil, 2, nil])
    #expect(entries.map(\.hasRawAudio) == [true, false, false])

    #expect(RecordingCatalog.statusText(entry: entries[1], state: nil) == "確定済み")
    #expect(RecordingCatalog.statusText(entry: entries[0], state: nil) == "未確定")
    #expect(RecordingCatalog.statusText(entry: entries[0], state: state("x", .running)) == "確定中")
    #expect(RecordingCatalog.canRefinalize(entry: entries[0], state: nil))
    #expect(!RecordingCatalog.canRefinalize(entry: entries[0], state: state("x", .running)))
    #expect(!RecordingCatalog.canRefinalize(entry: entries[1], state: nil))
    #expect(RecordingCatalog.canRefinalize(entry: entries[0], state: state("x", .gaveUp)))
}

@Test func recordingTitleReadsThePrefixAsAStartTime() {
    func entry(_ prefix: String) -> RecordingEntry {
        RecordingEntry(prefix: prefix, finalizedRun: nil, speakers: [], hasRawAudio: false)
    }
    #expect(entry("2026-10-06_100500").title == "2026-10-06 10:05:00")
    #expect(entry("not-a-prefix").title == "not-a-prefix")
    #expect(entry("2026-10-06_1005").title == "2026-10-06_1005")
}

@Test func durationLabelShowsMinutesAndSeconds() {
    #expect(DurationLabel.text(seconds: 0) == "0:00")
    #expect(DurationLabel.text(seconds: 59.6) == "1:00")
    #expect(DurationLabel.text(seconds: 754) == "12:34")
    #expect(DurationLabel.text(seconds: 4_000) == "66:40")
    #expect(DurationLabel.text(seconds: -3) == "0:00")
}
