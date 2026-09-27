# Kyoku — Phase 1 Download Engine

Native macOS SwiftUI music library + automated sync engine (in progress).
Phase 0 established the foundation; Phase 1 implements the download engine:
URL → source resolution → track discovery → download queue → filesystem
organization → library indexing.

## Build

```sh
./scripts/build.sh
# or
xcodebuild -project Kyoku.xcodeproj -scheme Kyoku -configuration Debug build
```

Requires Xcode 16+ (macOS 14 SDK). No third-party dependencies.

## Architecture

```
SwiftUI views (thin) → AppContainer (DI) → Core services → backends
```

| Area | Location | Notes |
|---|---|---|
| App entry / DI / root nav | `Kyoku/App/` | `KyokuApp`, `AppContainer`, `RootView` |
| Logging | `Kyoku/Core/Logging/` | `os_log` wrapper, `com.kyoku.app.*` |
| Settings | `Kyoku/Core/Settings/` | `AppSettings` (UserDefaults) |
| Database | `Kyoku/Core/Database/` | Serial-queue SQLite3, versioned migrations (`Schema.v1`) |
| Models | `Kyoku/Core/Models/` | `Track`, `SyncJob`, `DownloadProfile` (minimal Phase 0 shapes) |
| Library | `Kyoku/Core/Library/` | `LibraryStore` (DB-backed, observable) |
| Player | `Kyoku/Core/Player/` | `PlayerService` (AVPlayer local files) |
| Downloads | `Kyoku/Core/Downloads/` | `DownloadEngine` protocol (+`DownloadEngineError`), `ProcessRunner` (sole subprocess owner), `SpotDLEngine`, `DownloadQueue` (persistent serial worker) |
| Filesystem | `Kyoku/Core/Filesystem/` | `MusicFolderAccess` (security-scoped bookmarks) |
| Sync | `Kyoku/Core/Sync/` | `SyncScheduler` (interval/backoff math; BG strategy documented in-file) |

Rules: no shell commands in views; all subprocesses go through
`ProcessRunner` (argv arrays, never shell strings); async work is
cancellable; queue state persists in SQLite.

## Phase 1 pipeline (verified on dev machine, spotdl 4.5.2)

```
URL/search term
  → `spotdl save QUERY --save-file - --preload` (JSON on stdout)
  → [ResolvedSong] decoded, filtered, previewed in SourcesView
  → DownloadQueue.enqueue (SQLite-backed, dedup by Spotify URL)
  → serial worker → `spotdl download URL --output DIR --format …`
  → file located in music folder → LibraryStore.importFile → indexed
```

Key findings baked into the implementation:

- Spotify metadata goes through SpotipyFree scraping (not the official
  API); `spotdl` needs no client ID/secret. Requires `spotapi≥1.2.8`
  (1.2.7 returned `GenericError` for track lookups).
- Discovery is slow (60s search + ~6min preload for one track on cold
  runs: Spotify fetch + per-track YouTube matching). UI treats resolve
  as long-running with progress + cancel; timeouts are 600s/1200s.
- `--preload` resolves the candidate audio URL at discovery time.
- `spotdl download` with `--audio youtube` hangs under bot-check
  pressure; `youtube-music` matched and downloaded in ~6 min total.
  No provider override is set — spotDL picks, matching stays intact.
- `yt-dlp` direct YouTube playback needs
  `--extractor-args youtube:player_client=android` (web/ios/tv clients
  hit bot checks); relevant if Kyoku ever calls yt-dlp directly.
- spotDL writes logs to stderr, `save` JSON to stdout; `ProcessRunner`
  drains both pipes incrementally (64KB+ outputs would deadlock
  capture-at-exit on large playlists).

## Sandbox

App-sandboxed (`Kyoku.entitlements`): user-selected read/write, app-scope
bookmarks, network client. DB lives in the sandbox container
(`~/Library/Containers/com.kyoku.app/...`), verified working.

## Risks (from brief) — Phase 0 dispositions

- **Python/spotDL embedding**: deferred to Phase 6. Dev machines use PATH
  lookup (`ProcessRunner.locate`); `SpotDLEngine.bundledBinary()` already
  looks in `Resources/Backend/`. No bundling decisions made yet.
- **Background execution**: strategy documented in `SyncScheduler.swift` —
  foreground Timer → BGTaskScheduler → possible helper in Phase 3.
  No helper installed in Phase 0.
- **Sandbox/filesystem**: security-scoped bookmarks via `MusicFolderAccess`;
  stale-bookmark and missing-folder paths handled.
- **Apple Music APIs**: Phase 4. No code yet; modular boundary reserved.
- **Packaging/signing**: ad-hoc local signing works; hardened runtime +
  notarization deferred to Phase 6.

## Roadmap

Phase 1 → done (this phase). Phase 2 → library + player UI. Phase 3 →
automation. Phase 4 → Apple Music. Phase 5 → power-user settings.
Phase 6 → bundling/signing/notarization.
