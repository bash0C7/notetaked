import Foundation

/// device単位で受信済みseg`seq`の冪等判定に使うcursorの永続化。
/// `~/Library/Application Support/Notetake/received/<device>.cursor`に受信済み最大seqを
/// 10進文字列で保存する（`DeviceIdentity` / `SpeakerProfileStore`と同じディレクトリ規則）。
/// deviceごとに1ファイルなので、呼び出し側（ServeSession）は`[String: Int]`のin-memory mirrorを
/// 持ち、初回だけ`load(device:)`でここから復元する
struct ReceivedCursor {
    let directory: URL

    static func `default`() -> ReceivedCursor {
        let supportDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return ReceivedCursor(
            directory: supportDirectory.appendingPathComponent("Notetake/received"))
    }

    private func url(forDevice device: String) -> URL {
        directory.appendingPathComponent("\(device).cursor")
    }

    /// ファイルが無い、または壊れていれば0（=未受信）
    func load(device: String) -> Int {
        guard
            let text = try? String(contentsOf: url(forDevice: device), encoding: .utf8)
        else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// atomicに書き込む。ディレクトリが無ければ作成する
    func save(device: String, seq: Int) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try String(seq).write(to: url(forDevice: device), atomically: true, encoding: .utf8)
    }
}
