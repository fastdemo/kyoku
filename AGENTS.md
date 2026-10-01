# AGENTS.md — Kyoku contributor instructions

## Mandatory macOS .app build artifact

After every code change, always build the macOS `.app` and place the
resulting `.app` file in the project/repository folder.

- The `.app` must correspond to the latest code changes, not a stale build.
- Verify that the build succeeds before reporting the work complete.
- Report the exact path to the generated `.app` in the final response.
- This applies to every change, including small fixes, UI changes,
  refactors, tests that affect production code, and multi-file changes.
- Do not skip the `.app` build unless the user explicitly asks you not
  to build it.
