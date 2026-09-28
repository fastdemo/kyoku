import SwiftUI

/// Unwraps the (late-wired) PlaybackService for player UI. Shows nothing
/// until AppContainer.startPlayer() completes (first scene task tick).
struct IfPlayer<Content: View>: View {
    @EnvironmentObject private var container: AppContainer
    @ViewBuilder var content: (PlaybackService) -> Content

    var body: some View {
        if let player = container.player {
            content(player)
        }
    }
}
