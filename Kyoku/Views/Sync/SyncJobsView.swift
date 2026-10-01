import SwiftUI

/// Sync Jobs: status cards with Sync Now, progress, schedule, editor.
/// Thin over SyncJobStore + SyncEngine; no scheduling logic here.
struct SyncJobsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var editingJob: SyncJobConfig?
    @State private var runningJobID: String?
    @State private var previewJob: SyncJobConfig?
    @State private var showingCreateFor: Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sync Jobs")
                    .font(.largeTitle).fontWeight(.bold)
                Spacer()
            }
            .padding(20)
            Divider()
            if container.readySyncJobs.jobs.isEmpty {
                emptyState
            } else {
                List(container.readySyncJobs.jobs) { job in
                    SyncJobRow(job: job,
                               isRunning: runningJobID == job.id,
                               onSyncNow: { syncNow(job) },
                               onPreview: { previewJob = job },
                               onEdit: { editingJob = job })
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Sync Jobs")
        .sheet(item: $editingJob) { job in
            SyncJobEditorView(job: job, onDone: { editingJob = nil })
                .environmentObject(container)
                .frame(minWidth: 520, minHeight: 460)
        }
        .sheet(item: $previewJob) { job in
            SyncPreviewView(job: job)
                .environmentObject(container)
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No Sync Jobs")
                .font(.headline)
            Text("Create a Sync Job to keep a playlist synchronized automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncNow(_ job: SyncJobConfig) {
        guard runningJobID == nil else { return }
        runningJobID = job.id
        Task { @MainActor in
            container.readyScheduler.markRunning(job.id)
            await container.readySyncEngine.run(jobID: job.id)
            container.readyScheduler.markFinished(job.id)
            container.readySyncJobs.refresh()
            container.readySources.refresh()
            container.readyAutomation.refresh()
            runningJobID = nil
        }
    }
}

private struct SyncJobRow: View {
    @EnvironmentObject private var container: AppContainer
    var job: SyncJobConfig
    var isRunning: Bool
    var onSyncNow: () -> Void
    var onPreview: () -> Void
    var onEdit: () -> Void

    var body: some View {
        let source = container.readySources.sources.first { $0.id == job.sourceID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name.isEmpty ? (source?.displayName ?? "Sync Job") : job.name)
                        .font(.headline)
                    Text(source?.displayName ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                statusBadge
            }
            if isRunning, let progress = container.readySyncEngine.progress, progress.jobID == job.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.phase)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let error = job.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Button(isRunning ? "Syncing…" : "Sync Now") { onSyncNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || !(source?.enabled ?? true))
                Button("Preview") { onPreview() }
                Button(job.enabled ? "Pause" : "Resume") {
                    container.readySyncJobs.setEnabled(id: job.id, enabled: !job.enabled)
                }
                Spacer()
                Button("Edit") { onEdit() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Delete Job", role: .destructive) {
                container.readySyncJobs.remove(id: job.id)
            }
        }
    }

    private var statusBadge: some View {
        Group {
            if !job.enabled {
                Label("Paused", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            } else if isRunning {
                Label("Active", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            } else if job.lastError != nil {
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                Label("Active", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline)
    }

    private var statusLine: String {
        var parts: [String] = []
        let count = container.readySources.loadSnapshot(
            sourceID: job.sourceID).count
        if count > 0 { parts.append("\(count) track\(count == 1 ? "" : "s")") }
        if !job.destination.isEmpty {
            parts.append(URL(fileURLWithPath: job.destination).lastPathComponent)
        }
        parts.append(container.readyScheduler.nextCheckDescription(job))
        if let last = job.lastSuccessAt {
            parts.append("Last synced \(last.formatted(.relative(presentation: .named)))")
        }
        parts.append(job.schedule.label)
        return parts.joined(separator: " · ")
    }
}
