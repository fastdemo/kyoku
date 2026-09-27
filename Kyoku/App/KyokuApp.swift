import SwiftUI

/// Kyoku application entry point.
/// Phase 0: wires the DI container, shows RootView. Views stay thin;
///
/// Business logic lives in KyokuCore services.
@main
struct KyokuApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
        }
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(container)
        }
    }
}
