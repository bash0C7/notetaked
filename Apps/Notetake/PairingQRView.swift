import SwiftUI

/// menuの「iPhoneとペアリング」から開くwindow。現在のpairing codeをQR化して表示する。
/// 「切断」は新しいコードを再生成し、古いコードで接続中のiPhoneを実質的に無効化する
/// （iPhone側は個別に「ペアリングを解除」する必要がある）
struct PairingQRView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("iPhoneのNotetakeで「Macとペアリング」からこのQRコードをスキャンしてください")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let image = QRCodeGenerator.image(for: appModel.pairingCode) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                Text("QRコードの生成に失敗しました")
                    .foregroundStyle(.red)
                    .frame(width: 240, height: 240)
            }
            Text(appModel.pairingCode)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("切断（新しいコードを再生成）") { appModel.regeneratePairingCode() }
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 380)
        .onChange(of: appModel.connectedPeers.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty {
                dismiss()
            }
        }
    }
}
