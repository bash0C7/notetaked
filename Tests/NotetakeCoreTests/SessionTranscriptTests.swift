import Foundation
import Testing
@testable import NotetakeCore

@Test func sessionTranscriptRendersFinalSpeakersFromTimedText() throws {
    let plan = FinalizeImport.plan(
        result: FinalizeResult(
            run: 1,
            sources: [
                FinalizeSourceResult(
                    source: .mic,
                    utterances: [
                        FinalizeUtterance(
                            id: UUID(), speaker: "S1", start: 0, end: 1_000, text: "こんにちは", confidence: nil,
                            levelDBFS: -20, input: .test)
                    ],
                    speakers: [FinalizeSpeaker(local: "S1", seconds: 1, excerpt: "こんにちは", firstStartMS: 0, centroid: [1])])
            ]),
        info: CaptureSessionInfo(outputDirectory: "/o", device: "mac1", deviceName: "n", owner: "山田太郎"),
        prefix: "p", previous: nil, receivedAt: 0)
    let text = try plan.records.map { try NDJSON.encode($0) + "\n" }.joined()
    let markdown = SessionTranscript.markdown(timedText: text, timeZone: TimeZone(identifier: "UTC")!)
    #expect(markdown == "00:00:00 **話者1**（Mac）: こんにちは\n")
}
