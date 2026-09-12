import SwiftUI

/// メニューバーアイコンをクリックした時に表示するメニュー内容。
struct MenuContent: View {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        if let lastError = appModel.lastError {
            Text(lastError)
                .foregroundStyle(.red)
        }
        Divider()
        Button("収録開始") { appModel.startRecording() }
            .disabled(appModel.outputDirectory == nil || appModel.isRecording)
        Button("収録停止") { appModel.stopRecording() }
            .disabled(appModel.outputDirectory == nil || !appModel.isRecording)
        Divider()
        Button("ライブパネルを開く") {
            NSApp.activate()
            openWindow(id: "live")
        }
        Button("フォルダを開く") { appModel.openOutputFolder() }
            .disabled(appModel.outputDirectory == nil)
        Divider()
        SettingsLink {
            Text("設定…")
        }
        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        if appModel.isRecording, let prefix = appModel.prefix {
            return "収録中 \(prefix)"
        }
        return "停止中"
    }
}
