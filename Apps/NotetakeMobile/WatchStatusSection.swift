import NotetakeCore
import SwiftUI

/// Watchの録音の状態。判定の色と文言、小片ごとの音量、最後の文字起こしと時刻、最終受信、電池、
/// 止まった理由、未処理件数、欠番の件数を出す。iPhoneのmic収録をしていない時も出す
struct WatchStatusSection: View {
    let model: MobileModel

    /// 小片ごとの音量グラフの窓（30分）
    private static let graphWindowMS: Int64 = 30 * 60 * 1000

    init(model: MobileModel) {
        self.model = model
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(nowMS: Int64((context.date.timeIntervalSince1970 * 1000).rounded()))
        }
    }

    @ViewBuilder
    private func content(nowMS: Int64) -> some View {
        if let snapshot = model.watchStatus {
            VStack(alignment: .leading, spacing: 8) {
                let message = WatchStatusJudge.judge(snapshot, nowMS: nowMS)
                Text(message.text.isEmpty ? stateText(snapshot) : message.text)
                    .font(.callout)
                    .foregroundStyle(message.severity.color)
                    .fixedSize(horizontal: false, vertical: true)
                LevelGraph(samples: levelSamples(snapshot), windowMS: Self.graphWindowMS, nowMS: nowMS, height: 28)
                infoRow(title: "最終受信", value: receivedText(snapshot, nowMS: nowMS))
                infoRow(title: "電池", value: batteryText(snapshot))
                infoRow(title: "未処理", value: "\(snapshot.inboxPendingCount)件")
                infoRow(title: "欠番", value: "\(snapshot.missingChunkCount)件")
                if let reason = snapshot.haltReason {
                    infoRow(title: "止まった理由", value: reason.displayText)
                }
                if let detail = snapshot.haltDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let text = snapshot.lastText, !text.isEmpty {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let atMS = snapshot.lastTextAtMS {
                        Text("文字: \(StatusClockText.text(atMS: atMS))")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("Watchからまだ届いていません")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 小片の最大音量を、小片の先頭の時刻に置く
    private func levelSamples(_ snapshot: WatchStatusSnapshot) -> [LevelSample] {
        snapshot.levels.map { LevelSample(atMS: $0.startAtMS, dbfs: $0.maxDBFS) }
    }

    private func stateText(_ snapshot: WatchStatusSnapshot) -> String {
        switch snapshot.state {
        case .recording: return "Watch録音中"
        case .halted: return "Watchが止まりました"
        case .stopped:
            return snapshot.haltReason.map { "Watchの録音は止まりました: \($0.displayText)" } ?? "Watchの録音は止まりました"
        case .unknown: return "Watchの状態は不明です"
        }
    }

    private func receivedText(_ snapshot: WatchStatusSnapshot, nowMS: Int64) -> String {
        StatusClockText.text(atMS: snapshot.lastChunkReceivedAtMS)
    }

    private func batteryText(_ snapshot: WatchStatusSnapshot) -> String {
        guard let level = snapshot.batteryLevel else { return "—" }
        return "\(Int((level * 100).rounded()))%"
    }

    /// 左に項目名、右に値。狭い画面では値を折り返して切らさない
    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
