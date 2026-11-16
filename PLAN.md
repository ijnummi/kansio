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

## ✅ M12 — Undo
One app-wide history (`FileUndo`, like Finder/Explorer) for **rename, move, copy, duplicate, new folder, new text
document, Move to Trash** — Edit ▸ Undo ⌘Z / Redo ⇧⌘Z with action names ("Undo Move to Trash"). FileSystemKit model:
an `UndoStep` is a list of `FileChange`s (renamed / moved / created / trashed); undo performs the inverses in reverse
order, redo performs the step again; "created" is undone by moving it **to the Trash** (never deleting) and redone by
taking it back out; "trashed" is undone by putting it back from its recorded Trash location (refused if the name is
now taken, or reported if the Trash was emptied). The engine records every placement (merge children included) and
every item trashed by Replace, so undoing a copy-with-Replace also restores the replaced item; undoing a move-merge
recreates the source folder; cross-volume moves move back via the engine. Steps run strictly in order on an actor.
Text editing (rename field, address bar) keeps its own undo. After undo/redo — and after any operation — every window
showing an affected folder updates just those items (`.kansioFilesChanged`).
*Done when:* tests for each undo/redo through the engine ✅ (12 tests, incl. real Trash on a disk image, cross-volume
move, copy-with-Replace, move-merge, blocked put-back); ⌘Z/⇧⌘Z in the Edit menu with action names ✅ — self-test
drives undo/redo for rename, trash, new folder, copy, move. **Done.** (⌘Z via the real menu is covered when the
self-test run is activated by macOS; the window → undo manager hookup is checked every run.)

## ✅ M13 — Live updates
`FolderWatcher` (FSEvents, file-level events, `WatchRoot`; stream created/torn down on its own queue): reports the
*names* of direct children that changed, `.rescan` when FSEvents dropped events, `.folderGone` when the folder itself
was moved/deleted; deeper changes are ignored; paths compared resolved (`/private/var`). The list re-reads just those
names (`LiveChanges.readChanges`, one getattrlist each, off-main) and applies them as a small model change
(`FolderContents.applying`) — no re-list, selection and scroll kept, and an external rename carries the selection
(same inode). Batches larger than 2,000 names or a rescan → one re-list + `LiveChanges.diff`. Events that arrive while
a folder is still listing are applied right after. If the folder on screen goes away: go to the nearest existing
ancestor and say why, inline. (FSEvents doesn't see changes other Macs make on SMB shares.)
*Done when:* tests for the diff algorithm ✅ (8 tests incl. a real FSEvents stream: create/remove/rename/modify, deeper
changes ignored, folder gone, 1,000-file burst coalesced, live-applied result == fresh listing); creating/deleting 1k
files never re-lists per event and causes no hitches ✅ (`--measure-live`: 1,000 creates reflected in ~210 ms, 1,000
deletes in ~90 ms, ~60 incremental batches, 0 re-lists, worst iteration 8.9–13.3 ms — except the very first rows ever
shown in an empty window, a cold first-use cost, see PERF.md). **Done.**

## ✅ M14 — Status bar
Explorer-style bar under the list: **"1,234 items (12 hidden)"** · **"3 items selected  12.3 MB"** (size of the selected
*files*; folders add none until folder sizes, P1) · **"45.6 GB available"** (volume free space, off-main with a 2 s
deadline, cached 10 s, refreshed after operations). Updated synchronously on every selection/rows change; selections
over 50k items are summed off-main ("Calculating…", stale results dropped). View ▸ Hide/Show Status Bar ⌘/ (global,
persisted). The window subtitle no longer repeats the counts.
*Done when:* updates within one frame of a selection change for 100k-item folders ✅ (`--measure-status`: Select All on
100k → count shown in 3 ms, summed size in 12 ms; single selection changes ≤ 1 ms; 0 hitches). **Done.**
Also fixed: a live update arriving before an operation's own result could drop the operation's selection (pasted items
not selected) — stale local changes are now re-applied on top of the current model.

## ✅ M15 — Context menu
Item menu: Open, Open With, Show Package Contents (one package), Quick Look, Cut, Copy, Paste, Duplicate, Rename (one
item), Move to Trash, Copy Path, Show in Finder, **Get Info**, New Folder, **New Text Document**. Empty area: New Folder,
New Text Document, Paste, Copy Path, Show in Finder, Get Info (of the current folder). Right-click selects the row.
**Get Info (⌘I) is our own small window** (decided: Finder's panel would need Apple Events — the Automation
permission prompt — and brings Finder forward): icon, kind, size, where, created/modified, permissions + owner, link
target / alias original; several items → counts and a combined size. Sizes are counted off-main
(`ItemStatistics`: `lstat`, symlinks never followed, hard links once, no crossing into other volumes, progress every
2,000 items, unreadable folders reported); closing the window cancels the count. Show in Finder goes through the
injectable `Opener` (the self-test records it instead of driving Finder).
*Done when:* every item works on single/multi/empty selection and validates ✅ (5 `ItemStatistics` tests; 21
self-test checks: item sets per context, enabled state via `validateMenuItem`, Show in Finder / Get Info / Copy /
Move to Trash / New Text Document invoked from the menu items in a scratch folder, Info values for a file, a folder,
a symlink, several items and the current folder, close cancels the count). **Done.**

## ✅ M16 — Global view settings
`ViewSettings` holds the one view setting for every folder: sort, **columns (order, widths, which are shown)**, hidden
files, status bar — in the app's UserDefaults (`view.*`), never in folders. Columns are our own setting now (replacing
NSTableView's per-table autosave): a new **Date Created** column (hidden by default); right-click the column header (or
View ▸ Columns) to show/hide columns (Name always shown) or **Reset Columns**; dragging/resizing a header writes the
setting. Every change goes through `ViewSettings` → notification → each list applies it (one path for local changes
and changes made elsewhere — a second window or the Settings window later). Values are sanitized on load (unknown or
duplicate columns dropped, missing ones added, widths clamped). Previous column widths from the NSTableView autosave
aren't migrated (one-time reset to the defaults); its old keys are removed.
*Done when:* settings survive relaunch and apply to every folder ✅ (self-test: header menu, View ▸ Columns, move,
resize, sort, hidden files, reset, saved values; a **second launch** checks the columns, sort, hidden files and status
bar came back); no writes into browsed folders ✅ — verified with an **FSEvents recorder** over the browsed fixtures
(all processes, recursive, file-level; a control write proves it's live) while browsing 9 folders, sorting by every
column both ways, toggling hidden files and columns, Select All, Get Info and Show Package Contents: **0 events**.
(`fs_usage` needs root, so it isn't part of the automated test; the manual command is in docs/notes.md.)
The self-test now uses its own defaults domain (`KANSIO_DEFAULTS_SUITE`), wiped before and after: it starts from
the defaults and never touches the user's settings (before M16 it toggled the real hidden-files/status-bar values).
**Done.** P0 is complete.

---

# Plan — P1 (after P0 is solid and benchmarks pass)

Order agreed 2026-11-16. Same rules as P0: each milestone ends with a commit, built, tests passing,
measurements within budget (or the regression reported with a fix). Ask before starting anything P2.

## ✅ P1-0 — Settings window
(Split out of P1-9 on 2026-11-16 so the tree's options have a home.) SwiftUI Settings window (⌘,) — low-traffic, so
SwiftUI is allowed — over `ViewSettings`/UserDefaults: one source of truth, changes apply live in every window (the
M16 notification path). Starts with the settings that exist: show hidden files, status bar, reset columns. Later
milestones add their own (P1-1: the tree options below; P1-6: folder sizes per volume; …).
*Done when:* settings apply live and persist; standard controls (VoiceOver, full keyboard access); self-test covers
each setting round-trip in the test defaults domain. ✅ Kansio ▸ Settings… (⌘,): Files (show hidden files), List (sort
by, order, columns, Reset Columns), Window (status bar). `SettingsModel` (ObservableObject) reads/writes `ViewSettings`
and republishes its change notification, so ⇧⌘., the header menu or another window update the open Settings window.
12 self-test checks (menu item, window opens with content, each setting → list + saved value, outside change → window,
close). Linking SwiftUI didn't change launch time (A/B, 10 runs each: ≈160 ms both). **Done.**

## ✅ P1-1 — Tree view in the navigation pane
Explorer-style folder tree (`NSOutlineView`) in the navigation pane. Decisions from the 2026-11-16 grilling:

**Layout.** Favorites stays flat (Desktop, Documents, Downloads, Applications — **Home leaves Favorites**); Favorites
entries are never expandable (one place where the tree lives, one watcher per folder). The second section is renamed
**Locations**: **Home** first, then each volume — each an expandable tree root. At launch only the root containing the
start folder is open. If the current folder is also a favorite, both are highlighted.

**What appears.** Folders only — files and packages never. Hidden folders follow the one global "Show Hidden Files"
(dimmed, toggled in place without collapsing). **Symlinks to folders**: shown with the link badge, expand on click
under the link's own path (same model as the list: `~/link/src`), always show a disclosure triangle (no check — the
target may be a dead mount; a broken one loses it on first expand), never auto-expanded except along the current
folder's own path; loops are harmless (expansion is per click; path limits end it with an inline error).
**Finder aliases and broken symlinks** are not shown.

**Expand to open folder** (setting, on by default): navigating anywhere (list, address bar, history, sidebar)
expands the tree to the current folder and highlights it. Uses the **most specific root** (anything under `~` reveals
under Home, never under Macintosh HD ▸ Users). **Auto-opened branches collapse again when left; hand-expanded ones
stay.** Each level lists off-main; spinner after 150 ms; the list never waits for the tree. At launch the reveal starts
after the list's first rows (launch budget unchanged). Inside a package or a hidden folder (not shown): reveal to the
deepest shown folder, highlight nothing. Setting off: nothing expands; the deepest *visible* ancestor gets a light
highlight.
**Network volumes**: never listed just to reveal — highlight the deepest *already-listed* row (the share root if
never expanded) — unless the setting **"Expand to open folder on network volumes"** (off by default) is on: then the
reveal works as on local volumes with a 2 s limit per level, stopping at the deepest level reached. External drives
and iCloud Drive count as local.

**Disclosure triangles.** Unexpanded local folders: rows on screen are checked off-main for "has a subfolder" (read
until the first subfolder, then stop; cancelled when scrolled off; cached until the watcher reports a change); no
triangle while unknown (no flicker). Network volumes: always a triangle (removed if empty when expanded), unless
**"Check for subfolders on network volumes"** (off by default) is on — then the same check with a 2 s limit.

**Mouse & keyboard.** Click a row: navigate at once (no expand). Click the triangle: expand/collapse without
navigating. Double-click: navigate + toggle. ↑/↓: move the highlight, navigate after a pause (**setting, default
250 ms; 0 = immediately**). →: expand / first child. ←: collapse / parent. Return: navigate and focus the list.
⌥-click a triangle: collapse all below / expand only levels already listed (never a recursive listing). Tab: between
tree and list. Back/Forward (buttons 4/5, ⌘[ ⌘]) as everywhere.

**Context menu (P1-1):** Open, Show in Finder, Copy Path, Get Info, New Folder (inside it, then rename in the tree).
Rename, Move to Trash and Cut/Copy/Paste on tree nodes are **P1-4** (with drag & drop). Until then Del/F2/⌘⌫ do nothing
while the tree has focus (they never fall through to the list).

**Live updates.** One recursive **directory-level** FSEvents stream per expanded root (no file events: FSEvents
reports which directory changed); changes to directories not listed in the tree are ignored (set lookup, off-main);
a listed node is re-read (subfolders only) ~0.3 s after its change and diffed by inode → rows inserted/removed/moved
in place; nothing collapses; a rename keeps the node's expansion (identity = inode); selection and scroll kept.
Mount/eject via `refreshVolumes()` (eject drops that root's stream). Network shares: FSEvents only sees this Mac's
changes (re-listed on expand). If the current folder is deleted, the list moves to the nearest ancestor and the tree
follows.

**Not persisted:** expanded branches aren't remembered across launches (Explorer-like; keeps launch fast; can be
added later — restored in idle time, never blocking launch).

**Settings added to P1-0:** Expand to open folder (on) · Expand to open folder on network volumes (off) · Check for
subfolders on network volumes (off) · Tree arrow-key navigation delay (250 ms).

**Budgets** (measured with a new `--measure-tree` and a `wide-10k` fixture: 10,000 empty subfolders):

| Scenario | Budget |
|---|---|
| Expand a node with 10,000 subfolders | no main-thread iteration > 16 ms; first children < 100 ms; complete < 300 ms |
| Auto-reveal 10 levels deep (`deep`), after the list completes | < 100 ms, no iteration > 16 ms |
| Scroll a 10k-child node with subfolder checks | no dropped frames at 120 Hz; off-screen checks cancelled |
| Another process creates/deletes 1,000 folders in an expanded node | applied in place in batches, nothing collapses, no iteration > 16 ms |
| 10,000-file copy elsewhere on the disk while the `/` stream runs | < 1 ms main-thread per batch (filtering off-main) |
| Cold launch | unchanged (< 300 ms); tree work starts after the first rows |

Known risk: inserting 10k children into `NSOutlineView` at once may exceed 16 ms → first screenful immediately, the
rest in chunks across frames (as the list does).
*Done when:* the budgets above are met (or the regression reported with a fix); a UI-free `FolderTree` model in
FileSystemKit is unit-tested (expand/collapse, auto-reveal and auto-collapse, most-specific root, inode diffs, link
loops, hidden toggle, network rules); self-test covers clicks, the arrow-key delay, ←/→, the context menu, a live
rename keeping its branch open, and reveal from list/address bar/history.
✅ **Done (2026-11-16).** `FolderTree` + `TreeDiff` (row plan: remove → moves via longest increasing run → insert;
nodes keep identity across renames) + `FolderTreeIO` (folder-only listing on its own queues, early-exit subfolder
check, deadlines) + `TreeWatcher` (directory-level FSEvents) in FileSystemKit — 11 unit tests (incl. 200 random
diffs replayed, a link to its own parent ending at the path limit, a real FSEvents stream). App: `SidebarViewController`
rewritten — self-drawing rows (`TreeCellView`, reused row views), reveal walks then expands (deepest first, ≤ 4 ms per
frame), selection/scroll and auto-collapse each in their own frame, collapsing > 500 children in chunks, watcher events
filtered and coalesced off-main (≤ 1 batch / 150 ms), rows redrawn only when their triangle changes. 33 self-test
checks; `--measure-tree` numbers in PERF.md — every budget met except the cold first navigation's one frame, which is
the file list's known cold cost (no tree work in it). Also: the four tree settings in Settings ▸ Navigation Pane.

## ✅ P1-2 — Pinned favorites
Pin any folder to Favorites (context menu, drag onto the sidebar), unpin, reorder; persisted in UserDefaults as
bookmark data (`URL.bookmarkData`), so pinned folders that are moved or renamed are still found. Missing targets shown dimmed, not removed.
*Done when:* pins survive relaunch and folder renames/moves; reorder by drag; unpin from context menu.
✅ **Done (2026-11-16).** `FavoriteList` + `Bookmarks` (FileSystemKit, 6 tests: pin/unpin/no duplicates, drop-index
moves, JSON, a bookmark following a rename and a move, deleted / in-the-Trash = missing). `FavoritesStore` (one for
all windows, `favorites.v1` in the app's defaults): defaults Desktop, Documents, Downloads, Applications; bookmarks
made and resolved off-main (never mounts); re-checked at launch, on activation and after Kansio's own file
operations; a folder that wasn't moved keeps the path it was pinned under (`/var` vs `/private/var`). Pin from the
list's menus (folders only), File ▸ Pin to Favorites ⌃⌘T (Finder's Add to Sidebar shortcut), the tree's menu, or by
dropping folders on Favorites (from the list, the tree or Finder; files refused inline). Reorder by dragging (or Move
Up/Down for the keyboard); unpin from the favorite's menu; Settings ▸ Restore Default Favorites. Missing targets stay,
dimmed; clicking one checks again, then says why nothing opens. The list and tree became drag *sources* for this —
into other apps only as a copy until P1-4 defines moves. 23 self-test checks + a relaunch check (the pinned folder is
renamed by the test script while Kansio isn't running).
## ✅ P1-3 — Tabs and multiple windows
⌘T new tab, ⌘W close, ⌃Tab / ⌃⇧Tab cycle, ⌘N new window. Each tab has its own folder, history and selection; the
sidebar/tree follow the active tab. Background tabs cancel their work and keep only their model.
*Done when:* switching tabs is instant (no re-list unless changed on disk); 20 open tabs cost no idle CPU; history
and mouse buttons act on the active tab; closing a tab cancels all its work.
✅ **Done (2026-11-16)** — with one open item (switch frame, below). Native macOS window tabs (`WindowManager`): each
tab is a window in a tab group with its own folder, history, selection and navigation pane; the tab bar, dragging tabs
out, Merge All Windows are AppKit's. File ▸ New Tab ⌘T (Home, like Explorer), New Window ⌘N (this folder, like
Explorer), Close Tab ⌘W, Close Window ⇧⌘W; Window ▸ Show Previous/Next Tab ⌃⇧Tab/⌃Tab; Open in New Tab / New Window
in the list's, tree's and favorites' menus; middle-click a folder → background tab. A tab that isn't shown (another
tab selected, minimized, app hidden — not merely covered) pauses: watcher stopped at an FSEvents id, listing and icon
loads cancelled, tree watchers and checks stopped; shown again, FSEvents replays what changed since that id (one
re-list + diff only if something did), a cut-short listing restarts, a tab opened in the background lists only when
first shown. Closing a tab stops all its work and frees it. Measured (`--measure-tabs`): 40 switches through 20 tabs
→ **0 re-lists**, Kansio's own work **0.1 ms** per switch; idle with 20 tabs **0.10–0.12 % CPU** after the window
server settles (= one tab). 2 FolderWatcher tests (replay since an event id; nothing to replay = no rescan); 22
self-test checks.
**Redesigned 2026-11-16 (user's choice from mockups):** the native tab bar sat *below* the address bar — the control
that picks the folder under the path it decides. Now **Explorer layout**: a custom tab strip fills the title-bar row
(next to the traffic lights; it's the window's only toolbar item, `.unifiedCompact`), and the row under it — Back,
Forward, Up, path, search — belongs to the selected tab. **One window** holds the tabs (`TabContainerViewController`:
switching hides one list view and shows another); the navigation pane, address bar and search follow the selected
tab. Tabs: click, ✕ / middle-click to close, drag to reorder, context menu (Close Tab, Close Other Tabs, Move Tab to
New Window), "+", files dropped on a tab go into its folder (hovering switches to it after 0.6 s). Merging windows
is not implemented. Switch now: median 7.8–13 ms (was 13–25), worst 23–35 ms, 3–9 of 40 switches just over 16 ms
(our part 4–5 ms: address bar + pane; the rest is AppKit drawing the shown view); idle with 20 tabs 0.05 % CPU.

## ✅ P1-4 — Drag and drop
Within the app (list ↔ list, list → tree/sidebar/tabs) and with other apps, including file promises (Mail, Photos).
Move vs copy follows Finder/Explorer rules (same volume = move, ⌥ = copy), through the M9 engine with progress,
conflicts and undo.
Also (moved from P1-1, decided 2026-11-16): **file operations on tree nodes** — Rename (F2, inline in the tree), Move
to Trash (Del/⌘⌫) and Cut/Copy/Paste — with a clear focus indicator so a keystroke never hits the pane you didn't
mean (a tree node can be a whole folder hierarchy); same conflict prompts, undo and operations panel as the list.
*Done when:* drag between folders, onto tree nodes and tabs works; drops from Finder/Mail/Photos land correctly;
undo works for drag-moves; dragging 10k items doesn't block the UI; rename/trash/paste on tree nodes work with undo.
✅ **Done (2026-11-16)** — with open items below. `FileDrop`: drops on the list (its folder, or a folder row), on
tree folders and on favorites (*on* a favorite = into it; *between* favorites = pin), from Kansio, Finder (file URLs)
and Mail/Photos (file promises: received into a temporary folder on the destination's volume, then placed by the copy
engine — conflicts asked, undo trashes them). Move or copy per Finder: ⌥ copies, ⌘ moves, otherwise move on the same
volume / copy across volumes, decided from the mounted-volume list (no disk access while dragging). Refused: into an
item itself or its subfolder; moving into the folder the items are already in. Every drop goes through the copy
engine (panel, conflicts, Retry/Skip/Stop, undo). The list and tree drag out with copy/move/link allowed (Finder
decides). Tree folders: F2 rename in place, Del / ⌘⌫ to the Trash, ⌘X/⌘C/⌘V — sharing the list's clipboard (a folder
cut in the tree dims in the list), with undo; never Home or a volume; the focused pane is the one with the accent
selection (AppKit's source-list/table focus). 20 self-test checks.
Measured (`--measure-drag`, 10,000 items): validation while dragging 0 ms after the first (3–4 ms for a drag from
Kansio — its folder and names are registered at drag start; 8 ms for another app's drag — the first 100 items are
checked, the rest once on drop, off-main); drop accepted in 1.3 ms (Kansio) / 120 ms (another app: reading 10,000
strings from the drag pasteboard). **Open:** (1) starting a drag of 10,000 items costs ~0.6 s — AppKit writing 10,000
items to the drag pasteboard; lazily provided items cut that to 43 ms but cost a pasteboard round trip per item when
read (44 s for 10k), so eager it is; (2) a real promise drop from Mail/Photos and dropping on a tab can't be automated
here — test by hand (tabs get redesigned next anyway).
## ✅ P1-5 — Search this folder and its subfolders
(Scope changed 2026-11-16: no Spotlight — the folder on screen and its subfolders, like Explorer's search box.)
A search field to the right of the address bar (⌘F, Edit ▸ Search…). Typing filters the folder at once — off-main,
on names folded once for case, diacritics and width (`FolderSearch.Index`, `memmem`; every word must match) and kept
in display order, so matches need no sorting; the index is built when the field gets focus. After a 250 ms pause the
subfolders are walked breadth-first on their own queue (no packages, no symlinks, same volume, hidden only when
shown) and matches stream in, each shown with where it is ("Report.txt in a/b"). Live updates pause during a search
and catch up from FSEvents afterwards. Esc (or emptying the field) restores the folder; navigating or opening a
folder result ends the search. Results support open, drag, copy, trash (results refresh); renaming a subfolder result
is disabled (do it in its folder).
*Done when:* filter keystroke → updated list < 50 ms for 100k items ✅ (`--measure-search`: 3–27 ms with the index
prepared on focus; 77 ms for a keystroke typed with no focus first — that one builds the index); subfolder results
stream in progressively and are cancellable ✅ (whole fixtures tree, 14,460 folders: 0.7 s, worst main-thread
iteration 5.5 ms; a search ended mid-walk stops it); Esc restores the folder view ✅. 5 unit tests, 15 self-test checks.

## P1-6 — Folder sizes ✅ (2026-11-17)
(Confirmed 2026-11-17.) **Done:** subfolders and packages measured one at a time after the listing (visible rows first),
"…" while pending; app-wide cache by real path; a recursive directory-level FSEvents stream started *since* the oldest
cached size replays what changed meanwhile, and per-path event ids mean only folders changed after their measurement are
counted again. Sorting by Size and the status bar use them. Settings: on for local volumes, separate toggle for network
volumes. Never downloads evicted iCloud folders. Without Full Disk Access, privacy-protected folders (Desktop,
Documents, Downloads, app containers, iCloud Drive, CloudStorage, media libraries) are never entered by background
sizing unless one is being browsed — a prompt would pop up unasked *and* block the walk. A watchdog gives up any walk
with no progress for 3 s (unknown protected place, hung volume) and continues on a fresh queue. Measured with
`--measure-sizes` (PERF.md).
Background, cached, cancellable recursive sizes (bulk listing; never follow symlinks; hard links counted once), with
a per-volume toggle (off by default for network volumes). Cache invalidated by the M13 watcher.
*Done when:* sizes fill in progressively without hitches; navigating away cancels; symlink loops are harmless;
network volumes are never scanned unless enabled.

## P1-7 — Extension column ✅ (2026-11-17)
**Done:** hidden by default (like Date Created); shows the extension as written in the name; sorts case-insensitively
on ranks of the distinct extensions (100k items: 13 ms). Header menu, View ▸ Columns, Settings.
(Narrowed 2026-11-17: Date Created and Extension only, **no Tags**. Date Created already shipped with M16.) An
Extension column (the last path extension, as Explorer shows it: "pdf", "gz" for `x.tar.gz`; empty for folders;
packages show theirs, "app"), sortable on a precomputed key, in the header menu / View ▸ Columns / Settings like the
others.
*Done when:* sorting 100k items by extension stays within budget (off-main, integer keys); visibility persists globally.

## ~~P1-8 — Icon/grid view with thumbnails~~
**Dropped 2026-11-17** (user): Kansio stays a details-view file manager. Listed under P4.

## P1-9 — Full Disk Access onboarding
(Confirmed 2026-11-17.)
(The Settings window itself moved to P1-0.) First-run onboarding explains Full Disk Access with a button to the right System Settings pane, and the app works
with reduced access when declined (inline permission-denied states everywhere, with a "Grant access…" action).
*Done when:* onboarding shows once and is reachable later (from Settings); every permission-denied state offers a way
to fix it.

---

### Proposed next milestone
Next: **P1-9 — Full Disk Access onboarding** (last P1 item).

---

# Status (review 2026-11-17)

**Done:** P0 (M0–M16) and P1-0…P1-5 plus the tab redesign. In short: fast bulk listing with progressive display; details
view with sortable, resizable, reorderable, hideable columns (Name, Date Modified, Date Created, Type, Size); address
bar (breadcrumbs, edit, ~, completion, inline errors) with Back/Forward/Up and history menus; mouse side buttons;
Explorer keyboard model; Open / Open With / Show Package Contents / aliases and symlinks; copy/move engine (clone,
temporary name + RENAME_EXCL, verified cross-volume moves) with conflicts, Retry/Skip/Stop, operations panel, quit
guard; Undo/Redo; live updates (FSEvents); status bar; context menus; Get Info; one global view setting; Settings
window; folder tree with expand-to-current-folder; pinned favorites (bookmarks); tabs in the title-bar row (one
window, paused background tabs) and multiple windows; drag and drop (list, tree, favorites, tabs, Finder, file
promises); search in the folder and its subfolders. 145 unit tests, ~285 self-test checks, 12 measurement modes.

**Known open items** (measured or found, not yet fixed):
- Starting a drag of 10,000 items: ~0.6 s of AppKit writing the drag pasteboard (P1-4).
- Tab switch: median 8–13 ms, but 3–9 of 40 switches just over 16 ms (AppKit drawing the shown view).
- First navigation after ~1 s idle: one 17–24 ms frame (cold, list-side; PERF "after M12").
- Big row-count changes (100k → 44k while searching): 17–20 ms frames (`noteNumberOfRowsChanged`).
- First search keystroke without focusing the field first: ~80 ms (builds the index).
- Not verified by automation: a real promise drop from Mail/Photos, a real drag onto a tab, ⌘Z through the menu with
  the app frontmost, `fs_usage` (replaced by an FSEvents recorder); real network shares were never expanded or listed.
- Tree: names truncate in a narrow pane (no horizontal scrolling); "Merge All Windows" went away with native tabs.

---

# Plan — P2 (still missing)

What a daily Explorer user would reach for and not find. Same rules as before: each item ends with a commit,
built, tested, measured; **ask before starting each one** (CLAUDE.md working agreement). Roughly in value order.

## P2-1 — Trash: browse, Put Back, per-volume
A Trash entry in the navigation pane (Explorer's Recycle Bin): lists `~/.Trash` and the mounted volumes'
`.Trashes/<uid>` together, with *original location* and *date deleted* columns where known — Kansio's own trash history
(every Move to Trash is recorded) plus Finder's put-back data when readable — and **Put Back** (move to the original
folder through the copy engine; conflicts asked). Needs Full Disk Access (`~/.Trash` is TCC-protected) → P1-9 first.
**Decision needed:** Empty Trash is permanent deletion — allow (with a confirmation, like Finder) or leave to Finder?
*Done when:* everything trashed in Kansio can be put back from the Trash view, across launches and volumes; tests use
`TestVolume` (never the user's Trash).

## P2-2 — Volumes: Eject, Connect to Server
Eject / unmount from the navigation pane (button on the row, context menu, ⌘E), off-main, with the reason shown inline
when a volume is busy ("in use by …"). **Connect to Server…** (⌘K): `smb://`, `afp://`, `nfs://`, WebDAV URLs mounted
via NetFS (system authentication and Keychain; recent servers remembered). Network roots then appear in Locations.
*Done when:* ejecting a busy volume explains why; a mounted share browses like any folder; nothing blocks the UI
while a server is slow or unreachable.

## P2-3 — Compress and Extract
Context menu **Compress** (zip, like Explorer/Finder) and **Extract** (zip, tar, tar.gz/bz2/xz, 7z if the system's
libarchive reads it — `bsdtar` ships with macOS) as operations in the File Operations panel: progress, cancel,
partial output removed on cancel, never overwriting ("Archive (2).zip", extracting into a new folder). No browsing
inside archives (P3).
*Done when:* 10,000 files compress/extract without hitches; cancel leaves nothing half-made; names and attributes
survive a round trip.

## P2-4 — Address bar and drag-and-drop completeness
- Breadcrumb **chevron menus**: clicking › between segments lists that folder's subfolders (Explorer) to jump sideways.
- **Drop onto a breadcrumb segment** = into that folder; drag a segment out as that folder.
- **Spring-loaded folders**: hovering a drag over a folder row, tree node or segment opens it after a moment.
*Done when:* a file can be moved into any ancestor or sibling folder by drag without leaving the view.

## P2-5 — Rename and selection the Explorer way
- While renaming, **Tab / ⇧Tab** commits and moves to the next / previous item's name (Explorer).
- **Multi-item rename** (select several, F2): one base name → "Holiday (1).jpg", "Holiday (2).jpg"… (Explorer's simple
  mode), undoable as one step. (A pattern-based renamer is P3.)
- **Select None**, **Invert Selection**, **Select by Pattern…** (`*.jpg`, `report*`), in Edit and the keyboard.
*Done when:* all undo as one step; a clash inside the batch never overwrites (RENAME_EXCL); 10k-item inversion is instant.

## P2-6 — Make Alias / Symlink, Refresh, column auto-fit
- **Make Alias** (and **Make Symbolic Link**) in the context menu; also as an ⌥⌘-drag target ("create alias here").
- **F5 / ⌘R Refresh**: re-list + diff (FSEvents doesn't see changes other Macs make on shares).
- **Size column to fit** (double-click a header divider) and **Size All Columns to Fit**.
*Done when:* refresh on a 100k folder applies only the differences; aliases resolve and show as aliases.

## P2-7 — Session restore and tab conveniences
Reopen the windows and tabs (folders, selection, scroll) that were open at quit (Settings switch, on by default);
**Duplicate Tab**; **Reopen Closed Tab** (⇧⌘T, last 10); drag a tab out of the strip into a new window.
*Done when:* relaunch shows the same windows/tabs without listing hidden tabs (they list when first shown); launch
budget unchanged.

---

# Plan — P3 (might be nice)

Worth doing once P2 is in; each needs a "yes" first. Grouped; not in order.

**Viewing**
- Preview / details pane (Explorer Alt+P / Alt+Shift+P): Quick Look or metadata of the selection beside the list.
- Group by (type, date modified ranges, size buckets) and column filter drop-downs (Explorer's header filters).
- Row size / font zoom (⌘+ / ⌘−, compact and comfortable densities).
- Flat view: all files below this folder in one list (Total Commander's branch view; search with "*" today).
- Hover tooltips with name, kind, size, dates.

**Getting around**
- Go-to-folder palette with frecency (zoxide / fman / Marta style): type a few letters of any recently used folder.
- Dual pane / split view (Dolphin F3, Total Commander) for copy-between-folders work.
- Drag a tab out to tear it off; Merge All Windows (lost with native tabs).

**File operations**
- Pattern / text-editor batch rename (PowerRename, ranger/yazi "rename in $EDITOR"), with a preview and one undo step.
- Right-button drag menu: Copy here / Move here / Create alias here / Cancel (Explorer).
- Copy to… / Move to… with a folder picker and recent destinations.
- Pause/resume in the operations panel; speed and time-left estimate.
- Compare folders (by name/size/date/content) and one-way sync, always through the copy engine and Trash.
- "New" submenu from a templates folder (Explorer's ShellNew: new document of a type).
- Checksums (SHA-256 etc.) in Get Info, computed off-main.
- Editable Get Info: permissions, owner, Locked, "hide extension" — with undo where possible.
- Browse archives as folders (read-only).

**Integration**
- Open in Terminal (Explorer 11 has it built in); open folder in an editor (configurable app).
- Git status: badge / column for files in a repository (Explorer 25H2 and Dolphin show it).
- iCloud / File Provider status badges and Download Now / Remove Download (metadata only; never reads contents).
- Share menu (`NSSharingServicePicker`: AirDrop, Mail, Messages).
- Services menu "Open in Kansio"; registering as a file viewer (`NSFileViewer`) so "Show in Finder"-style reveals can open in Kansio.
- Search filters: kind:, size:, date: (Explorer's query syntax) on top of P1-5's search.
- Empty Trash (if not done in P2-1).

---

# P4 — never ever

Out of scope by decision; listed so they don't creep back in.

- **Icon / grid / gallery / column (Miller) views** — details view only (decided 2026-11-17, P1-8 dropped).
- **Finder tags** (column, editing, filtering) — decided 2026-11-17 with P1-7.
- **Spotlight / whole-disk search** and any **custom indexer** — search is the folder and its subfolders (P1-5).
- **Permanent delete** outside an explicit Empty Trash (no Shift+Delete, no secure erase): never lose data.
- Electron, Tauri or any web view for the main UI; SwiftUI for file lists.
- Replacing the Desktop, Finder itself, or the system Open/Save panels; Finder Sync extensions.
- App Store sandboxing; Core Data or any database for listings.
- Remote file systems in-app (SFTP, S3, FTP, cloud APIs) — mount them with the system or a FUSE tool instead.
- Built-in viewers/editors (text, hex, image) — Quick Look and the user's apps do this.
- Embedded terminal panel (P3 keeps only "Open in Terminal").
- Scripting, AppleScript dictionary, plugins; theming beyond the system light/dark appearance.
- "Home"/recent-files feeds, libraries, AI summaries/actions, cloud-account features (OneDrive-style).
- Duplicate finder, disk-usage treemaps, Time Machine browsing — separate tools do these better.
