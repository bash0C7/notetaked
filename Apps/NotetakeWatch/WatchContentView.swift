import NotetakeCore
import SwiftUI

/// Watch appのメイン画面。表示は色の点・1行・触覚（と開始・停止）だけにして、電池を記録に残す。
/// 止まった時の知らせは画面でなく触覚と通知が担う。
struct WatchContentView: View {
    @Bindable var recorder: WatchRecorder
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 32))
                        Text(recorder.isRecording ? "停止" : "開始")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)

                statusLine

                Button("設定") { showingSettings = true }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Notetake")
        .sheet(isPresented: $showingSettings) {
            WatchSettingsView(recorder: recorder)
        }
    }

    /// 色の点と1行。未転送の件数は行の末尾に小さく添える
    private var statusLine: some View {
        let message = recorder.display.message
        let color: Color = recorder.isRecording && message.severity == .normal ? .green : message.severity.color
        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor(message: message, fallback: color))
                .frame(width: 10, height: 10)
            Text(lineText(message: message))
                .font(.footnote)
                .multilineTextAlignment(.leading)
            if recorder.pendingTransfers > 0 {
                Text("未転送 \(recorder.pendingTransfers)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dotColor(message: IndicatorMessage, fallback: Color) -> Color {
        if recorder.isRecording || !message.text.isEmpty { return fallback }
        return recorder.interruptedOnLaunch ? IndicatorSeverity.alert.color : .secondary
    }

    private func lineText(message: IndicatorMessage) -> String {
        if !message.text.isEmpty { return message.text }
        if recorder.interruptedOnLaunch { return "前回の録音は中断されました" }
        if let lastError = recorder.lastError { return lastError }
        return "停止中"
    }
}

/// 自分の名前（`owner`としてsegに載る）を編集するだけの簡易設定画面。
private struct WatchSettingsView: View {
    @Bindable var recorder: WatchRecorder

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前", text: $recorder.ownerName)
            }
            .navigationTitle("設定")
        }
    }
}
