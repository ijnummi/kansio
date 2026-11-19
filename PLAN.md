# Kansio — plan

**Rules for every item:** it ends with a commit, it built, `Tools/test.sh` and `Tools/self-test.sh` passed, and the
relevant measurements in `PERF.md` are within budget (or the regression is reported with a proposed fix). Ask before
starting anything new from the queue (CLAUDE.md working agreement). Numbers (M…, P1-…, P3-…) are kept because commits,
PERF.md and docs/notes.md refer to them.

The full write-ups of finished milestones (decisions, budgets, test lists) are in git history: `git show e24e25b:PLAN.md`
is the last long version. Measurements are in PERF.md.

---

## Done

**P0 — MVP (M0–M16)**
- **M0** Scaffolding: SwiftPM layout, signed app bundle (Hardened Runtime), swift-testing runner.
- **M1–M3** Listing: `getattrlistbulk` lister with progressive batches and cancellation; ICU sort keys (100k items in
  23 ms); per-file icons off-main; symlinks/aliases classified; Type column.
- **M2** Details view: sortable, resizable columns; global persisted sort; Show Hidden Files.
- **M4** Window shell: collapsible navigation pane with Favorites and Volumes (live mount/eject).
- **M5** History: Back/Forward/Up with per-entry selection; mouse buttons 4/5; history menus.
- **M6** Address bar: breadcrumbs, edit mode, `~`/relative/`file://` paths, folder completion, inline errors, dead-mount timeout.
- **M7** Explorer keyboard model: F2 rename, ⌘⌫/Del Trash, ⇧⌘N, ⌘C/⌘X, Quick Look, type-to-select, Home/End/PgUp/PgDn.
- **M8** Open / Open With / Show Package Contents; aliases and links resolved off-main; first context menu.
- **M9** Copy engine: clone / copyfile, temporary name + `RENAME_EXCL`, verified cross-volume moves; ⌘V, ⌘D, New Text Document.
- **M10** Name conflicts: Replace (to Trash) / Skip / Keep Both / Merge / Stop, apply-to-all.
- **M11** File Operations panel: progress, Cancel, Retry/Skip/Stop on errors, quit guard.
- **M12** App-wide Undo/Redo for every file operation (Trash-based, never deletes).
- **M13** Live updates: FSEvents, per-name incremental diffs, folder-gone handling.
- **M14** Status bar: counts, selection size, free space.
- **M15** Context menus; Kansio's own Get Info window (off-main sizes).
- **M16** One global view setting (columns, sort, hidden files, status bar); 0 writes into browsed folders (FSEvents recorder).

**P1**
- **P1-0** Settings window (SwiftUI, live, persisted).
- **P1-1** Folder tree in the navigation pane: expand to the open folder, auto-collapse, subfolder checks, directory-level
  FSEvents, network-volume rules, `wide-10k` budgets met.
- **P1-2** Pinned favorites (bookmarks; follow renames/moves; missing shown dimmed; reorder; restore defaults).
- **P1-3** Tabs in the title-bar row (Explorer layout), multiple windows, paused background tabs (0 re-lists on switch).
- **P1-4** Drag and drop: list, tree, favorites, tabs, Finder, file promises; Finder's move/copy rules; tree file operations.
- **P1-5** Search this folder and its subfolders (filter at once, subfolder walk streams in).
- **P1-6** Folder sizes: background, cached, FSEvents-invalidated, per-volume settings, never enters protected folders unasked.
- **P1-7** Extension column. (P1-8 icon view: dropped, see P4.)
- **P1-9** Full Disk Access onboarding and Grant Access… on every privacy refusal.

**P2**
- **P2-1** Trash view: all volumes' Trashes, Original Location / Date Deleted, Put Back, Delete Immediately, Empty Trash,
  network volumes (delete after asking, or a `.Trashes` folder there).
- **P2-3** Compress / Extract: bundled 7-Zip + libarchive, 7z/zip, Compress as/into, Extract Here/as/flat, verified, nothing half-made.
- **P2-8** List zoom (11–20 pt, ⌘+/⌘−/⌘0, ⌘-scroll, row density), navigation pane follows the text size; Most Used Folders (frecency).

**P3 items asked for (2026-11-19)**
- **P3-1** Tear tabs off into windows, drop on another window's strip; Merge All Windows; Move Tab to New Window.
- **P3-2** Right-button drag menu: Copy Here / Move Here / Create Alias Here / Cancel (Kansio's own tracking loop).
- **P3-3** Copy To ▸ / Move To ▸: Recent, Most Used, Choose Folder….
- **P3-4** Pause/Resume per operation; speed, time left (`TransferEstimator`: bytes + per-file cost, decayed trend), speed graph.
- **P3-5** Browse zip/7z/tar archives as read-only folders; extract single items by opening, ⌘C/⌘V, Copy To, drag out;
  opened archives appear in the tree.
- **P3-6** Open in Terminal (⌥⌘T) / Open in Editor (⌥⌘E), apps chosen in Settings ▸ Apps only.
- **P3-7** Search filters `size:` / `date:` in the search box, and a popover of controls kept in sync with the query.
- **Selection rectangle**: drag-select from blank space in rows, past the columns or below the rows (⌘ toggles, ⇧ adds).

214 unit tests, 32 self-test groups, 12 `--measure-*` modes.

---

## Open items in finished work

Found or measured, not fixed yet. Small ones can go along with the next queue item that touches the same code.

**Performance**
- Starting a drag of 10,000 items: ~0.6 s of AppKit writing the drag pasteboard (P1-4; lazy items cost 44 s on read).
- Tab switch: median 8–13 ms, but 3–9 of 40 switches just over 16 ms (AppKit drawing the shown view).
- First navigation after ~1 s idle: one 17–24 ms frame (cold, list side).
- Big row-count changes (100k → 44k while searching): 17–20 ms frames (`noteNumberOfRowsChanged`).
- First search keystroke without focusing the field first: ~80 ms (builds the index).
- A huge Trash isn't shown progressively (100k items ≈ 0.6 s).

**Behaviour**
- Archives: password-protected ones list but don't open or extract; Compress/Extract have no File-menu items and no
  Pause; opened archives aren't remembered across launches.
- Tree: names truncate in a narrow pane (no horizontal scrolling); expanded branches aren't restored at launch.
- Rename (M7 leftovers): slow click to rename; "change the extension?" confirmation.
- Search: no `kind:` filter yet (P3-7 did size and date).
- Finder's Put Back doesn't know items Kansio trashed (Kansio never writes `.DS_Store`). By design; listed so it isn't
  reported as a bug.

**Not verified by automation:** real mouse drags (tab tear-off, right-drag and the selection rectangle are driven with
posted events or callbacks), a real promise drop from Mail/Photos, a real NSOpenPanel choice, real app launches (the
opener is recorded), ⌘Z through the menu with the app frontmost, `fs_usage` (replaced by an FSEvents recorder), real
network shares.

---

## Queue — P2 (next; ask before each)

Roughly in value order for a daily Explorer user.

### P2-2 — Volumes: Eject, Connect to Server
- **Eject** from the navigation pane: an ⏏ button on ejectable volume rows, the volume's context menu, File ▸ Eject ⌘E
  (when a volume or something on it is selected). Off-main (`NSWorkspace.unmountAndEjectDevice` / DiskArbitration).
  If the volume is busy, say why inline ("in use by Photos"), from DiskArbitration's dissenter (the process ID → name).
  Kansio's own watchers and listings on that volume stop first, so Kansio is never the reason.
- **Connect to Server…** (⌘K): `smb://`, `afp://`, `nfs://`, WebDAV URLs mounted with NetFS (`NetFSMountURLAsync`:
  system authentication and Keychain). Recent servers remembered and offered. The mounted share shows in Locations and
  opens.
- *Done when:* ejecting a busy volume explains why; a mounted share browses like any folder; nothing blocks the UI while
  a server is slow or unreachable (connect has a Cancel and a timeout). Tests: eject on a `TestVolume` disk image,
  busy-volume reason with a process holding a file open there; connect is checked by hand (no server in tests).

### P2-4 — Address bar and drag-and-drop completeness
- Breadcrumb **chevron menus**: the › between segments lists that folder's subfolders (Explorer) to jump sideways;
  listed off-main, shown when ready.
- **Drop onto a breadcrumb segment** = into that folder (same move/copy rules and refusals as other targets; the
  right-drag menu too); drag a segment out as that folder.
- **Spring-loaded folders**: hovering a drag over a folder row, tree node or segment opens it after a moment (system
  spring-loading delay); leaving the drag goes back.
- *Done when:* a file can be moved into any ancestor or sibling folder by drag without leaving the view.

### P2-5 — Rename and selection the Explorer way
- While renaming, **Tab / ⇧Tab** commits and moves to the next / previous item's name (Explorer).
- **Multi-item rename** (select several, F2): one base name → "Holiday (1).jpg", "Holiday (2).jpg"… (Explorer's simple
  mode), undoable as one step. (A pattern-based renamer stays in Ideas.)
- **Select None** (⌥⌘A), **Invert Selection**, **Select by Pattern…** (`*.jpg`, `report*`) in the Edit menu.
- The M7 leftovers: slow click on a selected name starts a rename; changing the extension asks first.
- *Done when:* all undo as one step; a clash inside the batch never overwrites (`RENAME_EXCL`); inverting a 10k-item
  selection is instant.

### P2-6 — Make Alias / Symlink, Refresh, column auto-fit
- **Make Alias** in the context menu and File menu (reuses `Aliases.make` from P3-2: Finder's names, temporary name +
  `RENAME_EXCL`, undo to the Trash) and **Make Symbolic Link**; ⌥⌘ left-drag makes aliases (Finder's modifier).
- **F5 / ⌘R Refresh**: re-list + diff (FSEvents doesn't see changes other Macs make on shares); also for the tree node.
- **Size column to fit** (double-click a header divider) and **Size All Columns to Fit** (header menu).
- *Done when:* refresh on a 100k folder applies only the differences; aliases resolve and show as aliases.

### P2-7 — Session restore and tab conveniences
- Reopen the windows and tabs (folders, selection, scroll) that were open at quit (Settings switch, on by default).
  Hidden tabs list only when first shown; launch budget unchanged.
- **Duplicate Tab**; **Reopen Closed Tab** (⇧⌘T, last 10, with history).
- (Tearing a tab off into a window: done in P3-1.)
- *Done when:* relaunch shows the same windows/tabs without listing hidden tabs; launch < 300 ms.

### P2-9 — Open folders in Kansio from outside *(missing, proposed 2026-11-19)*
Kansio can't be handed a folder today: dropping one on the Dock icon or `open -a Kansio ~/x` does nothing.
- `application(_:open:)`: folders open in a new tab of the front window (files: their folder, with them selected);
  Dock-icon drops too (`CFBundleDocumentTypes` for folders, viewer role).
- Services menu **Open in Kansio** (`NSServices`), so Finder and other apps can send a folder.
- Optional (setting, off): offer Kansio as the default folder viewer where macOS allows it (`NSFileViewer` reveals);
  documented in docs/notes.md for what macOS does and doesn't let a third-party app take over.
- *Done when:* each entry point opens the right folder with the item selected, at launch and while running; tested
  with posted Apple Events / `open` in the self-test.

### P2-10 — Accessibility pass *(missing, proposed 2026-11-19)*
CLAUDE.md requires VoiceOver and full keyboard access, but several parts are custom-drawn and never checked:
self-drawing list and tree cells, the custom tab strip, the speed graph, the right-drag menu and the selection
rectangle.
- VoiceOver: every row reads its name, kind, size and date; tabs read as tabs (select, close, count); the operations
  row reads progress, speed and time left; the graph has a summary value.
- Keyboard: every mouse-only action has a keyboard path (tab reorder / move to new window, the drag menu's actions
  via Copy To / Move To / Make Alias, the filter popover).
- *Done when:* a self-test group walks the accessibility tree (`NSAccessibility` attributes) of each custom view and a
  manual VoiceOver run is noted in docs/notes.md.

### P2-11 — Distribution *(missing; only if Kansio will be given to others)*
Today it's signed with a local identity ("Kansio Local Signing") and installed by `Tools/install.sh`, which only works on
this Mac.
- Developer ID signing + notarization (`notarytool`) + stapling in a `Tools/release.sh`; a versioned, signed zip/DMG.
- Updates: either a manual "a new version is available" check, or Sparkle (a dependency, so ask first).
- *Done when:* a fresh Mac opens the downloaded app without a Gatekeeper warning, and Full Disk Access survives an update.

---

## Ideas — P3 (might be nice; each needs a "yes" first)

**Viewing**
- Preview / details pane (Explorer Alt+P / Alt+Shift+P): Quick Look or metadata of the selection beside the list.
- Group by (type, date ranges, size buckets) and column filter drop-downs (Explorer's header filters; could reuse
  `SearchQuery`'s size/date filters).
- Flat view: all files below this folder in one list (Total Commander's branch view).
- Hover tooltips with name, kind, size, dates.

**Getting around**
- Go-to-folder palette with frecency (zoxide / fman style), built on `FolderUsage`.
- Dual pane / split view (Dolphin F3, Total Commander) for copy-between-folders work.

**File operations**
- Pattern / text-editor batch rename (PowerRename, "rename in $EDITOR"), with a preview and one undo step.
- Compare folders (name/size/date/content) and one-way sync, always through the copy engine and Trash.
- "New" submenu from a templates folder (Explorer's ShellNew).
- Checksums (SHA-256 etc.) in Get Info, computed off-main.
- Editable Get Info: permissions, owner, Locked, hide extension — with undo where possible.
- Writing into archives (add / delete / rename inside a zip or 7z), through a temporary archive replaced only when complete.

**Integration**
- Git status badge / column for files in a repository (Explorer 25H2, Dolphin).
- iCloud / File Provider status badges and Download Now / Remove Download (metadata only).
- Share menu (`NSSharingServicePicker`: AirDrop, Mail, Messages).
- Localization (Finnish first): menus and messages are English-only today; shortcuts already follow the keyboard layout.

---

## P4 — never

Out of scope by decision; listed so they don't creep back in.

- **Icon / grid / gallery / column (Miller) views** — details view only (decided 2026-11-17, P1-8 dropped).
- **Finder tags** (column, editing, filtering) — decided 2026-11-17 with P1-7.
- **Spotlight / whole-disk search** and any **custom indexer** — search is the folder and its subfolders (P1-5).
- **Permanent delete** outside the approved cases (Empty Trash, Delete Immediately in the Trash view, network volumes
  after asking): no Shift+Delete, no secure erase.
- Electron, Tauri or any web view for the main UI; SwiftUI for file lists.
- Replacing the Desktop, Finder itself, or the system Open/Save panels; Finder Sync extensions.
- App Store sandboxing; Core Data or any database for listings.
- Remote file systems in-app (SFTP, S3, FTP, cloud APIs) — mount them with the system or a FUSE tool instead.
- Built-in viewers/editors (text, hex, image) — Quick Look and the user's apps do this.
- Embedded terminal panel (Open in Terminal only, P3-6).
- Scripting, AppleScript dictionary, plugins; theming beyond the system light/dark appearance.
- "Home"/recent-files feeds, libraries, AI summaries/actions, cloud-account features (OneDrive-style).
- Duplicate finder, disk-usage treemaps, Time Machine browsing — separate tools do these better.
