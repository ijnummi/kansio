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
| Unit tests (FileSystemKit, swift-testing) | `Tools/test.sh` (passes the swift-testing macro plugin path the CLT needs); one suite: `Tools/test.sh --filter FolderSizeTests` |
| Build the app bundle | `Tools/build-app.sh [release\|debug]` → `build/Kansio.app` (a symlink to `build/app.noindex/Kansio.app`, which Spotlight skips; Hardened Runtime; bundles `7zz`; signed with the local identity "Kansio Local Signing" from `Tools/signing-identity.sh`, so Full Disk Access survives rebuilds) |
| Install to /Applications | `Tools/install.sh` (refuses a stale build or a running copy; the old copy goes to the Trash and is unregistered from LaunchServices) |
| App icon | `swift Tools/make-icon.swift [preview.png]` → `App/Resources/AppIcon.icns` (drawn in code; commit the .icns) |
| 7-Zip (P2-3) | `Tools/fetch-7zip.sh` → builds `7zz` from the pinned 7-Zip source release (SHA-256 checked, cached in `build/7zip-<ver>/`); build-app.sh runs it. Unit tests find it there (`KANSIO_7ZZ` overrides) |
| Run the app | `open build/Kansio.app` (use `open`, not the bare binary, when testing TCC permissions) |
| Generate fixtures | `Tools/make-fixtures.sh` → `$TMPDIR/kansio-fixtures` (1k/10k/100k, unicode, symlinks, `wide-10k` = 10,000 subfolders, …) |
| Library benchmarks | `swift run -c release kansio-bench [--home] [--iterations N]` (`--trash`: only the Trash listing table) |
| App launch time | `build/Kansio.app/Contents/MacOS/Kansio --measure-launch` |
| App folder-open time + hitches | `build/Kansio.app/Contents/MacOS/Kansio --measure-open <folder>` (add `KANSIO_TRACE=1` to log each >16 ms iteration) |
| Compress + extract (each engine; `KANSIO_ARCHIVE_FORMAT=zip`) | `build/Kansio.app/Contents/MacOS/Kansio --measure-archive $TMPDIR/kansio-fixtures/flat-10k` |
| File-operation responsiveness (copies a fixtures folder, cloning off) | `build/Kansio.app/Contents/MacOS/Kansio --measure-copy $TMPDIR/kansio-fixtures/flat-10k` |
| Live updates (another process creates/deletes 1,000 files in the folder on screen) | `build/Kansio.app/Contents/MacOS/Kansio --measure-live $TMPDIR/kansio-fixtures` |
| Search (keystrokes in 100k items, whole-tree search, cancel) | `build/Kansio.app/Contents/MacOS/Kansio --measure-search $TMPDIR/kansio-fixtures` (`KANSIO_SEARCH_COLD=1`: no index prepared) |
| Folder sizes (fixtures root, wide-10k sorted by size, cache on return, cancel) | `build/Kansio.app/Contents/MacOS/Kansio --measure-sizes $TMPDIR/kansio-fixtures` |
| Drag and drop of 10,000 items (drag start, validation, drop) | `build/Kansio.app/Contents/MacOS/Kansio --measure-drag $TMPDIR/kansio-fixtures` |
| Tabs (20 tabs: switch cost, re-lists, idle CPU) | `build/Kansio.app/Contents/MacOS/Kansio --measure-tabs $TMPDIR/kansio-fixtures` (`KANSIO_TABS=n`, `KANSIO_IDLE_WAIT=s`) |
| Navigation-pane tree (deep reveal, expand/scroll/collapse `wide-10k`, live burst, copy under a watched root) | `build/Kansio.app/Contents/MacOS/Kansio --measure-tree $TMPDIR/kansio-fixtures` (own settings domain; `KANSIO_TRACE=1` names the tree work in each >16 ms iteration) |
| Status bar responsiveness (Select All / selection changes) | `build/Kansio.app/Contents/MacOS/Kansio --measure-status $TMPDIR/kansio-fixtures/flat-100k` |
| Scroll smoothness (dropped frames at 120 Hz) | `build/Kansio.app/Contents/MacOS/Kansio --measure-scroll <folder>` |
| Visual check without screen capture | `build/Kansio.app/Contents/MacOS/Kansio --snapshot <folder> <out.png>` (sidebar + list rows; prints status/error) |
| In-app self-test; `Tools/self-test.sh --only settings,tree` runs just those groups, no relaunch (names: `groups` in `SelfTest.swift`; a wrong name lists them) (history, mouse buttons, shortcuts, address bar, file ops, opening, conflicts, undo, live updates, status bar, context menu + Get Info, view settings, folder sizes, Full Disk Access + permission errors, Trash view + network deletion, archives, no writes into browsed folders) | `Tools/self-test.sh` (opens a window twice — the second launch checks the view settings came back; own defaults domain via `KANSIO_DEFAULTS_SUITE`, never the user's settings; file ops only in a scratch folder under the fixtures, Trash → test folder via `KANSIO_TEST_TRASH` (the Trash view, Empty Trash and Delete Immediately see only that folder), a scratch folder acting as a network volume via `KANSIO_TEST_NETWORK`, private pasteboard, recorded opener; `KANSIO_ENV=KANSIO_INFO_PNG=<out.png>` also renders the Info window, `KANSIO_FDA_PNG` the Full Disk Access window, `KANSIO_SETTINGS_PNG` each Settings pane) |
| Launch timeline | `KANSIO_TRACE=1 build/Kansio.app/Contents/MacOS/Kansio --measure-launch` |
| Debugger | `lldb -- "$(swift build --show-bin-path)/Kansio"` (the signed app refuses attach: Hardened Runtime) |
| CPU profile | run a measure mode (`KANSIO_REPEATS=60` for more iterations) and `sample <pid> 3 -file out.txt` (may be refused for the hardened app; then count with the measure modes' trace notes) |

After every meaningful change: build and run the **focused** tests for what changed (`Tools/test.sh --filter <Suite>`,
`Tools/self-test.sh --only <group>`); run the **full** suites (`Tools/test.sh`, `Tools/self-test.sh`) once at the end
of a task or main step, before committing it. Fix **warnings as well as errors** (the `ld: warning: search path …/CommandLineTools/Developer/Library/Frameworks
not found` line is a toolchain artifact, not ours). Never claim something works unless it
built and tests passed. Re-run the relevant measurement after any perf-sensitive change and
update `PERF.md`; if a number gets noticeably worse, say so and propose a fix.

## Stack

- Swift 6 language mode, strict concurrency; UI code is `@MainActor`.
- **AppKit** for everything performance-critical (`NSTableView`, `NSOutlineView`, address bar).
  SwiftUI only for low-traffic windows (Settings, About). Never SwiftUI `List`/`Table` for files.
- macOS 15 minimum. No App Sandbox. Hardened Runtime on. Outside the Mac App Store.
- **No third-party dependencies** without asking. Approved: 7-Zip's `7zz` (P2-3), built from source at a pinned
  version and bundled as a separate program (LGPL; its licence ships in the app's Resources). macOS's libarchive is
  used through `dlsym` (no SDK headers). Don't hand-edit project files we don't have;
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
- Archives (P2-3) go through `ArchiveOperations`: a temporary name/folder in the destination, renamed into place only
  when complete; the originals of "Compress into" go to the Trash only after the archive was checked against them.
- Copies/moves go through `CopyEngine` only (temporary name + `RENAME_EXCL` placement, clone when possible, source of a
  cross-volume move removed only after a verified copy).
- Tests that need a real Trash or a second volume use `TestVolume` (a temporary APFS disk image): its Trash is the
  image's own `.Trashes`, never the user's. Renames/moves use `renamex_np(RENAME_EXCL)` — plain `rename(2)` overwrites.
- **No permanent deletion** except these approved cases: a cross-volume move removes the source after the copy fully
  succeeded; and (P2-1) Empty Trash, Delete Immediately in the Trash view, and Move to Trash on a network volume (which
  has no Trash) — each only after a confirmation, and only through `TrashActions.deletePermanently`/`empty`, which refuse
  anything not strictly inside the given Trash folders / network volume. Everything else: Move to Trash (`TrashService`).
- Never write `.DS_Store` or anything else into browsed folders; view state lives in UserDefaults (`ViewSettings`, one global
  setting; the self-test's FSEvents recorder checks that browsing causes 0 events in browsed folders).
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
