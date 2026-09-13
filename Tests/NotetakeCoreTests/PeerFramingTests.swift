import Foundation
import Testing
@testable import NotetakeCore

@Test func lineBufferSplitsAcrossAppends() {
    var buffer = LineBuffer()
    #expect(buffer.append(Data("hel".utf8)) == [])
    #expect(buffer.append(Data("lo\n".utf8)) == ["hello"])
}

@Test func lineBufferMultipleLinesInOneAppend() {
    var buffer = LineBuffer()
    let lines = buffer.append(Data("one\ntwo\nthree\n".utf8))
    #expect(lines == ["one", "two", "three"])
}

@Test func lineBufferKeepsRemainderForNextAppend() {
    var buffer = LineBuffer()
    #expect(buffer.append(Data("first\nsecond".utf8)) == ["first"])
    #expect(buffer.append(Data("-rest\n".utf8)) == ["second-rest"])
}

@Test func lineBufferSkipsEmptyLines() {
    var buffer = LineBuffer()
    let lines = buffer.append(Data("\n\nfoo\n\nbar\n\n".utf8))
    #expect(lines == ["foo", "bar"])
}

@Test func lineBufferHandlesUTF8MultibyteAcrossAppends() {
    var buffer = LineBuffer()
    let full = Data("こんにちは\n".utf8)
    let mid = full.count / 2
    #expect(buffer.append(full.subdata(in: full.startIndex..<mid)) == [])
    #expect(buffer.append(full.subdata(in: mid..<full.endIndex)) == ["こんにちは"])
}
