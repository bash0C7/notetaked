import SwiftUI

/// 「Macとペアリング」から開くモーダル。カメラでMacが表示するQRコードを読み取るか、
/// 6桁のコードを手入力してMacとペアリングする（issue #4）
struct PairingSheet: View {
    @Bindable var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualInput = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if QRScannerView.isSupported {
                    QRScannerView(onDetect: apply)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    Text("このデバイスではQRコードのスキャンを利用できません。下の欄に直接入力してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                Form {
                    Section("コードを直接入力") {
                        Text("Macのメニューの「iPhoneとペアリング」に表示される6桁のコードを入力してください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("123456", text: $manualInput)
                            .keyboardType(.numberPad)
                            .onChange(of: manualInput) { _, newValue in
                                let digitsOnly = newValue.filter(\.isNumber)
                                manualInput = String(digitsOnly.prefix(6))
                            }
                        Button("次へ") { apply(code: manualInput) }
                            .disabled(manualInput.count != 6)
                    }
                }
            }
            .navigationTitle("Macとペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func apply(code: String) {
        guard code.count == 6 else { return }
        model.settings.pairingCode = code
        model.pairingCodeDidChange()
        dismiss()
    }
}
