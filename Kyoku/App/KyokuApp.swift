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
                .task {
                    // Start actor-bound services on the main actor.
                    // (AppContainer.init is nonisolated, so actor-bound
                    // startup is deferred to here.)
                    await container.queue.start()
                    await container.startPlayer()
                }
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
