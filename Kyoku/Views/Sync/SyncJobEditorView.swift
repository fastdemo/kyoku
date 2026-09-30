import AppKit
import SwiftUI

/// Sync Job editor: destination, profile, schedule, removal, enabled.
/// Used for both create (from a Source) and edit (existing job).
struct SyncJobEditorView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    /// Create mode: source known, no job yet.
    var source: Source?
    /// Edit mode: existing job.
    var job: SyncJobConfig?
    var onDone: () -> Void = {}

    @State private var name = ""
    @State private var destination = ""
    @State private var profileID = DownloadProfile.appleLibrary.id
    @State private var schedule: SyncSchedule = .every30Minutes
    @State private var removalPolicy: RemovalPolicy = .ask
    @State private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEdit ? "Edit Sync Job" : "Create Sync Job")
                .font(.title2).fontWeight(.bold)

            if let sourceName {
                LabeledContent("Source", value: sourceName)
            }

            TextField("Job name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(destination.isEmpty ? "Default music folder" : destination)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { pickDestination() }
            }

            Picker("Download Profile", selection: $profileID) {
                ForEach(DownloadProfile.builtins) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Schedule", selection: $schedule) {
                ForEach(SyncSchedule.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)

            Picker("When tracks disappear", selection: $removalPolicy) {
                ForEach(RemovalPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)

            Toggle("Enabled", isOn: $enabled)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss(); onDone() }
                Button(isEdit ? "Save" : "Create") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: loadInitial)
    }

    private var isEdit: Bool { job != nil }

    private var sourceName: String? {
        if let job, let src = container.sources.sources.first(where: { $0.id == job.sourceID }) {
            return src.displayName.isEmpty ? src.url : src.displayName
        }
        if let source {
            return source.displayName.isEmpty ? source.url : source.displayName
        }
        return nil
    }

    private var canSave: Bool {
        if isEdit { return true }
        return source != nil
    }

    private func loadInitial() {
        if let job {
            name = job.name
            destination = job.destination
            profileID = job.profileID
            schedule = job.schedule
            removalPolicy = job.removalPolicy
            enabled = job.enabled
        } else if let source {
            name = source.displayName.isEmpty ? "Sync" : source.displayName
            destination = defaultDestination
        }
    }

    private var defaultDestination: String {
        guard let root = container.musicFolderAccess.folderURL else { return "" }
        if let source {
            let base = source.displayName.isEmpty ? "Sync" : source.displayName
            let safe = base.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
            return root.appendingPathComponent(safe, isDirectory: true).path
        }
        return root.path
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }

    private func save() {
        if var job {
            // Edit: only the fields on this screen change; snapshots,
            // run history, and linkage are untouched.
            job.name = name
            job.destination = destination
            job.profileID = profileID
            job.schedule = schedule
            job.removalPolicy = removalPolicy
            job.enabled = enabled
            container.syncJobs.update(job)
        } else if let source {
            var created = container.syncJobs.create(
                sourceID: source.id, name: name, destination: destination,
                profileID: profileID, schedule: schedule,
                removalPolicy: removalPolicy)
            created.enabled = enabled
            container.syncJobs.update(created)
        }
        dismiss()
        onDone()
    }
}
