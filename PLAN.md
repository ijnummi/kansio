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

## ✅ M6 — Address bar
Full-width bar under the toolbar (titlebar accessory). Breadcrumbs (volume first, leading segments fold into a "…"
menu when too long); clicking a segment navigates. Click empty space / ⌘L / ⇧⌘G → edit mode with the path selected.
Accepts absolute, `~`, `~user`, relative, quoted and `file://` paths; folder completions (case/diacritic-insensitive,
Finder order, off-main, cached 5 s) with ↓/↑, Tab to complete, Enter to go; a file path opens its folder with the file
selected; bad paths show an inline red error and stay editable; dead mounts time out after 3 s ("isn't responding");
Esc closes suggestions, then cancels. Also: lighter self-drawing cells (perf follow-up from M5).
*Done when:* path parsing/expansion/completion unit-tested ✅; typing never blocks (completion + checks off-main) ✅;
inline error on bad path ✅ — plus 14 address-bar checks in `Tools/self-test.sh`. **Done.**
Not yet: Explorer's chevron dropdown of subfolders on each separator (candidate for P1).

## ✅ M7 — Keyboard model (Explorer-style)
Enter open · **F2** inline rename (base name selected, extension not; Enter/click-away commits, Esc cancels; a clash
shows an inline error and reopens the editor) · Backspace up · **⌘⌫ / Delete (fn⌫)** Move to Trash (selection stays
where the items were) · **⇧⌘N** New folder ("New folder", "New folder (2)"…, then rename right away) · **⌘C/⌘X** file
URLs to the clipboard, cut items dimmed · **Space** Quick Look (follows the selection; ↑↓ in the panel move it) ·
type-to-select (Space continues a name being typed) · **Home/End/Page Up/Page Down** move the selection (⇧ extends) ·
⇧⌘. hidden files. Rename/new folder/trash run off-main via `FileOperations` (never overwrite: `RENAME_EXCL`; trash via
`FileManager.trashItem`), and results are applied as small model changes (`FolderContents.applying`), not re-lists.
*Done when:* every binding works and is in the menus ✅; type-select in Finder order ✅; Quick Look follows selection ✅ —
covered by unit tests (incl. real Trash on a disk image) and `Tools/self-test.sh` (scratch folder + test trash).
**Done.** Deferred: ⌘V (needs the copy/move engine, M9); slow-click-to-rename; "change extension?" confirmation.

## ✅ M8 — Open & Open With
Enter / double-click / ⌘O open with the default app (several files: each one); apps launch; folders, links to
folders (link path kept) and **Finder aliases** (resolved off-main, never mounting or showing UI; folder aliases go to
the original) navigate; broken links/aliases explain inline. **Open With ▸** (File menu and context menu): default app
first, other capable apps (versions shown for duplicates), "Other…" (app chooser sheet) — computed off-main per file
type, prefetched on selection, filled in live if still loading. **Show Package Contents.** First **context menu**
(Open, Open With, Show Package Contents, Quick Look, Cut/Copy/Paste, Rename, Move to Trash, Copy Path, Show in Finder,
New Folder; right-click selects the clicked row). Launch errors are shown inline ("No app is set to open… use Open With
▸ Other…"). New `linkToFile` flag: links to files open immediately.
*Done when:* works for files, apps, aliases and symlinks ✅; errors inline ✅ — self-test with a recording opener
(no real app launches). **Done.**

## ✅ M9 — File operations engine (FileSystemKit)
`CopyEngine`: copy (same APFS volume → `clonefile(2)`, instant and space-free; otherwise `copyfile(3)` COPYFILE_ALL,
recursive — data, metadata, xattrs, ACLs, tags, dates; symlinks copied as symlinks), move (same volume →
`renamex_np(RENAME_EXCL)`; across volumes → copy, verify item count + bytes, place, then remove the source — kept if
anything failed). Every item is copied to a hidden temporary name and renamed into place with `RENAME_EXCL`, so a
partial item never appears under its real name and nothing is ever overwritten. Planning pass for totals, throttled
progress, cancellation between files and inside large files (copyfile callback), per-item errors (skip the file,
carry on, report). Conflict hook (`Resolver`: replace → existing item goes to the Trash / skip / keep both / stop);
default until M10: skip and report. Same-folder copies are named "name - Copy.ext", "name - Copy (2).ext" (Explorer).
Also: New Text Document ("New Text Document.txt"). App: **⌘V** paste (Kansio or Finder clipboard; after ⌘X it moves
and the clipboard is spent), **⌘D** Duplicate, **⌘.** Stop File Operation, inline progress line ("Copying 3 items…
45%"), result summary, pasted items selected.
*Done when:* tests in temp dirs / disk images for every operation ✅ — tree copy with metadata (clone and copyfile paths),
APFS clone verified by free space, conflicts (skip default, keep both, replace via Trash, stop), same-volume move keeps
the inode, cross-volume move removes the source only after a verified copy and keeps it when a file is unreadable,
folder-into-itself, vanished source, read-only destination, cancel inside a 200 MB file leaves nothing behind,
monotonic progress. **Done.** Next: the conflict dialog (M10) and the operations panel (M11) on top of this engine.

## ✅ M10 — Name conflicts
Engine: **Replace** (the existing item goes to the Trash — never a permanent delete; refused if that folder contains the
source), **Skip**, **Keep both** ("name (2).ext", folders "Folder (2)"), **Merge** for folder onto folder (contents go
into the existing folder, every clash inside is asked about again, nested merges included; after a move the source
folder is removed only if it ended up empty), **Stop**. `ConflictPolicy`: "apply to all" remembers the answer for the
rest of the operation, separately for folder clashes and file clashes. App: conflict sheet with both items' size and
date — files: Replace (default) / Keep Both / Skip / Stop; folders: Merge (default) / Keep Both / Skip / Replace / Stop;
"Do this for all remaining conflicts"; Esc = Stop; sheets queue one at a time.
*Done when:* tests for each choice ✅, apply-to-all across a batch ✅, replace-with-folder (both directions) ✅, case-only
name clash on case-insensitive APFS ✅ (plus copy/move merges, cross-volume merge, stop inside a merge, replace-ancestor
guard) — and the real sheets driven by `Tools/self-test.sh`. **Done.**

## ✅ M11 — Operations UI + clipboard
App-wide `OperationCenter` + **File Operations panel** (non-activating utility panel; never steals focus): one row per
operation — title, progress bar (indeterminate while counting), "12 MB of 40 MB · 2 of 3 items · current file",
Cancel. Appears when an operation runs > 0.5 s (quick ones never flash it) or at once when an item fails; hides when
all are done; Window ▸ File Operations reopens it. Engine **error hook**: a failing item turns its row into an inline
error with **Retry / Skip / Stop** while the engine waits (Retry discards the failed attempt). Conflict sheets (M10).
⌘. stops this window's operations. Quitting with operations running asks first (Keep Running / Stop and Quit).
Clipboard (M7/M9): ⌘C/⌘X file URLs + private cut marker, ⌘V copies/moves; paste from Finder works.
*Done when:* copying 10k files keeps the UI responsive and reports progress ✅ (`--measure-copy`: 10k files / 39 MB,
cloning off, ~1.3 s, ~29 progress updates, worst main-thread iteration 10.7–13.9 ms, 0 hitches); cut+paste moves ✅;
paste from Finder works ✅ (file URLs on the general pasteboard). Panel, Retry, Skip and Cancel driven by
`Tools/self-test.sh`. **Done.**

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

# Plan — P1 (after P0 is solid and benchmarks pass)

Order agreed 2026-11-16. Same rules as P0: each milestone ends with a commit, built, tests passing,
measurements within budget (or the regression reported with a fix). Ask before starting anything P2.

## P1-1 — Tree view in the navigation pane
Explorer-style folder tree (`NSOutlineView`) in the sidebar, lazily expanded: children are listed only when a node
is expanded (off-main, same `DirectoryLoader`), folders only (packages and files never appear), symlinks to folders
shown but never auto-expanded recursively. The tree follows the current folder (expands to and highlights it) and
stays correct via the M13 watcher (create/rename/move/delete, inside and outside the app).
**Decided (2026-11-16):** Explorer layout — Favorites stays flat; **Home** and each **volume** become expandable tree
roots in the same navigation pane; network volumes never auto-expand. If the current folder is also a favorite, both
are highlighted.
**Open (decide when P1 starts):** auto-expand to the current folder ("Expand to open folder") — proposal: on by default
with a Settings switch; auto-opened branches collapse again when left, hand-expanded ones stay; never auto-list a
network volume. Also: should Favorites entries themselves be expandable?
*Done when:* expanding a 10k-subfolder node never blocks the UI; navigating anywhere (list, address bar, history)
reveals that folder in the tree; changes on disk show up without collapsing/rebuilding the tree; no symlink loop
can expand forever; tested model for expand/collapse/sync.

## P1-2 — Pinned favorites
Pin any folder to Favorites (context menu, drag onto the sidebar), unpin, reorder; persisted in UserDefaults as
bookmark data (`URL.bookmarkData`), so pinned folders that are moved or renamed are still found. Missing targets shown dimmed, not removed.
*Done when:* pins survive relaunch and folder renames/moves; reorder by drag; unpin from context menu.

## P1-3 — Tabs and multiple windows
⌘T new tab, ⌘W close, ⌃Tab / ⌃⇧Tab cycle, ⌘N new window. Each tab has its own folder, history and selection; the
sidebar/tree follow the active tab. Background tabs cancel their work and keep only their model.
*Done when:* switching tabs is instant (no re-list unless changed on disk); 20 open tabs cost no idle CPU; history
and mouse buttons act on the active tab; closing a tab cancels all its work.

## P1-4 — Drag and drop
Within the app (list ↔ list, list → tree/sidebar/tabs) and with other apps, including file promises (Mail, Photos).
Move vs copy follows Finder/Explorer rules (same volume = move, ⌥ = copy), through the M9 engine with progress,
conflicts and undo.
*Done when:* drag between folders, onto tree nodes and tabs works; drops from Finder/Mail/Photos land correctly;
undo works for drag-moves; dragging 10k items doesn't block the UI.

## P1-5 — Filter-as-you-type and Spotlight search
⌘F filters the current folder as you type (off-main on precomputed keys; 100k items stay responsive). A "Search
everywhere" mode uses Spotlight (`NSMetadataQuery`) with results streamed into the details view; no custom indexer.
*Done when:* filter keystroke → updated list < 50 ms for 100k items; Spotlight results stream in progressively and
are cancellable; Esc restores the folder view.

## P1-6 — Folder sizes
Background, cached, cancellable recursive sizes (bulk listing; never follow symlinks; hard links counted once), with
a per-volume toggle (off by default for network volumes). Cache invalidated by the M13 watcher.
*Done when:* sizes fill in progressively without hitches; navigating away cancels; symlink loops are harmless;
network volumes are never scanned unless enabled.

## P1-7 — Extra columns
Date Created, Extension, Tags (from metadata, no content reads). Show/hide columns from the header context menu;
part of the global view setting (M16).
*Done when:* each is sortable on precomputed keys within budget; column visibility persists globally.

## P1-8 — Icon/grid view with thumbnails
`NSCollectionView` grid; `QLThumbnailGenerator` only for visible items, cancelled when scrolled away, cached;
type icons until a thumbnail arrives. The view mode is part of the one global view setting.
*Done when:* scrolling a 10k-image folder drops no frames; thumbnails never block the main thread; switching views
keeps selection.

## P1-9 — Settings window and Full Disk Access onboarding
SwiftUI Settings window for the options introduced so far (hidden files, folder sizes per volume, default view…).
First-run onboarding explains Full Disk Access with a button to the right System Settings pane, and the app works
with reduced access when declined (inline permission-denied states everywhere, with a "Grant access…" action).
*Done when:* settings apply live and persist; onboarding shows once and is reachable later; every permission-denied
state offers a way to fix it.

---

### Proposed next milestone
**M12 (Undo)**.
