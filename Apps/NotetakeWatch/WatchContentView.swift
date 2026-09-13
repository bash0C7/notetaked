import SwiftUI

/// Watch appのメイン画面。前面表示中のみ録音する前提で、大きな開始/停止ボタン・経過時間・
/// 未転送小片数・直近のエラーを表示する。
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

                Text(Self.formattedElapsed(recorder.elapsedSeconds))
                    .font(.system(.title2, design: .monospaced))
                    .monospacedDigit()

                Text("未転送 \(recorder.pendingTransfers)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let lastError = recorder.lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

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

    private static func formattedElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        return String(format: "%02d:%02d", minutes, remaining)
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
