import Foundation
import NotetakeCore

/// Mac横断で永続化される命名済み話者プロファイルの読み書き。
/// `~/Library/Application Support/Notetake/speakers.json`（`DeviceIdentity`と同じ
/// ディレクトリ規則）。serve起動時に読み込んで`SpeakerRegistry`の初期profilesにし、
/// 命名・停止時に書き戻す
struct SpeakerProfileStore: Sendable {
    let url: URL

    static func `default`() -> SpeakerProfileStore {
        let supportDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let directory = supportDirectory.appendingPathComponent("Notetake")
        return SpeakerProfileStore(url: directory.appendingPathComponent("speakers.json"))
    }

    /// ファイルが無い、またはJSONとして壊れている場合は空配列を返す
    func load() -> [SpeakerProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SpeakerProfile].self, from: data)) ?? []
    }

    /// JSON（sortedKeys、prettyPrinted）でatomicに書き込む。ディレクトリが無ければ作成する
    func save(_ profiles: [SpeakerProfile]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(profiles)
        try data.write(to: url, options: .atomic)
    }
}
