import SwiftUI

struct ContentView: View {
    @Bindable var model: MobileModel

    @State private var showPairingSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    StatusArea(model: model)
                    LabeledContent("Watch", value: "\(model.watchStreams) stream")
                }

                Section("Watch") {
                    WatchStatusSection(model: model)
                }

                Section("Watch受信モード") {
                    Toggle(
                        "Watch受信モード",
                        isOn: Binding(
                            get: { model.listeningMode.enabled },
                            set: { model.setListeningMode(enabled: $0) }))
                    Text("無音を流して背面で待ち受けます。電池を使います（12時間で自動で切れます）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
}
