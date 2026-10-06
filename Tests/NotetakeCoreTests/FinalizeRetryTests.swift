import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("finalize-\(UUID().uuidString)")
}

@Test func retryDelaysAreOneTenAndSixtyMinutesThenStop() {
    #expect(FinalizeRetryPolicy.delay(afterFailureCount: 0) == nil)
    #expect(FinalizeRetryPolicy.delay(afterFailureCount: 1) == 60)
    #expect(FinalizeRetryPolicy.delay(afterFailureCount: 2) == 600)
    #expect(FinalizeRetryPolicy.delay(afterFailureCount: 3) == 3_600)
    #expect(FinalizeRetryPolicy.delay(afterFailureCount: 4) == nil)
    #expect(!FinalizeRetryPolicy.isGivenUp(failureCount: 3))
    #expect(FinalizeRetryPolicy.isGivenUp(failureCount: 4))
}

@Test func attemptsFileKeepsTheFailureCount() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(try FinalizeAttempts.read(sessionDirectory: directory) == 0)
    try FinalizeAttempts.write(2, sessionDirectory: directory)
    #expect(try FinalizeAttempts.read(sessionDirectory: directory) == 2)
    try AtomicFile.write(Data("x".utf8), to: CaptureSessionPaths.finalizeAttemptsURL(sessionDirectory: directory))
    #expect(throws: (any Error).self) {
        _ = try FinalizeAttempts.read(sessionDirectory: directory)
    }
    FinalizeAttempts.clear(sessionDirectory: directory)
    #expect(try FinalizeAttempts.read(sessionDirectory: directory) == 0)
}
