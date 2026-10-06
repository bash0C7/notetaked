import Foundation

/// SpeechのAttributedString.runsから作る、run単位の時間範囲付きテキスト片。
/// Speechフレームワークに依存しないため、Speechが使えないplatformでも
/// 話者の割り当てなどの純粋な処理がこの型を使える。
public struct TranscriptRun: Sendable, Equatable {
    public var text: String
    public var startMS: Int64
    public var endMS: Int64

    public init(text: String, startMS: Int64, endMS: Int64) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
    }
}
