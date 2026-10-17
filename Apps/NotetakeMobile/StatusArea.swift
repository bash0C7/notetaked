import NotetakeCore
import SwiftUI

/// 状態セクションの中身。音量グラフ・判定の文言・Macとの接続・未送信の件数を出す。
/// 値はすべてMobileModelが持つ実データから作る。停止中は前の値を残さず、取り込み中でない旨だけを出す。
struct StatusArea: View {
    let model: MobileModel

    private static let graphWindowMS: Int64 = 90_000

    init(model: MobileModel) {
        self.model = model
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            content(nowMS: Int64((context.date.timeIntervalSince1970 * 1000).rounded()))
        }
    }

    private func content(nowMS: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRecording {
                levelRow(nowMS: nowMS)
            } else {
                Text("取り込み中ではありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            infoRow(title: "Mac", value: peerStatusText)
            if let peer = model.peerIndicator {
                Text(peer.text)
                    .font(.footnote)
                    .foregroundStyle(peer.severity.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            infoRow(title: "未送信", value: "\(model.pendingCount)件")
        }
    }

    /// 音量グラフ・今の値・文字からの秒数・判定の文言
    private func levelRow(nowMS: Int64) -> some View {
        let message = model.indicator(nowMS: nowMS)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LevelGraph(samples: model.levelHistory.samples, windowMS: Self.graphWindowMS, nowMS: nowMS, height: 28)
                Text(valueText(nowMS: nowMS))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(sinceText(nowMS: nowMS))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(message.severity.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func valueText(nowMS: Int64) -> String {
        guard let dbfs = model.levelHistory.latest(nowMS: nowMS)?.dbfs else { return "—" }
        return String(format: "%.0f dB", dbfs)
    }

    private func sinceText(nowMS: Int64) -> String {
        guard let lastTextAtMS = model.lastTextAtMS else { return "文字: —" }
        let seconds: Int = max(0, Int((nowMS - lastTextAtMS) / 1000))
        return "文字: \(seconds)秒前"
    }

    /// 左に項目名、右に値。狭い画面では値を折り返して切らさない
    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var peerStatusText: String {
        switch model.peerState {
        case .idle: return "未接続"
        case .browsing: return "検索中…"
        case .connecting(let name): return "接続試行中: \(name)"
        case .connected(let name): return "接続済み: \(name)"
        case .failed(let reason): return "エラー: \(reason)"
        }
    }
}

private extension IndicatorSeverity {
    /// 赤はalertだけ。info・normalは目立たせない
    var color: Color {
        switch self {
        case .alert: return Color.red
        case .caution: return Color.orange
        case .info, .normal: return Color.secondary
        }
    }
}
