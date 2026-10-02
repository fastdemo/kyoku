import AppKit
import SwiftUI

/// Needs Attention: persistent inbox of automation problems with actions.
/// Retry re-runs the job (failures re-detect naturally); Ignore resolves
/// the item; removal-pending items offer Keep vs Remove.
struct NeedsAttentionView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        // No in-content title: the Automation disclosure + window title
        // already say "Needs Attention". Content starts with the inbox.
        VStack(alignment: .leading, spacing: 0) {
            let items = container.readyAutomation.openAttention
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("All clear")
                        .font(.headline)
                    Text("Sync problems will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, id: \.id) { item in
                    AttentionRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Needs Attention")
    }
}

private struct AttentionRow: View {
    @EnvironmentObject private var container: AppContainer
    var item: AttentionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                actionButtons
                Spacer()
                Button("Ignore") {
                    container.readyAutomation.resolveAttention(id: item.id)
                }
                .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch item.kind {
        case "downloadFailed": return "arrow.down.circle"
        case "sourceFailed": return "antenna.radiowaves.left.and.right"
        case "removalPending": return "trash"
        case "musicFolderInaccessible", "destinationInaccessible": return "folder.badge.questionmark"
        default: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.kind {
        case "downloadFailed":
            if let taskID = item.taskID {
                Button("Retry") {
                    container.readyQueue.retry(taskID: taskID)
                    container.readyAutomation.resolveAttention(id: item.id)
                }
            } else if let jobID = item.syncJobID {
                Button("Retry Sync") {
                    SyncNowRunner.run(jobID: jobID, container: container)
                    container.readyAutomation.resolveAttention(id: item.id)
                }
            }
        case "sourceFailed":
            if let jobID = item.syncJobID {
                Button("Retry Sync") {
                    SyncNowRunner.run(jobID: jobID, container: container)
                    container.readyAutomation.resolveAttention(id: item.id)
                }
            }
        case "musicFolderInaccessible":
            Button("Reconnect in Settings") {
                // Settings is a separate scene; resolving here avoids a
                // dead-end item. The relink prompt lives in Settings →
                // Library, which re-validates on pick.
                container.readyAutomation.resolveAttention(id: item.id)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        case "destinationInaccessible":
            // Repaired in the job editor (destination picker rewrites the
            // bookmark). Resolving here would hide a still-broken job.
            if item.syncJobID != nil {
                Text("Fix in Sync Jobs → Edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case "removalPending":
            Button("Keep in Library") {
                container.readyAutomation.resolveAttention(id: item.id)
            }
            if let trackURL = item.trackURL,
               let track = container.readyLibrary.tracks.first(where: { $0.sourceURL == trackURL }) {
                Button("Remove") {
                    container.readyLibrary.removeFromLibrary(trackID: track.id)
                    container.readyAutomation.resolveAttention(id: item.id)
                }
            }
        default:
            if let jobID = item.syncJobID {
                Button("Open Job") {
                    // Jobs live under Sync Jobs; resolving keeps the item
                    // visible until the user acts. No-op navigation: the
                    // sidebar selection is app-level (kept simple).
                    _ = jobID
                }
            }
        }
    }
}
