import Foundation
import Testing
@testable import NotetakeCore

@Test func everyOperationHasTheKeyOfTheDesignTable() {
    #expect(ServeOperation.desiredState.errorKey == "desired")
    #expect(ServeOperation.startRecording.errorKey == "recording.start")
    #expect(ServeOperation.appendLive.errorKey == "archive.live")
    #expect(ServeOperation.appendPeerOther.errorKey == "peer.other")
    #expect(ServeOperation.appendOrphan.errorKey == "peer.orphan")
    #expect(ServeOperation.startPeerListener.errorKey == "peer.listener")
    #expect(ServeOperation.liveTranscription(.mic).errorKey == "live.mic")
    #expect(ServeOperation.liveTranscription(.system).errorKey == "live.system")
    #expect(ServeOperation.finalize(prefix: "2026-11-19-1234").errorKey == "final.2026-11-19-1234")
}

@Test func failedCarriesTheMessageAndTheOperationKey() {
    var reporter = ServeErrorReporter()
    #expect(
        reporter.failed(.appendLive, message: "failed to append segment: x")
            == .error("failed to append segment: x", key: "archive.live"))
}

@Test func succeededResolvesOnlyAfterAFailureAndOnlyOnce() {
    var reporter = ServeErrorReporter()
    #expect(reporter.succeeded(.appendLive) == nil)
    _ = reporter.failed(.appendLive, message: "x")
    #expect(reporter.succeeded(.appendLive) == .resolved(key: "archive.live"))
    #expect(reporter.succeeded(.appendLive) == nil)
}

@Test func succeededOfAnotherOperationKeepsTheError() {
    var reporter = ServeErrorReporter()
    _ = reporter.failed(.appendLive, message: "x")
    #expect(reporter.succeeded(.appendOrphan) == nil)
    #expect(reporter.succeeded(.appendLive) == .resolved(key: "archive.live"))
}

@Test func everyOperationRecoversByItsOwnSuccess() {
    let operations: [ServeOperation] = [
        .desiredState, .startRecording, .appendLive, .appendPeerOther, .appendOrphan, .startPeerListener,
        .liveTranscription(.mic), .liveTranscription(.system), .finalize(prefix: "a"),
    ]
    for operation in operations {
        var reporter = ServeErrorReporter()
        _ = reporter.failed(operation, message: "x")
        #expect(reporter.succeeded(operation) == .resolved(key: operation.errorKey))
    }
}

@Test func liveTranscriptionRecoversPerSource() {
    var reporter = ServeErrorReporter()
    _ = reporter.failed(.liveTranscription(.mic), message: "x")
    _ = reporter.failed(.liveTranscription(.system), message: "y")
    #expect(reporter.succeeded(.liveTranscription(.mic)) == .resolved(key: "live.mic"))
    #expect(reporter.succeeded(.liveTranscription(.mic)) == nil)
    #expect(reporter.succeeded(.liveTranscription(.system)) == .resolved(key: "live.system"))
}

@Test func finalizeRecoversPerPrefix() {
    var reporter = ServeErrorReporter()
    _ = reporter.failed(.finalize(prefix: "a"), message: "x")
    #expect(reporter.succeeded(.finalize(prefix: "b")) == nil)
    #expect(reporter.succeeded(.finalize(prefix: "a")) == .resolved(key: "final.a"))
}
