# Plan — P0 (MVP)

Each milestone is small, ends with a commit, and is **done when** its criterion holds *and*
it built, `Tools/test.sh` passed, and the relevant measurements in `PERF.md` are within budget
(or the regression is reported with a proposed fix). P1/P2 only after P0 is solid.

## ✅ M0 — Scaffolding
git, SwiftPM layout (`Packages/FileSystemKit`, `App/Kansio`, `Tools/`), `CLAUDE.md`, this plan,
app bundle script with Hardened Runtime, swift-testing runner.
*Done when:* `Tools/build-app.sh` produces a signed `build/Kansio.app` and `Tools/test.sh` runs. **Done.**

## ✅ M1 — Core listing (FileSystemKit)
`BulkDirectoryLister` (`getattrlistbulk`) + `FoundationDirectoryLister` (reference/fallback), streaming
batches with cancellation, `FolderContents` (name ranks + integer-key re-sorts), `DirectoryLoader`
(progressive snapshots), fixtures, `kansio-bench`.
*Done when:* tests cover correctness vs. the FileManager oracle, errors, batching, cancellation, Unicode,
sorting vs. `localizedStandardCompare`; benchmarks recorded. **Done** — one open item: 100k name
ranking is 250 ms (budget 200 ms), see M3.

## ✅ M2 — Minimal details view
`NSTableView` with Name (icon) / Date Modified / Size, sortable + resizable columns, listing off-main
with progressive display, global persisted sort, Show Hidden Files (⇧⌘.), double-click/Enter opens,
Backspace goes up, measurement modes.
*Done when:* home folder shows on launch; 1k/10k/100k budgets met in-app; no >16 ms main-thread iterations. **Done.**

## ✅ M3 — Listing follow-ups (small, perf + correctness)
- ICU sort-key pre-sort + exact CF pass: 100k ranking 250 → 23 ms.
- Coalesced loading: folders up to ~10k items apply exactly once.
- Symlinks classified off the listing path (20 ms deadline): links to folders group/open as folders on the
  link's own path (Explorer); broken links/loops shown distinctly and explained inline when opened.
- Per-file icons (apps, custom icons, aliases, symlinks) off-main for visible rows, cancelled when scrolled away.
- Type column (localized kind per extension), sortable.
- `--measure-scroll`: display-link driven constant-speed scrolling with dropped-frame count.
*Done when:* 100k full list < 200 ms ✅ (125 ms); small folders apply once ✅; links to folders behave as folders ✅;
app icons visible ✅; Type column sortable ✅. **Done.**

## ✅ M4 — Main window shell + sidebar
`NSSplitViewController` (collapsible sidebar, ⌃⌘S) | details view; unified toolbar with the sidebar toggle.
Sidebar = source-list `NSOutlineView`: Favorites (Home, Desktop, Documents, Downloads, Applications; SF Symbols)
and Volumes (`VolumeList`, read off-main, refreshed on NSWorkspace mount/unmount/rename notifications).
Sidebar highlights the current folder; Go menu has Finder's shortcuts (⇧⌘H/D/O/A, ⌥⌘L). Ejecting the
volume being browsed navigates Home with an inline message.
*Done when:* clicking any sidebar item navigates ✅; mounting/ejecting a disk image updates the list without
relaunch ✅ (and Kansio doesn't keep the volume busy); no-permission folder shows inline error ✅. **Done.**
Follow-up: launch regression (+25 ms, 22–26 ms first-frame iteration) — see PERF.md.

## ✅ M5 — Navigation & history
`NavigationHistory` (FileSystemKit, unit-tested): Back/Forward stacks, no duplicates, bounded, per-entry selection,
entries on ejected volumes dropped. Toolbar Back/Forward/Up (right-click Back/Forward for the history list),
Go menu ⌘[ ⌘] ⌘↑ (macOS shows them localized, e.g. ⌘Ö ⌘Ä on Finnish layouts), Explorer's ⌥← ⌥→ ⌥↑, Backspace = Up,
**mouse buttons 4/5** handled at window level (work over list, sidebar, toolbar). Up is a recorded navigation and
selects the folder you came from; Back/Forward restore the selection you left (or the child folder).
*Done when:* history model unit-tested ✅; mouse buttons verified with synthesized button-4/5 events incl. with the
sidebar focused ✅; 60 rapid navigations never leave stale rows ✅ — all in `Tools/self-test.sh`. **Done.**
Also: launch follow-up from M4 (startup prefetch: rows in the first frame).

## M6 — Address bar
Breadcrumb segments (clickable); click empty area or ⌘L → editable text field; `~` expansion; path
autocompletion (listing off-main, cached per parent); Enter navigates; invalid path → inline error (no modal); Esc cancels.
*Done when:* tests for path parsing/expansion/completion; typing never blocks (completion off-main); inline error on bad path.

## M7 — Keyboard model (Explorer-style)
Enter open · F2 inline rename · Backspace up · ⌘⌫ Move to Trash · ⌘C/⌘X/⌘V (real cut/paste) ·
⇧⌘N new folder · Space Quick Look (`QLPreviewPanel`) · type-to-select · arrows/Shift/⌘ selection · ⇧⌘. hidden files.
*Done when:* every binding works in the details view and is listed in the menus; type-select matches by Finder order; Quick Look follows selection.
(Rename / trash / paste call the M9 engine; keys land here, operations there.)

## M8 — Open & Open With
Open with default app (`NSWorkspace.open`), packages open (apps launch), "Show Package Contents" enters bundles,
Open With submenu (`NSWorkspace.urlsForApplications(toOpen:)`, default first), "Other…" chooser.
*Done when:* works for files, apps, aliases and symlinks (resolved off-main); errors shown inline.

## M9 — File operations engine (FileSystemKit)
Copy (`copyfile` with `COPYFILE_CLONE` + `COPYFILE_ALL`, recursive), move (`rename(2)` on the same volume),
rename, new folder, new text file, Move to Trash (`FileManager.trashItem`, keep the resulting URL for undo).
Operations are queued and run off-main with progress (bytes/items), cancellation between files and within large
files (copyfile progress callback), and per-item error reporting. Signposts around each.
*Done when:* tests in temp dirs for every operation incl. cancellation mid-copy, permission errors, vanished
source, cross-volume copy (disk image fixture), APFS clone (instant, verified via same-size/fast).
**Decided (2026-11-16):** a cross-volume *move* is copy + verify + remove the source (approved exception to the
"no permanent deletion" rule — the data exists at the destination). The source is removed only after the whole
item copied successfully; on any error or cancel the source stays.

## M10 — Name conflicts
Replace / Skip / Keep both, with "apply to all". Keep-both naming: Explorer's "name (2).txt" (decided). Replace moves the replaced item to the Trash (never permanent delete). Folder-onto-folder = merge prompt.
*Done when:* tests for each choice, apply-to-all across a batch, replace-with-folder, case-only renames on case-insensitive APFS.

## M11 — Operations UI + clipboard
Non-blocking progress panel (multiple operations, Cancel each), inline errors with Retry/Skip, conflict sheet.
Clipboard: ⌘C/⌘X write file URLs to `NSPasteboard` (plus a private "cut" marker), ⌘V copies/moves into the current folder.
*Done when:* copying 10k files keeps the UI responsive (no hitches) and reports progress; cut+paste moves; paste from Finder works.

## M12 — Undo
`NSUndoManager` for rename, move, new folder, Move to Trash (undo = move back from the recorded Trash URL).
*Done when:* tests for each undo/redo through the engine; ⌘Z/⇧⌘Z in the Edit menu with action names.

## M13 — Live updates
Watch the current folder (FSEvents with file-level events, or `DispatchSource` vnode + re-list diff), coalesce
events, diff by `fileID`/name, apply inserts/removes/updates to the table without reload, keep selection and scroll.
*Done when:* tests for the diff algorithm; creating/deleting 1k files in a watched folder never re-lists the whole table per event and causes no hitches.

## M14 — Status bar
Item count, selection count, total selected size (sum off-main for large selections).
*Done when:* updates within one frame of selection change for 100k-item folders.

## M15 — Context menu
Open, Open With, Copy, Cut, Paste, Rename, Move to Trash, New Folder, New Text File, Copy Path, Show in Finder,
Get Info (Finder's info panel via Apple Events or our own minimal panel — decide).
*Done when:* every item works on single/multi/empty selection and validates (disabled when not applicable).

## M16 — Global view settings
Sort column, visible columns, column widths/order, hidden-files state: one setting everywhere, persisted in
UserDefaults, never `.DS_Store`.
*Done when:* settings survive relaunch and apply to every folder; no writes into browsed folders (verified with `fs_usage` during browsing).

---

### Proposed next milestone
**M6 (address bar)**. Small perf follow-up first or alongside: lighter cells (cold first-navigation hitch, PERF.md).
