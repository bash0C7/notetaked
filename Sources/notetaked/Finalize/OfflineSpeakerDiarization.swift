import FluidAudio
import Foundation
import NotetakeCore

/// 生音声の全体に対するオフライン話者分離。話者ごとの区間と、`speakerDatabase`のcentroidを返す
enum OfflineSpeakerDiarization {
    struct Output {
        var turns: [SpeakerTurn]
        /// 話者id（`S1`）ごとの声の特徴
        var centroids: [String: [Float]]
    }

    /// - `speakers`は話者の人数の目標で、必ずその人数になるとは限らない（`clustering.numSpeakers`）
    /// - 話者のmodelは初回だけ取得する。取得できなければthrowする
    /// - 音声に発話が無ければ（`noSpeechDetected`）、区間の無い結果を返す
    static func run(
        source: MappedPCMSampleSource, speakers: Int?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Output {
        var config = OfflineDiarizerConfig.default
        if let speakers {
            config.clustering.numSpeakers = speakers
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        do {
            let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0) { processed, total in
                progress(Double(processed) / Double(max(1, total)))
            }
            let turns = result.segments.map { segment in
                SpeakerTurn(
                    speaker: segment.speakerId, startMS: Int64((Double(segment.startTimeSeconds) * 1000).rounded()),
                    endMS: Int64((Double(segment.endTimeSeconds) * 1000).rounded()))
            }
            return Output(turns: turns, centroids: result.speakerDatabase ?? [:])
        } catch OfflineDiarizationError.noSpeechDetected {
            return Output(turns: [], centroids: [:])
        }
    }
}
