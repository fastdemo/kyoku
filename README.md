# Kyoku — Phase 0 Foundation

Native macOS SwiftUI music library + automated sync engine (in progress).
Phase 0 establishes the buildable foundation: Xcode project, DI, SQLite,
settings, logging, sandbox permissions, and the download-engine abstraction.

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
| Downloads | `Kyoku/Core/Downloads/` | `DownloadEngine` protocol, `ProcessRunner` (sole subprocess owner), `SpotDLEngine` stub |
| Filesystem | `Kyoku/Core/Filesystem/` | `MusicFolderAccess` (security-scoped bookmarks) |
| Sync | `Kyoku/Core/Sync/` | `SyncScheduler` (interval/backoff math; BG strategy documented in-file) |

Rules: no shell commands in views; all subprocesses go through
`ProcessRunner` (argv arrays, never shell strings); async work is
cancellable; queue state persists in SQLite.

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

Phase 1 → download engine (`resolveSource`/`downloadTrack` in `SpotDLEngine`).
Phase 2 → library + player UI. Phase 3 → automation. Phase 4 → Apple Music.
Phase 5 → power-user settings. Phase 6 → bundling/signing/notarization.
