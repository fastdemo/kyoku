import SwiftUI

/// Phase 1 sources: paste a URL or search term → resolve → preview tracks
/// → enqueue. No spotDL vocabulary; just "paste a link, get music".
struct SourcesView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var input = ""
    @State private var isResolving = false
    @State private var discovered: [DiscoveredTrack] = []
    @State private var errorMessage: String?
    @State private var resolveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Music")
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack(spacing: 8) {
                TextField("Spotify or YouTube link, or search for a song…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { resolve() }
                    .disabled(isResolving)
                if isResolving {
                    Button("Cancel") { resolveTask?.cancel() }
                } else {
                    Button("Add") { resolve() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if isResolving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding tracks… this can take a few minutes on first run.")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if !discovered.isEmpty {
                resultsSection
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Sources")
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(discovered.count) track\(discovered.count == 1 ? "" : "s") found")
                    .font(.headline)
                Spacer()
                Button("Download All") {
                    container.queue.enqueue(discovered.map(\.song), sourceURL: input)
                    discovered = []
                    input = ""
                }
                .buttonStyle(.borderedProminent)
            }
            List {
                ForEach(discovered) { track in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(track.artist) – \(track.title)")
                                .lineLimit(1)
                            Text(track.song.albumName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(formatDuration(track.song.duration))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200)
        }
    }

    private func resolve() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        errorMessage = nil
        discovered = []
        isResolving = true
        resolveTask = Task {
            do {
                let engine = container.downloads
                let tracks = try await engine.resolveSource(query)
                if !Task.isCancelled {
                    discovered = tracks
                    if tracks.isEmpty {
                        errorMessage = "No tracks found. Check the link and try again."
                    }
                }
            } catch is CancellationError {
                // User cancelled; stay quiet.
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isResolving = false
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
