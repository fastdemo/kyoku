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
                    // Start the download queue worker on the main actor.
                    // (AppContainer.init is nonisolated, so the queue's
                    // actor-bound startup is deferred to here.)
                    await container.queue.start()
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
