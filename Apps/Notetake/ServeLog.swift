import Foundation

/// serveの起動・終了・stderrを`~/Library/Logs/Notetake/serve.log`へ残す。
/// serveが落ちた理由は、落ちた後のappからは標準エラーに流しただけでは辿れないため、ファイルに残す。
enum ServeLog {
    private static let maxBytes = 1_000_000
    /// 複数のclientとstderrのreadabilityHandlerから同時に呼ばれるため、ファイル操作を直列にする
    private static let queue = DispatchQueue(label: "notetake.serve-log")

    private static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Notetake", isDirectory: true)
    }
    private static var logURL: URL { directoryURL.appendingPathComponent("serve.log") }
    private static var rotatedURL: URL { directoryURL.appendingPathComponent("serve.log.1") }

    static func write(_ line: String) {
        let stamp = timestampFormatter.string(from: Date())
        queue.async {
            append("\(stamp) \(line)\n")
        }
    }

    /// stderrの塊を行に分けて書く（空行は捨てる）
    static func writeStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            write("stderr: \(line)")
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// queue上でだけ呼ぶ。失敗しても収録は止めず、標準エラーに1行出す
    private static func append(_ text: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if let size = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > maxBytes {
                try? fileManager.removeItem(at: rotatedURL)
                try fileManager.moveItem(at: logURL, to: rotatedURL)
            }
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            FileHandle.standardError.write(Data("ServeLog: failed to write: \(error)\n".utf8))
        }
    }
}
