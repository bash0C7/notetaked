import NotetakeCore
import SwiftUI

/// 直近の音量を細い縦棒で並べるグラフ。MacとiPhoneで共有する
/// 通常は棒、完全な無音は最下段の赤い印、欠測は灰色の点で描き分ける
struct LevelGraph: View {
    let samples: [LevelSample]
    let windowMS: Int64
    let nowMS: Int64
    var height: CGFloat = 36

    private let barWidth: CGFloat = 2
    private let markHeight: CGFloat = 3
    private let gapDiameter: CGFloat = 3

    init(samples: [LevelSample], windowMS: Int64, nowMS: Int64, height: CGFloat = 36) {
        self.samples = samples
        self.windowMS = windowMS
        self.nowMS = nowMS
        self.height = height
    }

    var body: some View {
        Canvas { context, size in
            guard windowMS > 0 else { return }
            let startMS = nowMS - windowMS
            for sample in samples {
                let ratio = Double(sample.atMS - startMS) / Double(windowMS)
                guard ratio >= 0, ratio <= 1 else { continue }
                let centerX = CGFloat(ratio) * size.width
                let originX = centerX - barWidth / 2

                guard let dbfs = sample.dbfs else {
                    let dot = CGRect(x: centerX - gapDiameter / 2, y: size.height - gapDiameter,
                                     width: gapDiameter, height: gapDiameter)
                    context.fill(Path(ellipseIn: dot), with: .color(.gray))
                    continue
                }
                if LevelScale.isSilent(dbfs: dbfs) {
                    let mark = CGRect(x: originX, y: size.height - markHeight,
                                      width: barWidth, height: markHeight)
                    context.fill(Path(mark), with: .color(.red))
                    continue
                }
                let barHeight = max(CGFloat(LevelScale.normalized(dbfs: dbfs)) * size.height, 1)
                let bar = CGRect(x: originX, y: size.height - barHeight,
                                 width: barWidth, height: barHeight)
                context.fill(Path(bar), with: .color(.primary))
            }
        }
        .frame(height: height)
    }
}

private let previewWindowMS: Int64 = 90_000
private let previewNowMS: Int64 = 100_000
private let previewStepMS: Int64 = 500

/// previewの時刻を古い順に並べる
private func previewTimes() -> [Int64] {
    var times: [Int64] = []
    var atMS: Int64 = previewNowMS - previewWindowMS
    while atMS <= previewNowMS {
        times.append(atMS)
        atMS += previewStepMS
    }
    return times
}

/// 音量が上下する値
private func previewMoving() -> [LevelSample] {
    var samples: [LevelSample] = []
    for (index, atMS) in previewTimes().enumerated() {
        let phase: Double = Double(index) / 5.0
        let wave: Double = sin(phase)
        let dbfs: Double = -60.0 + 40.0 * wave
        samples.append(LevelSample(atMS: atMS, dbfs: dbfs))
    }
    return samples
}

/// 途中から完全な無音（-120）が続く値
private func previewSilent() -> [LevelSample] {
    var samples: [LevelSample] = []
    for (index, atMS) in previewTimes().enumerated() {
        let dbfs: Double = index < 100 ? -30.0 : -120.0
        samples.append(LevelSample(atMS: atMS, dbfs: dbfs))
    }
    return samples
}

/// 途中に欠測が混ざる値
private func previewWithGaps() -> [LevelSample] {
    var samples: [LevelSample] = []
    for (index, atMS) in previewTimes().enumerated() {
        let dbfs: Double? = (index >= 60 && index < 120) ? nil : -40.0
        samples.append(LevelSample(atMS: atMS, dbfs: dbfs))
    }
    return samples
}

#Preview("音量グラフ") {
    VStack(alignment: .leading, spacing: 12) {
        LevelGraph(samples: previewMoving(), windowMS: previewWindowMS, nowMS: previewNowMS)
        LevelGraph(samples: previewSilent(), windowMS: previewWindowMS, nowMS: previewNowMS)
        LevelGraph(samples: previewWithGaps(), windowMS: previewWindowMS, nowMS: previewNowMS)
    }
    .padding()
    .frame(width: 360)
}
