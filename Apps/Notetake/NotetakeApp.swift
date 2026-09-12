import SwiftUI

@main
struct NotetakeApp: App {
    var body: some Scene {
        MenuBarExtra("Notetake", systemImage: "waveform") {
            Text("Notetake").font(.headline)
            Divider()
            Button("終了") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
