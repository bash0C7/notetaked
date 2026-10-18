import SwiftUI

@main
struct NotetakeMobileApp: App {
    @State private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // 背面で溜まった受け取り箱の小片を、前面になった時に回収する
            if phase == .active { model.didBecomeActive() }
        }
    }
}
