import SwiftUI

/// Sync Preview (dry run): resolve + diff, show counts, Apply runs the
/// real sync. Removals are described per the job's removal policy —
/// never presented as actions for "Never remove".
struct SyncPreviewView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    var job: SyncJobConfig

    @State private var isLoading = true
    @State private var changes: ChangeSet?
    @State private var total = 0
    @State private var errorMessage: String?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Preview")
                .font(.title2).fontWeight(.bold)
            Text(job.name)
                .foregroundStyle(.secondary)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Resolving source… (cancellable, may take minutes)")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { previewTask?.cancel(); dismiss() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Close") { dismiss() }
            } else if let changes {
                summary(changes)
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Apply Sync") {
                        dismiss()
                        SyncNowRunner.run(jobID: job.id, container: container)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            previewTask = Task {
                if let result = await container.readySyncEngine.preview(jobID: job.id) {
                    if !Task.isCancelled {
                        changes = result.changes
                        total = result.total
                    }
                } else if !Task.isCancelled {
                    errorMessage = "Could not resolve the source. Check the URL and connection."
                }
                isLoading = false
            }
            await previewTask?.value
        }
    }

    private func summary(_ changes: ChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(total) tracks")
                .font(.headline)
            Group {
                Text("+ \(changes.added.count) new")
                Text("✓ \(changes.unchangedCount) unchanged")
                if !changes.changed.isEmpty {
                    Text("~ \(changes.changed.count) changed")
                }
                removalLine(changes)
            }
            .foregroundStyle(.secondary)
            Divider()
            Text("Downloads: \(downloadCount(changes))")
                .font(.headline)
            if removalActionCount(changes) > 0 {
                Text("Local removals: \(removalActionCount(changes))")
                    .font(.headline)
            }
        }
    }

    private func removalLine(_ changes: ChangeSet) -> some View {
        Group {
            switch job.removalPolicy {
            case .keep:
                if !changes.removed.isEmpty {
                    Text("− \(changes.removed.count) removed upstream (will be kept)")
                }
            case .ask:
                if !changes.removed.isEmpty {
                    Text("− \(changes.removed.count) removed (confirmation required)")
                }
            case .delete:
                if !changes.removed.isEmpty {
                    Text("− \(changes.removed.count) removed (will be removed from library)")
                }
            }
        }
    }

    private func downloadCount(_ changes: ChangeSet) -> Int {
        changes.added.count + changes.changed.count
    }

    private func removalActionCount(_ changes: ChangeSet) -> Int {
        job.removalPolicy == .delete ? changes.removed.count : 0
    }
}
