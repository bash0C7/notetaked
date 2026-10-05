import Foundation

/// 読み手が書きかけの内容を見ないよう、同じディレクトリの一時ファイルへ書いてからrenameで置き換える。
/// 置き換えに失敗した時は一時ファイルを消すため、ディレクトリに一時ファイルが残らない
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL)
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// 状態ファイル（JSON）の読み書き。書き込みは`AtomicFile`を通す
public enum JSONFile {
    public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(value), to: url)
    }

    /// ファイルが無ければnil。中身を解釈できなければthrowする
    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
