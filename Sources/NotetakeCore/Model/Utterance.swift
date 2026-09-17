import Foundation

/// Reconcilerが生成する統合済み発話。同一の発話に属する複数device由来segを1件へまとめたもの。
public struct Utterance: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID            // 最初に受け取ったsegのid（安定）
    public var start: Int64        // 正規化後 epoch ms
    public var end: Int64
    public var speakerID: String?  // 大域話者id
    public var speaker: String     // 表示ラベル
    public var text: String        // 採用本文
    public var confidence: Double?
    public var source: Source      // 採用本文のsource
    public var platform: Platform  // 採用本文segのplatform
    public var ownerLabel: String  // 採用本文segのowner
    public var input: String       // 採用本文segのinput.name
    public var sources: [UUID]     // 統合したseg id（受信順）
    public var devices: [String]   // 統合したdevice id
    public var direction: Direction?  // 統合したsegのうちconfidence最大のdirection

    // 場所ラベル(LocationLabel)専用: 本文の勝者(input/platform/source/direction)とは別に、
    // 統合したsegのうちlevel_dbfsが最大のもの(話者に最も近いマイク)を追跡する（issue #6）
    public var locationInput: String
    public var locationPlatform: Platform
    public var locationSource: Source
    public var locationDirection: Direction?
    public var locationLevelDBFS: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case speakerID = "speaker_id"
        case speaker
        case text
        case confidence
        case source
        case platform
        case ownerLabel = "owner_label"
        case input
        case sources
        case devices
        case direction
        case locationInput = "location_input"
        case locationPlatform = "location_platform"
        case locationSource = "location_source"
        case locationDirection = "location_direction"
        case locationLevelDBFS = "location_level_dbfs"
    }
}
