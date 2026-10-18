import SwiftUI

@main
struct NotetakeWatchApp: App {
    @State private var recorder = WatchRecorder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchContentView(recorder: recorder)
            }
            .onChange(of: scenePhase) { _, newPhase in
                recorder.scenePhaseChanged(newPhase)
            }
        }
    }
}
