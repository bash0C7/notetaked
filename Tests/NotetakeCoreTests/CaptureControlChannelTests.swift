// Tests/NotetakeCoreTests/CaptureControlChannelTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func pollReturnsNilWhenNothingSent() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    #expect(channel.poll(after: nil) == nil)
}

@Test func sendThenPollReturnsMessage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let result = channel.poll(after: nil)
    #expect(result?.message == .stopSession)
}

@Test func pollWithAfterSkipsAlreadySeenMessage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let first = channel.poll(after: nil)!
    #expect(channel.poll(after: first.sentAt) == nil)
}

@Test func secondSendIsVisibleAfterFirstIsSeen() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let first = channel.poll(after: nil)!
    try channel.send(.quit)
    let second = channel.poll(after: first.sentAt)
    #expect(second?.message == .quit)
}
