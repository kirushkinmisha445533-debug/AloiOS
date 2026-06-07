import SwiftUI

@main
struct AloiOSApp: App {
    @StateObject private var app = AloAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}
