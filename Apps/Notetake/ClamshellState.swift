import Foundation
import IOKit

/// ノートPCの蓋の開閉。IORegistryの`IOPMrootDomain`にある`AppleClamshellState`を読む
enum ClamshellState {
    /// 蓋が閉じていればtrue。読めなければfalse
    static func isClosed() -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
