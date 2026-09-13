import FluidAudio
import Foundation
import NotetakeCore

/// FluidAudio（`DiarizerManager`）をラップし、16kHz mono の音声を
/// chunk（既定10秒）ごとに`performCompleteDiarization`へ渡して話者turnを返すactor。
///
/// `DiarizerManager`は非Sendableなclassだが、このactorだけが所有し、
/// actor隔離のもとでしか触れないため安全に保持できる。
@available(macOS 14, iOS 17, *)
public actor Diarizer {
    private static let sampleRate = 16000

    /// `feed`/`flush`の1回の呼び出しで新たに得られた話者turnと、
    /// そこまでに分離済みの音声の絶対時刻（epoch ms、streamのoriginMS基準）。
    public struct Output: Sendable {
        public var turns: [SpeakerTurn]
        public var coveredUntilMS: Int64

        public init(turns: [SpeakerTurn], coveredUntilMS: Int64) {
            self.turns = turns
            self.coveredUntilMS = coveredUntilMS
        }
    }

    private let manager: DiarizerManager
    private let originMS: Int64
    private let chunkSize: Int
    private var buffer: [Float] = []
    private var processedSamples: Int = 0

    /// FluidAudioの話者分離モデルを取得する（初回はHugging Faceからダウンロード、
    /// 既定の保存先 `~/Library/Application Support/FluidAudio/Models/…` に無ければ
    /// 取得し、以降はローカルキャッシュを使う）。`progress`には0...1の完了割合が渡る。
    public static func prepareModels(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizerModels {
        try await DiarizerModels.downloadIfNeeded(progressHandler: { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        })
    }

    /// - Parameters:
    ///   - models: `prepareModels(progress:)`で取得済みのモデル
    ///   - originMS: このstream（mic/system）の収録開始時刻（epoch ms）。
    ///     turnの絶対時刻はこれに音声内の経過秒数を足して求める
    ///   - chunkSeconds: 分離を実行する単位（秒）。FluidAudio側の`chunkDuration`にもそのまま渡す
    ///   - clusteringThreshold: 話者クラスタリングの閾値（`DiarizerConfig.clusteringThreshold`）
    public init(
        models: DiarizerModels,
        originMS: Int64,
        chunkSeconds: Double = 10,
        clusteringThreshold: Float = 0.7
    ) {
        let manager = DiarizerManager(
            config: DiarizerConfig(
                clusteringThreshold: clusteringThreshold,
                chunkDuration: Float(chunkSeconds)
            )
        )
        manager.initialize(models: models)
        self.manager = manager
        self.originMS = originMS
        self.chunkSize = Int((chunkSeconds * Double(Self.sampleRate)).rounded())
    }

    /// 16kHz monoの音声を追加する。chunk分（既定10秒＝16000*10サンプル）溜まるごとに
    /// `performCompleteDiarization`を実行し、その回のfeed呼び出しで新たに得られた
    /// 話者turnをまとめて返す。1chunk分も溜まっていなければnil。
    public func feed(_ samples: [Float]) throws -> Output? {
        buffer.append(contentsOf: samples)

        var turns: [SpeakerTurn] = []
        var didProcess = false
        while buffer.count >= chunkSize {
            let chunk = Array(buffer.prefix(chunkSize))
            buffer.removeFirst(chunkSize)
            turns.append(contentsOf: try process(chunk))
            didProcess = true
        }

        guard didProcess else { return nil }
        return Output(turns: turns, coveredUntilMS: coveredUntilMS)
    }

    /// 停止時に残っているbufferを処理する。FluidAudioはchunkより短い音声も
    /// 内部でパディングして処理できるが、1秒（16000サンプル）未満では
    /// 有意な分離結果が得られないため処理せずnilを返す。
    public func flush() throws -> Output? {
        guard buffer.count >= Self.sampleRate else { return nil }
        let chunk = buffer
        buffer.removeAll()
        let turns = try process(chunk)
        return Output(turns: turns, coveredUntilMS: coveredUntilMS)
    }

    private func process(_ chunk: [Float]) throws -> [SpeakerTurn] {
        let atTime = Double(processedSamples) / Double(Self.sampleRate)
        let result = try manager.performCompleteDiarization(
            chunk, sampleRate: Self.sampleRate, atTime: atTime)
        processedSamples += chunk.count
        return result.segments.map { segment in
            SpeakerTurn(
                localID: segment.speakerId,
                startMS: originMS + Int64((Double(segment.startTimeSeconds) * 1000).rounded()),
                endMS: originMS + Int64((Double(segment.endTimeSeconds) * 1000).rounded()),
                embedding: segment.embedding
            )
        }
    }

    private var coveredUntilMS: Int64 {
        originMS + Int64((Double(processedSamples) / Double(Self.sampleRate) * 1000).rounded())
    }
}
