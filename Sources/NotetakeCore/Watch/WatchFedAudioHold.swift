import Foundation

/// streamへfeedした小片の音声を、そのstreamを閉じて末尾が確定するまで受け取り箱に残すための記録。
/// feedの直後に消すと、suspendの間にappが落とされた時に、analyzerの中で未確定の末尾の文字が音声ごと失われる。
/// 台帳の処理済みはfeedの時点で記録する（streamを作り直す起点と二重のfeed防止に使う）ので、
/// 残った音声は次の回収で「処理済み」として片付き、二重には流れない
public struct WatchFedAudioHold: Sendable, Equatable {
    private var held: [String: [String]] = [:]

    public init() {}

    public var heldCount: Int { held.values.reduce(0) { $0 + $1.count } }

    public mutating func hold(session: String, id: String) {
        var ids = held[session] ?? []
        if !ids.contains(id) { ids.append(id) }
        held[session] = ids
    }

    /// streamを閉じ終えた時に消してよいid。閉じるのに失敗した時は消さず、残したまま次に閉じる時へ持ち越す
    public mutating func release(session: String, finishSucceeded: Bool) -> [String] {
        guard finishSucceeded, let ids = held.removeValue(forKey: session) else { return [] }
        return ids
    }
}
