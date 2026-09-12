import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.ensureDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appModel.shutdownDaemon()
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
    }
}
