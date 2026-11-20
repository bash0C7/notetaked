import Foundation
import Testing
@testable import NotetakeCore

@Test func resolveReportsOnlyActiveKeys() {
    var keys = ActiveErrorKeys()
    #expect(keys.resolve("archive.live") == false)
    keys.fail("archive.live")
    keys.fail("archive.live")
    #expect(keys.resolve("archive.live") == true)
    #expect(keys.resolve("archive.live") == false)
}
