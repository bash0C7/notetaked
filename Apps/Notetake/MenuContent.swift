import NotetakeCore
import SwiftUI

/// メニューバーアイコンをクリックした時に表示するメニュー内容。
struct MenuContent: View {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    private static let nextRotationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        formatter.timeZone = .current
        return formatter
    }()

    var body: some View {
        Text(statusText)
        if appModel.isRecording {
            ForEach(appModel.captureStatuses, id: \.source) { status in
                Text(CaptureStatusLabel.text(for: status))
                    .foregroundStyle(.secondary)
            }
        }
        if let nextRotationAt = appModel.nextRotationAt {
            Text("次の区切り " + Self.nextRotationFormatter.string(from: nextRotationAt))
                .foregroundStyle(.secondary)
        }
        if !appModel.connectedPeers.isEmpty {
            Text("接続: " + appModel.connectedPeerNames.joined(separator: "/"))
                .foregroundStyle(.secondary)
        }
        if let lastLog = appModel.lastLog {
            Text(lastLog)
                .foregroundStyle(.secondary)
        }
        if let lastError = appModel.lastError {
            Text(lastError)
                .foregroundStyle(.red)
        }
        ForEach(FinalizeStatusLabel.menuLines(states: appModel.finalizeStates), id: \.self) { line in
            Text(line)
                .foregroundStyle(.secondary)
        }
        Divider()
        Button("収録開始") { appModel.startRecording() }
            .disabled(!appModel.recordingControls.canStart)
        Button("収録停止") { appModel.stopRecording() }
            .disabled(!appModel.recordingControls.canStop)
        Button("収録を区切る") { appModel.rotateRecording() }
            .disabled(!appModel.recordingControls.canRotate)
        Divider()
        Button("ライブパネルを開く") {
            NSApp.activate()
            openWindow(id: "live")
        }
        Button("iPhoneとペアリング") {
            NSApp.activate()
            openWindow(id: "pairing")
        }
        Button("フォルダを開く") { appModel.openOutputFolder() }
            .disabled(appModel.outputDirectory == nil)
        Button("直前の収録を整形") { appModel.polishLastRecording() }
            .disabled(!appModel.recordingControls.canPolish)
        if let polishNote = appModel.recordingControls.polishNote {
            Text(polishNote)
                .foregroundStyle(.secondary)
        }
        Button("収録の話者…") {
            NSApp.activate()
            openWindow(id: "speakers")
        }
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
