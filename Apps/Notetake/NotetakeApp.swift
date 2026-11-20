import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.checkLoginItem(register: true)
        appModel.ensureDaemon()
    }

    /// daemonへの`quit`送信〜最大2秒の終了待ちはmainスレッドをブロックできないため、
    /// `.terminateLater`で終了を保留し、非同期の`shutdownDaemon()`完了後に終了を再開する。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await appModel.shutdownDaemon()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct NotetakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appModel: appDelegate.appModel)
        } label: {
            Image(systemName: appDelegate.appModel.hasError ? "exclamationmark.triangle" : "waveform")
                .accessibilityLabel("Notetake")
        }
        Settings {
            SettingsView(appModel: appDelegate.appModel)
        }
        Window("ライブ", id: "live") {
            LivePanelView(appModel: appDelegate.appModel)
                .onAppear { appDelegate.appModel.livePanelVisible = true }
                .onDisappear { appDelegate.appModel.livePanelVisible = false }
        }
        .defaultSize(width: 640, height: 480)
        Window("収録の話者", id: "speakers") {
            SpeakersWindowView(appModel: appDelegate.appModel)
        }
        .defaultSize(width: 760, height: 480)
        Window("iPhoneとペアリング", id: "pairing") {
            PairingQRView(appModel: appDelegate.appModel)
        }
        .defaultSize(width: 320, height: 380)
    }
}
