import SwiftUI

/// Shared track context menu. Used by Songs, Albums detail, Artists
/// detail, playlists, and search results — one definition, everywhere.
struct TrackContextMenu: ViewModifier {
    @EnvironmentObject private var container: AppContainer
    var track: Track
    var context: [Track]
    var onShowAlbum: ((Track) -> Void)?
    var onShowArtist: ((Track) -> Void)?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play") {
                container.player?.play(track, in: context.isEmpty ? nil : context)
            }
            Button("Play Next") { container.player?.playNext(track) }
            Button("Add to Queue") { container.player?.addToQueue(track) }
            Menu("Add to Playlist") {
                ForEach(container.readyLibrary.playlists) { playlist in
                    Button(playlist.name) {
                        container.readyLibrary.addToPlaylist(playlistID: playlist.id, trackIDs: [track.id])
                    }
                }
            }
            Divider()
            if onShowAlbum != nil {
                Button("Show Album") { onShowAlbum?(track) }
            }
            if onShowArtist != nil {
                Button("Show Artist") { onShowArtist?(track) }
            }
            Button("Reveal in Finder") {
                if let path = track.localPath {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            .disabled(track.localPath == nil)
            Divider()
            Button("Remove from Library") {
                container.readyLibrary.removeFromLibrary(trackID: track.id)
            }
            Button("Delete File…") {
                confirmDelete = true
            }
        }
        .confirmationDialog(
            "Delete this file from disk?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                _ = container.readyLibrary.deleteFile(trackID: track.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(track.title) will be moved to the Trash. This cannot be undone.")
        }
    }

    @State private var confirmDelete = false
}

extension View {
    func trackMenu(track: Track, context: [Track] = [],
                   onShowAlbum: ((Track) -> Void)? = nil,
                   onShowArtist: ((Track) -> Void)? = nil) -> some View {
        modifier(TrackContextMenu(track: track, context: context,
                                  onShowAlbum: onShowAlbum, onShowArtist: onShowArtist))
    }
}
