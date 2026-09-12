import SwiftUI

/// `Settings`シーンで表示する設定画面。保存先と自分の名前を編集する。
/// 自分の名前はキー入力ごとではなく、確定（Enter/フォーカス喪失）時にのみ`appModel`へ反映する。
/// `--owner`はdaemonの起動引数に含まれるため、確定していない値で毎回daemonを再起動しないようにするため。
struct SettingsView: View {
    @Bindable var appModel: AppModel
    @State private var ownerNameDraft: String = ""
    @FocusState private var ownerNameFieldFocused: Bool

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
            TextField("自分の名前", text: $ownerNameDraft)
                .focused($ownerNameFieldFocused)
                .onSubmit { commitOwnerName() }
        }
        .onAppear { ownerNameDraft = appModel.ownerName }
        .onChange(of: ownerNameFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitOwnerName()
            }
        }
        .padding()
        .frame(minWidth: 360)
    }

    private func commitOwnerName() {
        guard ownerNameDraft != appModel.ownerName else { return }
        appModel.ownerName = ownerNameDraft
        appModel.ensureDaemon()
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
