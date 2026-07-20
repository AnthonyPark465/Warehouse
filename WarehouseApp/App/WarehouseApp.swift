import SwiftUI
import FirebaseCore

@main
struct WarehouseApp: App {
    init() {
        FirebaseBootstrap.configureIfPossible()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum FirebaseBootstrap {
    static var isConfigured: Bool {
        FirebaseApp.app() != nil
    }

    /// GoogleService-Info.plist is gitignored and added by each developer,
    /// so the app must stay launchable without it.
    static func configureIfPossible() {
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else {
            return
        }
        FirebaseApp.configure()
    }
}
