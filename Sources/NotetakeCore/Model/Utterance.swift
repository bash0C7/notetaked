import Foundation

/// Reconcilerが生成する統合済み発話。同一の発話に属する複数device由来segを1件へまとめたもの。
public struct Utterance: Sendable, Equatable, Identifiable {
    public var id: UUID            // 最初に受け取ったsegのid（安定）
    public var start: Int64        // 正規化後 epoch ms
    public var end: Int64
    public var speakerID: String?  // 大域話者id
    public var speaker: String     // 表示ラベル
    public var text: String        // 採用本文
    public var confidence: Double?
    public var source: Source      // 採用本文のsource
    public var ownerLabel: String  // 採用本文segのowner
    public var sources: [UUID]     // 統合したseg id（受信順）
    public var devices: [String]   // 統合したdevice id
}
