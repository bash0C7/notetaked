import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func instanceLockIsExclusiveUntilReleased() throws {
    let url = temporaryDirectory("lock").appendingPathComponent("capture-daemon.lock")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var first = try InstanceLock.acquire(at: url)
    #expect(first != nil)
    #expect(try InstanceLock.acquire(at: url) == nil)
    first = nil
    #expect(try InstanceLock.acquire(at: url) != nil)
}
