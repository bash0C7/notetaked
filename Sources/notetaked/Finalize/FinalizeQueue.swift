import Foundation
import NotetakeCore

enum FinalizeQueueError: Error, CustomStringConvertible {
    case rawAudioMissing(String)
    case resultMismatch(expected: Int, actual: Int?)

    var description: String {
        switch self {
        case .rawAudioMissing(let prefix):
            return "\(prefix)の生音声が残っていません"
        case .resultMismatch(let expected, let actual):
            return "確定処理の結果の回が合いません（期待 \(expected)、結果 \(actual.map(String.init) ?? "なし")）"
        }
    }
}

/// 確定処理の順番待ちと、結果の取り込み。収録ごとに1本ずつ、`notetaked finalize`を子processとして走らせる。
/// 状態が変わるたびに`finalize_state` eventを、取り込みのたびに`finalized` eventを送る
actor FinalizeQueue {
    struct Job: Equatable, Sendable {
        var prefix: String
        /// 話者の人数の目標
        var speakers: Int?
    }

    struct Dependencies: Sendable {
        var archive: SessionArchive
        /// このMacのdevice id。確定済みの回を、このMacの`finalized`の記録で数える
        var deviceID: String
        /// 生音声の親ディレクトリ（`notetake-capture`の親）
        var rawBase: URL
        /// 子processを走らせ、stderrの行を`onLine`へ渡す。失敗はthrowする
        var runChild:
            @Sendable (
                _ sessionDirectory: URL, _ run: Int, _ speakers: Int?, _ onLine: @escaping @Sendable (String) -> Void
            ) async throws -> Void
        var readActual: @Sendable () -> CaptureActualState?
        var now: @Sendable () -> Date
        var sleep: @Sendable (TimeInterval) async throws -> Void
        var emit: @Sendable (Event) async -> Void
    }

    private let dependencies: Dependencies
    private var pending: [Job] = []
    private var running: Job?
    private var states: [String: FinalizeStateEvent] = [:]
    private var worker: Task<Void, Never>?
    private var lastProgressPercent: [String: Int] = [:]
    private var shuttingDown = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func state(of prefix: String) -> FinalizeStateEvent? {
        states[prefix]
    }

    // MARK: - 入口

    /// 順番待ちへ入れる。既に順番待ちか実行中なら何もしない
    func enqueue(_ job: Job) async {
        guard !shuttingDown else { return }
        guard running?.prefix != job.prefix, !pending.contains(where: { $0.prefix == job.prefix }) else { return }
        pending.append(job)
        await setState(FinalizeStateEvent(prefix: job.prefix, phase: .waiting))
        startWorker()
    }

    /// serveの停止。実行中の子processを止める
    func shutdown() async {
        shuttingDown = true
        pending = []
        worker?.cancel()
        await worker?.value
    }

    // MARK: - 実行

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !shuttingDown, !pending.isEmpty {
            if let index = pending.firstIndex(where: { isReady($0) }) {
                let job = pending.remove(at: index)
                running = job
                await process(job)
                running = nil
            } else {
                try? await dependencies.sleep(1)
            }
        }
        worker = nil
    }

    private func isReady(_ job: Job) -> Bool {
        FinalizeGate.canStart(
            prefix: job.prefix, actual: dependencies.readActual(), nowMS: Self.ms(dependencies.now()))
    }

    private func process(_ job: Job) async {
        await setState(FinalizeStateEvent(prefix: job.prefix, phase: .running))
        do {
            let info = try readInfo(prefix: job.prefix)
            let sessionDirectory = CaptureSessionPaths.sessionDirectory(
                prefix: job.prefix, baseTemporaryDirectory: dependencies.rawBase)
            let outputDirectory = URL(fileURLWithPath: info.outputDirectory)
            let records = try await dependencies.archive.readRecords(prefix: job.prefix, in: outputDirectory)
            let resultURL = CaptureSessionPaths.finalizeResultURL(sessionDirectory: sessionDirectory)

            let run = (FinalizedRuns.latestRun(in: records, device: info.device) ?? 0) + 1
            let prefix = job.prefix
            try await dependencies.runChild(sessionDirectory, run, job.speakers) { [weak self] line in
                Task { await self?.noteLine(line, prefix: prefix) }
            }
            let result = try JSONFile.read(FinalizeResult.self, from: resultURL)
            guard let result, result.run == run else {
                throw FinalizeQueueError.resultMismatch(expected: run, actual: result?.run)
            }
            let outcome = try await dependencies.archive.importFinalize(
                result: result, info: info, prefix: job.prefix, receivedAt: Self.ms(dependencies.now()))
            await report(outcome, prefix: job.prefix)
            await dependencies.emit(.finalized(outcome.event))
            await setState(FinalizeStateEvent(prefix: job.prefix, phase: .finalized, run: run))
        } catch {
            await fail(job, error: error)
        }
    }

    private func report(_ outcome: SessionArchive.ImportOutcome, prefix: String) async {
        for match in outcome.plan.matches {
            await dependencies.emit(
                .log(
                    "\(prefix): 名前を引き継ぎました \(match.current) ← 前回の\(match.previous)（類似度 \(Self.format(match.similarity))）"
                ))
        }
        for closest in outcome.plan.closest {
            await dependencies.emit(
                .log(
                    "\(prefix): 名前を引き継げません \(closest.current)に最も近い前回の\(closest.previous)は類似度 \(Self.format(closest.similarity))（閾値 \(Self.format(SpeakerMatcher.threshold))）"
                ))
        }
    }

    private func noteLine(_ line: String, prefix: String) async {
        guard let progress = FinalizeProgress.parse(line) else {
            // `finalize:`で始まる行（完了や警告）だけをlogへ流す。FluidAudioのdebug logは、進捗が続いている確認にだけ使う
            if line.hasPrefix("finalize:") {
                await dependencies.emit(.log("\(prefix): \(line)"))
            }
            return
        }
        // 進捗は5%刻みで伝える
        guard progress.percent % 5 == 0, lastProgressPercent[prefix] != progress.percent,
            states[prefix]?.phase == .running
        else { return }
        lastProgressPercent[prefix] = progress.percent
        await setState(FinalizeStateEvent(prefix: prefix, phase: .running, detail: progress.detail))
    }

    // MARK: - 失敗

    /// 失敗した収録は、暫定版の`final.md`が残る
    private func fail(_ job: Job, error: Error) async {
        guard !shuttingDown else { return }
        await dependencies.emit(.error("\(job.prefix): 確定処理に失敗しました: \(error)"))
        await setState(FinalizeStateEvent(prefix: job.prefix, phase: .gaveUp, detail: "\(error)"))
    }

    // MARK: - 補助

    private func readInfo(prefix: String) throws -> CaptureSessionInfo {
        let directory = CaptureSessionPaths.sessionDirectory(
            prefix: prefix, baseTemporaryDirectory: dependencies.rawBase)
        guard
            let info = try JSONFile.read(
                CaptureSessionInfo.self, from: CaptureSessionPaths.sessionInfoURL(sessionDirectory: directory))
        else {
            throw FinalizeQueueError.rawAudioMissing(prefix)
        }
        return info
    }

    private func setState(_ state: FinalizeStateEvent) async {
        states[state.prefix] = state
        if state.phase != .running {
            lastProgressPercent[state.prefix] = nil
        }
        await dependencies.emit(.finalizeState(state))
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
