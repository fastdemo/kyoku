import SwiftUI

/// Phase 1 queue: live task list with states, errors, retry/cancel.
/// Thin view over DownloadQueue; all logic lives there.
struct QueueView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if container.queue.tasks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(container.queue.tasks) { task in
                        TaskRow(task: task)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Queue")
    }

    private var header: some View {
        HStack {
            Text("Download Queue")
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            if hasFinished {
                Button("Clear Finished") {
                    container.queue.clearFinished()
                }
            }
        }
        .padding(24)
        .padding(.bottom, 0)
    }

    private var hasFinished: Bool {
        container.queue.tasks.contains {
            $0.state == .done || $0.state == .failed || $0.state == .cancelled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing queued")
                .font(.headline)
            Text("Paste a Spotify or YouTube URL on the Sources tab to start.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var container: AppContainer
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = task.lastError, task.state == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        task.resolvedSong.map { "\($0.artist) – \($0.name)" } ?? task.sourceURL
    }

    private var subtitle: String {
        switch task.state {
        case .pending: return "Waiting"
        case .resolving: return "Finding audio…"
        case .downloading: return "Downloading…"
        case .processing: return "Processing…"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .resolving, .downloading, .processing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch task.state {
        case .pending, .resolving, .downloading, .processing:
            Button("Cancel") { container.queue.cancel(taskID: task.id) }
                .buttonStyle(.link)
        case .failed:
            Button("Retry") { container.queue.retry(taskID: task.id) }
        case .done, .cancelled:
            EmptyView()
        }
    }
}
