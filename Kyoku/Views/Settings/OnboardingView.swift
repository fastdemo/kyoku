import SwiftUI

/// First-run flow: Welcome → Music folder → How it works → Finish.
/// Gated by AppSettings.needsOnboarding (flag AND usable folder).
/// Cannot complete without a valid folder (completeOnboarding refuses).
struct OnboardingView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var step = 0
    @State private var folderError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            switch step {
            case 0: welcomeStep
            case 1: folderStep
            case 2: howItWorksStep
            default: welcomeStep
            }
            Spacer()
            controls
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Welcome to Kyoku")
                .font(.largeTitle).fontWeight(.bold)
            Text("Your local music library.\nAdd Spotify or YouTube sources — Kyoku downloads, organizes, and plays your music automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var folderStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Where should Kyoku keep your music?")
                .font(.title2).fontWeight(.semibold)
            Text("Choose a folder for downloads. You can change it later in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let path = container.readyMusicFolderAccess.folderURL?.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose Folder…") {
                if FolderPicker.pickAndStoreMusicFolder(access: container.readyMusicFolderAccess) {
                    folderError = nil
                }
            }
            .buttonStyle(.borderedProminent)
            if let folderError {
                Text(folderError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var howItWorksStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Add source → Kyoku syncs → play")
                .font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 6) {
                Label("Paste a Spotify or YouTube link under Sources", systemImage: "1.circle")
                Label("Kyoku downloads new tracks automatically", systemImage: "2.circle")
                Label("Music appears in your library — press play", systemImage: "3.circle")
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1; folderError = nil }
            }
            Spacer()
            Text("\(step + 1) of 3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if step < 2 {
                Button(step == 1 ? "Continue" : "Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !container.readyMusicFolderAccess.hasFolder)
            } else {
                Button("Start Using Kyoku") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        if step == 1, !container.readyMusicFolderAccess.hasFolder {
            folderError = "Please choose a folder to continue."
            return
        }
        folderError = nil
        step += 1
    }

    private func finish() {
        // Refuses without a folder — invalid setup cannot silently complete.
        if container.settings.completeOnboarding(
            hasFolder: container.readyMusicFolderAccess.hasFolder) {
            folderError = nil
        } else {
            step = 1
            folderError = "Please choose a folder to finish setup."
        }
    }
}
