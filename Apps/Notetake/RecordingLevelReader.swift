import Foundation
import NotetakeCore
import Observation

/// 背景のTaskからも読むので、main actorのclassの外に置く
private let recordingLevelTickMS: Int64 = 100
/// 新しいsampleがこの期間増えなければ、測れなかった区間として扱う
private let recordingLevelGapAfterMS: Int64 = 300

/// 収録中の音量を、capture-daemonが追記する生音声ファイルの末尾から作る。
/// 読み込みと100ms周期は背景のTaskで行い、`histories`の更新だけをmain actorへ戻す
@MainActor
@Observable
final class RecordingLevelReader {
    /// 背景のTaskからmain actorへ渡す更新
    private enum Update: Sendable {
        case level(atMS: Int64, dbfs: Double)
        case gap(atMS: Int64)
    }

    private(set) var histories: [Source: LevelHistory]

    @ObservationIgnored private let prefix: String
    @ObservationIgnored private let sources: [Source]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(prefix: String, sources: [Source]) {
        self.prefix = prefix
        self.sources = sources
        histories = Dictionary(uniqueKeysWithValues: sources.map { ($0, LevelHistory()) })
    }

    func start() {
        guard task == nil else { return }
        let directory = CaptureSessionPaths.sessionDirectory(prefix: prefix)
        let targets = sources.map { ($0, CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: $0)) }
        // startはmain actorで呼ばれるので、現在の末尾だけここで決める。PCMTailReaderは背景のTaskだけが持つ
        let starts = targets.map { PCMTailReader.sampleCount(of: $0.1) }
        task = Task.detached(priority: .utility) { [weak self] in
            var trackers = zip(targets, starts).map { Tracker(source: $0.0, url: $0.1, startSample: $1) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(recordingLevelTickMS))
                if Task.isCancelled { break }
                let nowMS = Int64((Date().timeIntervalSince1970 * 1000).rounded())
                for index in trackers.indices {
                    let updates = trackers[index].tick(nowMS: nowMS)
                    guard !updates.isEmpty else { continue }
                    let source = trackers[index].source
                    await self?.apply(updates, to: source)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ updates: [Update], to source: Source) {
        guard var history = histories[source] else { return }
        for update in updates {
            switch update {
            case .level(let atMS, let dbfs): history.append(atMS: atMS, dbfs: dbfs)
            case .gap(let atMS): history.appendGap(atMS: atMS)
            }
        }
        histories[source] = history
    }

    /// 1つのsourceの読み進め。背景のTaskの中だけで使う
    private struct Tracker {
        let source: Source
        private let reader: PCMTailReader
        private var carry: [Float] = []
        private var lastGrowthMS: Int64?

        init(source: Source, url: URL, startSample: Int64) {
            self.source = source
            reader = PCMTailReader(url: url, startSample: startSample)
        }

        mutating func tick(nowMS: Int64) -> [Update] {
            let chunkSamples = Int(CapturePCM.samples(forMS: recordingLevelTickMS))
            let fresh = (try? reader.readNew()) ?? []
            if lastGrowthMS == nil { lastGrowthMS = nowMS }

            guard !fresh.isEmpty else {
                guard let lastGrowthMS, nowMS - lastGrowthMS >= recordingLevelGapAfterMS else { return [] }
                return [.gap(atMS: nowMS)]
            }
            lastGrowthMS = nowMS

            carry += fresh
            let series = LevelChunker.dbfsSeries(samples: carry, chunkSamples: chunkSamples)
            carry.removeFirst(series.count * chunkSamples)
            // 区切りは古い順。最後の区切りをいまの時刻に置き、前の区切りは100msずつ遡らせる
            return series.enumerated().map { offset, dbfs in
                .level(atMS: nowMS - Int64(series.count - 1 - offset) * recordingLevelTickMS, dbfs: dbfs)
            }
        }
    }
}
