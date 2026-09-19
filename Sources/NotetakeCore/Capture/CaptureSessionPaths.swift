import Foundation

public enum CaptureSessionPaths {
    public static func sessionDirectory(
        prefix: String,
        baseTemporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) -> URL {
        baseTemporaryDirectory.appendingPathComponent("notetake-capture").appendingPathComponent(prefix)
    }

    public static func rawFileURL(sessionDirectory: URL, source: String) -> URL {
        sessionDirectory.appendingPathComponent("\(source).raw")
    }

    public static func checkpointFileURL(sessionDirectory: URL, source: String) -> URL {
        sessionDirectory.appendingPathComponent("\(source).checkpoint")
    }
}
