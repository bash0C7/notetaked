#if canImport(FoundationModels)
import Foundation
import FoundationModels
import NotetakeCore

/// Foundation Modelsを使ってPolishChunk単位で文字起こしを整形する。
@available(macOS 26, *)
enum Polisher {
    @Generable
    struct PolishedTurnOutput {
        @Guide(description: "話者ラベル。入力のまま")
        var speaker: String
        @Guide(description: "整形後の本文")
        var text: String
    }

    @Generable
    struct PolishedChunkOutput {
        @Guide(description: "本文turnと同じ件数・同じ順")
        var turns: [PolishedTurnOutput]
    }

    private static let instructions = """
        会議の文字起こしを読みやすく整形する。認識誤りの修正、句読点の整形、言い淀み・繰り返しの除去。\
        意味は変えない、要約しない、話者ラベルは入力のまま。文脈turnは参考情報で出力しない。\
        本文turnと同じ件数・同じ順で返す。
        """

    /// SystemLanguageModelが利用できない場合、理由を文字列で返す（利用可能ならnil）
    static func availabilityError() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        }
    }

    /// 1 chunkをFoundation Modelsで整形する。失敗した場合はstderrに1行書いてnilを返す。
    static func polish(chunk: PolishChunk, index: Int) async -> [(speaker: String, text: String)]? {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = makePrompt(for: chunk)
        do {
            let response = try await session.respond(to: prompt, generating: PolishedChunkOutput.self)
            return response.content.turns.map { (speaker: $0.speaker, text: $0.text) }
        } catch let error as LanguageModelSession.GenerationError {
            reportFailure(index: index, error: error)
            return nil
        } catch {
            reportFailure(index: index, error: error)
            return nil
        }
    }

    private static func reportFailure(index: Int, error: Error) {
        FileHandle.standardError.write(Data("polish: chunk \(index) failed: \(error)\n".utf8))
    }

    private static func makePrompt(for chunk: PolishChunk) -> String {
        var lines: [String] = []
        if !chunk.context.isEmpty {
            lines.append("## 文脈（出力しない）")
            for turn in chunk.context {
                lines.append("\(turn.speaker): \(turn.text)")
            }
        }
        lines.append("## 本文")
        for (offset, turn) in chunk.body.enumerated() {
            lines.append("\(offset + 1). \(turn.speaker): \(turn.text)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
