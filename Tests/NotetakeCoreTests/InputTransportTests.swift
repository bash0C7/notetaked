import Testing
@testable import NotetakeCore

@Test func transportBuiltIn() {
    #expect(InputTransport(fourCC: 0x626C746E) == .builtIn)
}

@Test func transportContinuityWired() {
    #expect(InputTransport(fourCC: 0x63637764) == .continuity)
}

@Test func transportContinuityWireless() {
    #expect(InputTransport(fourCC: 0x6363776C) == .continuity)
}

@Test func transportUnknownIsOther() {
    #expect(InputTransport(fourCC: 0) == .other)
    #expect(InputTransport(fourCC: 0x75736220) == .other)
}
