import Foundation

/// Diarizerが返す、絶対時刻（epoch ms）付きの話者turn。
/// localIDはstream内（mic/systemそれぞれ）でのみ意味を持つ一時的なid。
public struct SpeakerTurn: Sendable, Equatable {
    public var localID: String
    public var startMS: Int64
    public var endMS: Int64
    public var embedding: [Float]

    public init(localID: String, startMS: Int64, endMS: Int64, embedding: [Float]) {
        self.localID = localID
        self.startMS = startMS
        self.endMS = endMS
        self.embedding = embedding
    }
}
