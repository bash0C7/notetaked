import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerForLogin()
        appModel.ensureDaemon()
    }

    /// Notetake.app itselfをmacOSのログイン項目に登録する。
    /// 登録済み、またはユーザーの承認待ちなら状態を変えず、未登録の場合だけ登録する。
    private func registerForLogin() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered:
            do {
                try service.register()
            } catch {
                appModel.lastError = "ログイン時自動起動の登録に失敗しました: \(error.localizedDescription)"
            }
        case .notFound:
            appModel.lastError = "ログイン時自動起動を登録できませんでした: Notetake.appが見つかりません"
        @unknown default:
            appModel.lastError = "ログイン時自動起動の状態を確認できませんでした"
        }
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
