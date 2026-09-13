import Foundation
import WatchKit

/// Watch端末の識別子（`~/Documents/device-id`にUUIDとして永続化）と表示名。
/// `Sources/notetaked/DeviceIdentity.swift`（Mac側）と同じ考え方。
enum WatchIdentity {
    private static let fileName = "device-id"

    /// 初回はUUIDを生成して`~/Documents/device-id`へ保存し、以後は保存済みの値を返す。
    /// 読み書きに失敗した場合でも、そのrun用に新規UUIDを返す（永続化はできないが動作は継続する）。
    static func deviceID() -> String {
        let url = documentsDirectory().appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url),
            let existing = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return existing
        }
        let id = UUID().uuidString
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    static var deviceName: String {
        WKInterfaceDevice.current().name
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
