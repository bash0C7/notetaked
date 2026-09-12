import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        MenuBarExtra("Notetake", systemImage: "waveform") {
            MenuContent(appModel: appDelegate.appModel)
        }
        Settings {
            SettingsView(appModel: appDelegate.appModel)
        }
        Window("ライブ", id: "live") {
            LivePanelView(appModel: appDelegate.appModel)
        }
        .defaultSize(width: 640, height: 480)
    }
}
