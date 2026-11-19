import Foundation

public struct ErrorEntry: Equatable, Sendable {
    public var key: String
    public var summary: String
    /// 要約と同じ文言ならnil
    public var detail: String?
    public var sinceMS: Int64
    /// 一時表示だけが持つ
    public var expiresAtMS: Int64?
}

/// 原因ごとのkeyで持つエラーの集まり。同じkeyは1件にまとめ、原因が治った時にkeyで消す
public struct ErrorBook: Equatable, Sendable {
    public static let transientMS: Int64 = 10_000

    private var entries: [ErrorEntry] = []
    private var transientCount = 0

    public init() {}

    /// 同じkeyなら文言だけ更新し、最初に出た時刻は保つ。何分続いているかを見せるため
    public mutating func set(key: String, message: String, nowMS: Int64) {
        let summary = ErrorText.summary(message)
        let detail = message == summary ? nil : message
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].summary = summary
            entries[index].detail = detail
            entries[index].expiresAtMS = nil
        } else {
            entries.append(ErrorEntry(key: key, summary: summary, detail: detail, sinceMS: nowMS, expiresAtMS: nil))
        }
    }

    /// 治る条件を持たないエラー。同じ文言でも別の出来事なので、連番のkeyで別々に持つ
    public mutating func addTransient(message: String, nowMS: Int64) {
        transientCount += 1
        let summary = ErrorText.summary(message)
        entries.append(
            ErrorEntry(
                key: "transient.\(transientCount)", summary: summary,
                detail: message == summary ? nil : message, sinceMS: nowMS,
                expiresAtMS: nowMS + Self.transientMS))
    }

    public mutating func resolve(key: String) {
        entries.removeAll { $0.key == key }
    }

    public mutating func resolveAll(withPrefix prefix: String) {
        entries.removeAll { $0.key.hasPrefix(prefix) }
    }

    public mutating func prune(nowMS: Int64) {
        entries.removeAll { entry in entry.expiresAtMS.map { $0 <= nowMS } ?? false }
    }

    /// 期限内のものだけ、出た時刻の昇順（同時刻はkey順で並びを安定させる）。pruneを待たずに期限切れを隠す
    public func active(nowMS: Int64) -> [ErrorEntry] {
        entries
            .filter { entry in entry.expiresAtMS.map { $0 > nowMS } ?? true }
            .sorted { ($0.sinceMS, $0.key) < ($1.sinceMS, $1.key) }
    }

    public var nextExpiryMS: Int64? {
        entries.compactMap(\.expiresAtMS).min()
    }
}

public enum ErrorText {
    /// Cocoaのエラーは`Error Domain=`以降が長く画面に収まらないので切る。原因が分かるものは一言添える
    public static func summary(_ message: String) -> String {
        guard let range = message.range(of: ": Error Domain=") else { return message }
        var text = String(message[..<range.lowerBound])
        if message.contains("No space left on device") || message.contains("Code=640") {
            text += "（ディスクの空きがありません）"
        }
        return text
    }
}
