import SwiftUI

/// `Settings`シーンで表示する設定画面。保存先と自分の名前を編集する。
struct SettingsView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        Form {
            LabeledContent("保存先") {
                HStack {
                    Text(appModel.outputDirectory?.path ?? "未設定")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { chooseOutputDirectory() }
                }
            }
            TextField("自分の名前", text: $appModel.ownerName)
        }
        .onChange(of: appModel.ownerName) { _, _ in appModel.ensureDaemon() }
        .padding()
        .frame(minWidth: 360)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = appModel.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.outputDirectory = url
        appModel.ensureDaemon()
    }
}
