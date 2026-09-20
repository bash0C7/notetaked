import SwiftUI

struct ContentView: View {
    @Bindable var model: MobileModel

    @State private var showPairingSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    LabeledContent("Mac", value: peerStatusText)
                    LabeledContent("未送信", value: "\(model.pendingCount)件")
                    LabeledContent("Watch", value: "\(model.watchStreams) stream")
                }

                Section("取り込み") {
                    Button(model.isRecording ? "取り込み中（タップで終了）" : "取り込み開始") {
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                    Text("Macでセッションを開始してから使ってください。取り込んだ音声は時刻でMacのセッションに自動的に統合されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !model.lastText.isEmpty {
                        Text(model.lastText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("自分の名前") {
                    TextField("名前", text: $model.settings.ownerName)
                }

                Section("ペアリング") {
                    if model.settings.pairingCode.isEmpty {
                        Button("Macとペアリング") { showPairingSheet = true }
                    } else {
                        Button("ペアリングを解除") {
                            model.settings.pairingCode = ""
                            model.pairingCodeDidChange()
                        }
                    }
                }

                if let error = model.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Notetake")
            .sheet(isPresented: $showPairingSheet) {
                PairingSheet(model: model)
            }
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
