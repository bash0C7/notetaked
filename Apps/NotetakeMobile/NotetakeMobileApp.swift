import SwiftUI

@main
struct NotetakeMobileApp: App {
    @State private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
