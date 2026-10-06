import Foundation

/// `notetaked finalize`がstderrへ書く進捗の1行。serveが読み、メニューの進捗と、進捗が途絶えたかの判断に使う
public struct FinalizeProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case transcribe
        case diarize
    }

    public var source: Source
    public var stage: Stage
    /// 0...100
    public var percent: Int

    public init(source: Source, stage: Stage, percent: Int) {
        self.source = source
        self.stage = stage
        self.percent = min(100, max(0, percent))
    }

    public var line: String { "finalize-progress \(source.rawValue) \(stage.rawValue) \(percent)" }

    /// メニューに出す進捗の文
    public var detail: String {
        let stageName =
            switch stage {
            case .transcribe: "文字起こし"
            case .diarize: "話者分離"
            }
        return "\(source.rawValue) \(stageName) \(percent)%"
    }

    /// 進捗の行でなければnil
    public static func parse(_ line: String) -> FinalizeProgress? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "finalize-progress",
            let source = Source(rawValue: String(parts[1])), let stage = Stage(rawValue: String(parts[2])),
            let percent = Int(parts[3])
        else { return nil }
        return FinalizeProgress(source: source, stage: stage, percent: percent)
    }
}

/// 進捗の割合が上がった時だけ行を出す。1%未満の刻みの呼び出しで、stderrを埋めない
public struct FinalizeProgressThrottle: Sendable {
    private var last = -1

    public init() {}

    /// `fraction`は0...1。前回出した割合より上がっていれば、出す割合を返す
    public mutating func percent(forFraction fraction: Double) -> Int? {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        guard percent > last else { return nil }
        last = percent
        return percent
    }
}
