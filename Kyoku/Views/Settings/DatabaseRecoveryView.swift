import SwiftUI

/// Workstream 6 recovery screen. Shown INSTEAD of the normal library UI
/// when the database can't safely start — never alongside it, never
/// destroying data. Plain language, no SQLite jargon: what happened, what
/// is safe, and two actions (try again / start fresh with a backup).
struct DatabaseRecoveryView: View {
    @EnvironmentObject private var container: AppContainer
    var error: DatabaseStartupError
    var dbPath: String
    @State private var showingResetConfirm = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Kyoku couldn't open its music library")
                .font(.title2).fontWeight(.semibold)
            Text(error.userMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("Your music files are untouched. Your settings are untouched. Only the library index failed to open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let notice = container.lastBackupNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let failure = container.resetFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                Button("Try Again") {
                    container.retryBoot()
                }
                .buttonStyle(.borderedProminent)
                .disabled(container.isResetting)
                Button("Start Fresh (Keeps a Backup)…") {
                    showingResetConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(container.isResetting)
            }
            if container.isResetting {
                ProgressView("Creating a fresh library…")
                    .controlSize(.small)
            }
            Text("Starting fresh preserves your current database as a backup file next to it, then creates a new empty library. Your music files stay where they are.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Spacer()
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 480)
        .confirmationDialog(
            "Start with a fresh library?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Preserve Backup & Start Fresh", role: .destructive) {
                container.resetDatabase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // swiftlint:disable:next line_length
            Text("Kyoku will first preserve your current database as a backup file, then create a new empty library. Your music files and settings are not touched.")
        }
        .accessibilityIdentifier("DatabaseRecoveryView")
    }
}
