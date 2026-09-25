import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
