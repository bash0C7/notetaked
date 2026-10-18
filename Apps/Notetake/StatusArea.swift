import NotetakeCore
import SwiftUI

/// ライブパネルの下部に常時出すステータス領域。
/// 音量グラフ・判定の文言・iPhoneの受信状況は、すべてAppModelが持つ実データから作る。
struct StatusArea: View {
    let appModel: AppModel
    let statusText: String

    private static let graphWindowMS: Int64 = 90_000

    init(appModel: AppModel, statusText: String) {
        self.appModel = appModel
        self.statusText = statusText
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            content(nowMS: Int64((context.date.timeIntervalSince1970 * 1000).rounded()))
        }
    }

    private func content(nowMS: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let daemon = appModel.daemonIndicator(nowMS: nowMS) {
                DaemonBannerRow(message: daemon)
            }
            SourceLevelRow(
                label: "mic",
                history: appModel.micHistory,
                message: appModel.indicator(for: .mic, nowMS: nowMS),
                secondsSinceText: secondsSinceText(for: .mic, nowMS: nowMS),
                idleNote: appModel.isRecording ? nil : appModel.micLevelMonitor.unavailableReason,
                isRecording: appModel.isRecording,
                nowMS: nowMS,
                windowMS: Self.graphWindowMS)
            if appModel.isRecording {
                SourceLevelRow(
                    label: "system",
                    history: appModel.systemHistory,
                    message: appModel.indicator(for: .system, nowMS: nowMS),
                    secondsSinceText: secondsSinceText(for: .system, nowMS: nowMS),
                    idleNote: nil,
                    isRecording: true,
                    nowMS: nowMS,
                    windowMS: Self.graphWindowMS)
            } else {
                SystemStoppedRow()
            }
            PeerRow(
                connectedNames: appModel.connectedPeerNames,
                lastSeg: newestPeerSeg(),
                message: appModel.peerIndicator,
                nowMS: nowMS)
            FooterRow(statusText: statusText, clamshellClosed: appModel.clamshellClosed)
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 指定sourceの最新の確定文字からの経過秒。確定文字が無ければnil
    private func secondsSinceText(for source: Source, nowMS: Int64) -> Int? {
        guard let lastEnd = appModel.lastTextAtMS(for: source) else { return nil }
        return max(0, Int((nowMS - lastEnd) / 1000))
    }

    /// 受信時刻が最も新しいiPhone等のseg情報
    private func newestPeerSeg() -> AppModel.PeerSegInfo? {
        appModel.lastPeerSeg.values.max { $0.receivedAt < $1.receivedAt }
    }
}

/// daemonの更新が止まった時の赤い帯
private struct DaemonBannerRow: View {
    let message: IndicatorMessage

    var body: some View {
        Text(message.text)
            .fontWeight(.semibold)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// micまたはsystemの1行。グラフ・今の値・文字からの秒数・判定の文言
private struct SourceLevelRow: View {
    let label: String
    let history: LevelHistory
    let message: IndicatorMessage
    let secondsSinceText: Int?
    let idleNote: String?
    let isRecording: Bool
    let nowMS: Int64
    let windowMS: Int64

    private var valueText: String {
        guard let dbfs = history.latest(nowMS: nowMS)?.dbfs else { return "—" }
        return String(format: "%.0f dB", dbfs)
    }

    private var sinceText: String {
        guard let seconds = secondsSinceText else { return "文字: —" }
        return "文字: \(seconds)秒前"
    }

    /// 判定の文言が空なら、停止中のモニターが使えない理由を出す
    private var noteText: String {
        if !message.text.isEmpty { return message.text }
        return idleNote ?? ""
    }

    private var noteColor: Color {
        message.text.isEmpty ? Color.secondary : message.severity.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                LevelGraph(samples: history.samples, windowMS: windowMS, nowMS: nowMS, height: 28)
                Text(valueText)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                if isRecording {
                    Text(sinceText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                }
            }
            Text(noteText)
                .foregroundStyle(noteColor)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
                .padding(.leading, 56)
        }
    }
}

/// 停止中のsystem行。グラフは出さない
private struct SystemStoppedRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("system")
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text("停止中（収録中のみ表示します）")
                .foregroundStyle(.secondary)
        }
    }
}

/// iPhoneの接続と最終受信の行
private struct PeerRow: View {
    let connectedNames: [String]
    let lastSeg: AppModel.PeerSegInfo?
    let message: IndicatorMessage?
    let nowMS: Int64

    private var connectionText: String {
        connectedNames.isEmpty ? "未接続" : connectedNames.joined(separator: "/")
    }

    private var lastSegText: String {
        guard let seg = lastSeg else { return "最終受信 —" }
        let seconds: Int = max(0, Int((nowMS - seg.receivedAt) / 1000))
        return "最終受信 \(seconds)秒前"
    }

    /// 取り込み先。診断の要なので、第1行から外して省略されない専用の行に出す
    private var outcomeLine: String {
        guard let seg = lastSeg else { return "" }
        return Self.outcomeText(seg.outcome)
    }

    private static func outcomeText(_ outcome: PeerSegOutcome) -> String {
        switch outcome {
        case .current: return "今の収録に入りました"
        case .other: return "別の収録に追記しました"
        case .orphan: return "どの収録にも入らず orphans.jsonl へ"
        case .peerRecording: return "端末の収録に入りました"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("iPhone")
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text(connectionText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(lastSegText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(outcomeLine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
                .padding(.leading, 56)
            Text(message?.text ?? "")
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
                .padding(.leading, 56)
        }
    }
}

/// 最下行。収録の状態文字列と蓋の状態
private struct FooterRow: View {
    let statusText: String
    let clamshellClosed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if clamshellClosed {
                Text("蓋: 閉")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
