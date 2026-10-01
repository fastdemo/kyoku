import AppKit
import SwiftUI

/// Kyoku application entry point.
/// Phase 0: wires the DI container, shows RootView. Views stay thin;
///
/// Business logic lives in KyokuCore services.
///
/// Background-execution model (Phase 3 decision, documented):
/// Kyoku is a regular foreground .app. Scheduled sync continues while
/// the app is RUNNING with all windows closed (the scheduler lives in
/// the AppContainer, not in any view). True launch-at-login / run-while-
/// terminated execution needs an SMAppService login item + helper, which
/// is deferred to Phase 6 (packaging/signing) — installing a helper now
/// would complicate sandbox/signing for no verified benefit, and macOS
/// terminates plain apps(deliberately): pretending otherwise would be fake.
/// AppDelegate below keeps the app alive windowless + refocuses on dock click.
@main
struct KyokuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            Group {
                switch container.bootState {
                case .recovery(let error, let path):
                    // Recovery owns the screen: no library UI, no workers,
                    // no onboarding — nothing touches the broken DB.
                    DatabaseRecoveryView(error: error, dbPath: path)
                        .environmentObject(container)
                case .ready:
                    if container.settings.needsOnboarding(
                        hasFolder: container.readyMusicFolderAccess.hasFolder) {
                        OnboardingView()
                            .environmentObject(container)
                    } else {
                        RootView()
                            .environmentObject(container)
                    }
                }
            }
            .task {
                // Start actor-bound services on the main actor.
                // (AppContainer.init is nonisolated, so actor-bound
                // startup is deferred to here. start() is a no-op in
                // recovery state.)
                container.start()
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

/// Keeps Kyoku running windowless so scheduled sync continues after the
/// main window closes (scheduler + queue live in AppContainer, not views).
/// Also reopens the main window on dock-icon click when none is visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // NO: closing the window must not stop automation.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click with no windows: SwiftUI's WindowGroup reopens
        // automatically when this returns true.
        true
    }
}
