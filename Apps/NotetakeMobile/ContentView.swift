import SwiftUI

struct ContentView: View {
    @Bindable var model: MobileModel

    @State private var pairingCodeInput = ""
    @State private var didLoadPairingCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    LabeledContent("Mac", value: peerStatusText)
                    LabeledContent("未送信", value: "\(model.pendingCount)件")
                    LabeledContent("Watch", value: "\(model.watchStreams) stream")
                }

                Section("収録") {
                    Button(model.isRecording ? "収録停止" : "収録開始") {
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                    if !model.lastText.isEmpty {
                        Text(model.lastText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("自分の名前") {
                    TextField("名前", text: $model.settings.ownerName)
                }

                Section("ペアリングコード") {
                    Text("Macの設定Windowに表示されている6桁のコードを入力してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("123456", text: $pairingCodeInput)
                        .keyboardType(.numberPad)
                        .onChange(of: pairingCodeInput) { _, newValue in
                            let digitsOnly = newValue.filter(\.isNumber)
                            pairingCodeInput = String(digitsOnly.prefix(6))
                        }
                    Button("保存") {
                        model.settings.pairingCode = pairingCodeInput
                        model.pairingCodeDidChange()
                    }
                    .disabled(pairingCodeInput.count != 6)
                }

                if let error = model.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Notetake")
            .onAppear {
                guard !didLoadPairingCode else { return }
                didLoadPairingCode = true
                pairingCodeInput = model.settings.pairingCode
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
