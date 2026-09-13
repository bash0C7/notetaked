import SwiftUI

@main
struct NotetakeWatchApp: App {
    @State private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchContentView(recorder: recorder)
            }
        }
    }
}
