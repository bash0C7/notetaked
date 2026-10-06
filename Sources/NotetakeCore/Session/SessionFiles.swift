import Foundation

/// 出力ディレクトリの、収録ごとのファイルの場所
public enum SessionFiles {
    public static func timedURL(prefix: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(prefix).timed.jsonl")
    }

    public static func finalURL(prefix: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(prefix).final.md")
    }
}
