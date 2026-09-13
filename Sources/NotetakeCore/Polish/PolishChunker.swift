import Foundation

/// 話者turn（連続する同一話者のutteranceを1つにまとめたもの）
public struct PolishTurn: Codable, Sendable, Equatable {
    public var speaker: String
    public var text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// 1回のFoundation Models呼び出しに渡す単位。contextは直前chunk末尾のturn（文脈用、出力対象外）
public struct PolishChunk: Sendable, Equatable {
    public var context: [PolishTurn]
    public var body: [PolishTurn]

    public init(context: [PolishTurn], body: [PolishTurn]) {
        self.context = context
        self.body = body
    }
}

/// 整形結果1 turn。polishedがfalseなら原文採用
public struct PolishedTurn: Codable, Sendable, Equatable {
    public var speaker: String
    public var text: String
    public var polished: Bool

    public init(speaker: String, text: String, polished: Bool) {
        self.speaker = speaker
        self.text = text
        self.polished = polished
    }
}

public enum PolishChunker {
    public static let defaultMaxCharacters = 2000   // 日本語で約1500 token相当
    public static let defaultContextTurns = 2

    /// utterance（start順）→ 連続する同一speakerを1 turnへ（textは""で連結）。空textは飛ばす
    public static func turns(from utterances: [Utterance]) -> [PolishTurn] {
        var result: [PolishTurn] = []
        for utterance in utterances where !utterance.text.isEmpty {
            if let last = result.last, last.speaker == utterance.speaker {
                result[result.count - 1].text += utterance.text
            } else {
                result.append(PolishTurn(speaker: utterance.speaker, text: utterance.text))
            }
        }
        return result
    }

    /// bodyの文字数合計が maxCharacters を超えないよう分割（1 turnが単独で超える場合はその turn だけの chunk）。各chunkのcontextは直前chunkのbody末尾 contextTurns 件（先頭chunkは[]）
    public static func chunks(
        _ turns: [PolishTurn],
        maxCharacters: Int = defaultMaxCharacters,
        contextTurns: Int = defaultContextTurns
    ) -> [PolishChunk] {
        var result: [PolishChunk] = []
        var currentBody: [PolishTurn] = []
        var currentLength = 0

        func flush() {
            guard !currentBody.isEmpty else { return }
            let context = result.last.map { Array($0.body.suffix(contextTurns)) } ?? []
            result.append(PolishChunk(context: context, body: currentBody))
            currentBody = []
            currentLength = 0
        }

        for turn in turns {
            let length = turn.text.count
            if !currentBody.isEmpty && currentLength + length > maxCharacters {
                flush()
            }
            currentBody.append(turn)
            currentLength += length
        }
        flush()

        return result
    }

    /// chunkごとの整形出力（失敗はnil）をbodyと突き合わせる: 出力が空でなければ件数一致・不一致とも出力のspeaker/textをそのまま polished true で採用。nil（失敗）はbodyを polished false で採用
    public static func merge(
        outputs: [[(speaker: String, text: String)]?],
        chunks: [PolishChunk]
    ) -> [PolishedTurn] {
        var result: [PolishedTurn] = []
        for (output, chunk) in zip(outputs, chunks) {
            guard let output, !output.isEmpty else {
                result.append(contentsOf: chunk.body.map {
                    PolishedTurn(speaker: $0.speaker, text: $0.text, polished: false)
                })
                continue
            }
            if output.count == chunk.body.count {
                for item in output {
                    result.append(PolishedTurn(speaker: item.speaker, text: item.text, polished: true))
                }
            } else {
                result.append(contentsOf: output.map {
                    PolishedTurn(speaker: $0.speaker, text: $0.text, polished: true)
                })
            }
        }
        return result
    }
}
