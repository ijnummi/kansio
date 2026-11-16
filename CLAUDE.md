# Kansio — project rules for Claude

A fast, Explorer-style file manager for macOS. **Speed is the main feature**; behaviour
is predictable (Explorer keyboard model, one global view setting); **never lose data**.
Full requirements live in the original brief; this file is the working summary.
Milestones: `PLAN.md`. Measurements: `PERF.md`. macOS gotchas: `docs/notes.md`.

## Build, test, run (no Xcode required)

Only the Command Line Tools are installed, so there is **no Xcode project, no
`xcodebuild`, no XcodeGen, no XCTest, no Instruments**. Everything is SwiftPM.

| Task | Command |
|---|---|
| Unit tests (FileSystemKit, swift-testing) | `Tools/test.sh` (passes the swift-testing macro plugin path the CLT needs) |
| Build the app bundle | `Tools/build-app.sh [release\|debug]` → `build/Kansio.app` (ad-hoc signed, Hardened Runtime) |
| Run the app | `open build/Kansio.app` (use `open`, not the bare binary, when testing TCC permissions) |
| Generate fixtures | `Tools/make-fixtures.sh` → `$TMPDIR/kansio-fixtures` (1k/10k/100k, unicode, symlinks, …) |
| Library benchmarks | `swift run -c release kansio-bench [--home] [--iterations N]` |
| App launch time | `build/Kansio.app/Contents/MacOS/Kansio --measure-launch` |
| App folder-open time + hitches | `build/Kansio.app/Contents/MacOS/Kansio --measure-open <folder>` (add `KANSIO_TRACE=1` to log each >16 ms iteration) |
| Scroll smoothness (dropped frames at 120 Hz) | `build/Kansio.app/Contents/MacOS/Kansio --measure-scroll <folder>` |
| Visual check without screen capture | `build/Kansio.app/Contents/MacOS/Kansio --snapshot <folder> <out.png>` (sidebar + list rows; prints status/error) |
| In-app self-test (history, mouse buttons, shortcuts, address bar, rename/new folder/trash/clipboard/Quick Look) | `Tools/self-test.sh` (opens a window for a few seconds; file ops only in a scratch folder under the fixtures, Trash → test folder via `KANSIO_TEST_TRASH`, private pasteboard) |
| Launch timeline | `KANSIO_TRACE=1 build/Kansio.app/Contents/MacOS/Kansio --measure-launch` |
| Debugger | `lldb -- "$(swift build --show-bin-path)/Kansio"` (the signed app refuses attach: Hardened Runtime) |
| CPU profile | run a measure mode (`KANSIO_REPEATS=60` for more iterations) and `sample <pid> 3 -file out.txt` |

After every meaningful change: build, run `Tools/test.sh`, fix **warnings as well as
errors** (the `ld: warning: search path …/CommandLineTools/Developer/Library/Frameworks
not found` line is a toolchain artifact, not ours). Never claim something works unless it
built and tests passed. Re-run the relevant measurement after any perf-sensitive change and
update `PERF.md`; if a number gets noticeably worse, say so and propose a fix.

## Stack

- Swift 6 language mode, strict concurrency; UI code is `@MainActor`.
- **AppKit** for everything performance-critical (`NSTableView`, `NSOutlineView`, address bar).
  SwiftUI only for low-traffic windows (Settings, About). Never SwiftUI `List`/`Table` for files.
- macOS 15 minimum. No App Sandbox. Hardened Runtime on. Outside the Mac App Store.
- **No third-party dependencies** without asking. Don't hand-edit project files we don't have;
  if Xcode is installed later, add an XcodeGen `project.yml` rather than a hand-made `.xcodeproj`.
- Layout:
  - `Packages/FileSystemKit/` — UI-free library: listing, model, sorting, (later) file ops, watching. Fully unit-tested.
  - `App/Kansio/` — AppKit app (executable target in the root `Package.swift`). `App/Resources/` — Info.plist, entitlements.
  - `Tools/` — scripts and the `kansio-bench` harness (`Tools/Bench`).

## Architecture rules (not optional)

1. Main thread only does UI. Listing, metadata, sizes, icons/thumbnails, file ops, search: off-main, delivered in batches.
2. Directory listing uses `getattrlistbulk()` (`BulkDirectoryLister`); `FoundationDirectoryLister` is the reference/fallback.
3. Progressive display: first batch on screen immediately; never wait for a whole large folder.
4. Virtualized `NSTableView` with reuse. Cells: no file-system calls, frames + autoresizing (no Auto Layout).
   **Never `reloadData()` for content updates** — refresh visible cells in place (`refreshRows`). Count changes go through
   `noteNumberOfRowsChanged()` inside a zero-duration `NSAnimationContext` (otherwise rows fade in; the self-test checks).
   Free big arrays off the main thread (`releaseOffMain`). Nothing that touches LaunchServices/IconServices on main.
5. Icons: lazy, cached per type (rasterized once), `QLThumbnailGenerator` only in icon view for visible items; cancel off-screen requests.
6. Live updates: FSEvents / `DispatchSource`, incremental diffs by `fileID` — never re-list + reload for one change.
7. Sorting on precomputed keys (`FolderContents.nameRank` + integer keys), off-main for big folders.
8. Cancellation everywhere: navigating away cancels listing/icon/size work (structured concurrency, cooperative checks).
   Blocking syscalls run on the `kansio.listing` GCD queue, not the Swift concurrency pool.
9. Slow volumes (SMB, external, iCloud): timeouts, spinner after 150 ms, UI never freezes.
10. `os_signpost` (`Signposts.*`, `OSSignposter`) around listing, sorting, icon loading, file ops.

### Performance budgets (measured, not guessed)

| Scenario | Target |
|---|---|
| Cold launch → window with home folder listed | < 300 ms |
| Open 1,000 items (local SSD) → fully displayed | < 50 ms |
| Open 10,000 items → first rows / full list | < 100 ms / < 300 ms |
| Open 100,000 items | first rows < 150 ms; UI responsive throughout |
| Scrolling | no dropped frames (60/120 Hz) |
| Sort 100,000 items by any column | < 200 ms, off main thread |
| Main-thread hitch | never > 16 ms |

## Safety rules

- Tests and experiments create/modify/delete files **only** inside a temp or fixtures dir
  (`TempDir` in tests refuses to delete anything outside `$TMPDIR/kansio-tests/`; `make-fixtures.sh`
  only touches a dir named `*kansio-fixtures*`). Never run file operations against real user folders.
  Read-only listing of real folders (e.g. `kansio-bench --home`) is fine.
- Tests that need a real Trash or a second volume use `TestVolume` (a temporary APFS disk image): its Trash is the
  image's own `.Trashes`, never the user's. Renames/moves use `renamex_np(RENAME_EXCL)` — plain `rename(2)` overwrites.
- **No permanent deletion** in P0/P1: delete = Move to Trash (`FileManager.trashItem`). Only exception (approved):
  a cross-volume move removes the source after the copy fully succeeded.
- Never write `.DS_Store` or anything else into browsed folders; view state lives in UserDefaults.
- iCloud/dataless files: metadata only; never read contents to display a listing (`FileItem.Flags.dataless`).
- Packages (`.app`, …) display and open as single items; "Show Package Contents" to browse inside.
- Symlinks/aliases shown distinctly, resolved on open (off-main), never followed recursively in size calculations.
- Errors (permission denied, ejected volume, vanished file) shown inline / in the operation panel; never crash, never leave half-done operations unreported.
- Unicode: keep names byte-exact as returned (don't normalize); compare with Swift `==` (canonical equivalence); sort with localized standard compare.
- Accessibility: standard AppKit controls so VoiceOver / full keyboard access work.

## Working agreement

- Ask before: adding dependencies, changing the stack, raising the minimum macOS, starting a P2 feature.
- Small, focused commits with clear messages. Keep `CLAUDE.md`, `PLAN.md`, `PERF.md`, `docs/notes.md` current.
- Explain macOS-specific gotchas (TCC, Hardened Runtime, NSFileCoordinator, …) in 2–3 sentences, in the reply or `docs/notes.md`.
- The user is an experienced developer new to macOS/AppKit: explain platform decisions briefly.
