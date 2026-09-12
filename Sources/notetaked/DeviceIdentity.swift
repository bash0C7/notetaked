import Foundation

/// Macのdevice id（永続UUID）と表示名
struct DeviceIdentity: Sendable {
    let id: String
    let name: String

    /// `~/Library/Application Support/Notetake/device-id` にUUIDを保存し、以後はそれを再利用する。
    /// 読み書きに失敗した場合でも、今回のrun用に新規UUIDを返す（stderrへ警告）。
    static func load() -> DeviceIdentity {
        let name = Host.current().localizedName ?? "Mac"

        guard
            let supportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return DeviceIdentity(id: UUID().uuidString, name: name)
        }
        let directory = supportDirectory.appendingPathComponent("Notetake")
        let fileURL = directory.appendingPathComponent("device-id")

        if let data = try? Data(contentsOf: fileURL),
            let existing = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return DeviceIdentity(id: existing, name: name)
        }

        let newID = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try newID.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                Data("warning: failed to persist device id: \(error)\n".utf8))
        }
        return DeviceIdentity(id: newID, name: name)
    }
}
