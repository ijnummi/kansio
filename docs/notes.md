# macOS notes and gotchas

Short explanations of platform-specific decisions. Newest at the bottom of each section.

## Toolchain (no Xcode)

- **SwiftPM instead of Xcode/XcodeGen.** Only the Command Line Tools are installed, and both
  `xcodebuild` and XcodeGen-generated projects need full Xcode. The app is an executable target;
  `Tools/build-app.sh` assembles `Kansio.app` (Info.plist + binary) and signs it. If Xcode is
  installed later, an XcodeGen `project.yml` can be added without changing the source layout.
- **Tests use swift-testing, not XCTest.** The CLT ship `Testing.framework` but no XCTest. SwiftPM
  doesn't find the swift-testing macro plugin under the CLT on its own, so `Tools/test.sh` passes
  `-Xswiftc -plugin-path …/usr/lib/swift/host/plugins/testing`.
- **No Instruments / `xctrace`.** Signposts (`OSSignposter`) are in place for when Xcode is available.
  Meanwhile: the app's `--measure-*` modes, the run-loop hitch monitor, and `/usr/bin/sample` for CPU profiles.

## Signing, Hardened Runtime, TCC

- **Hardened Runtime** (`codesign -o runtime`) is required for notarization. It blocks code injection
  (`DYLD_*` env vars, unsigned libraries, JIT) unless explicitly allowed by entitlements; we need no
  exceptions. Local builds are ad-hoc signed (`--sign -`); set `KANSIO_SIGN_IDENTITY` for Developer ID.
- **TCC remembers permissions per code signature.** An ad-hoc signature changes every build, so Full Disk
  Access or "Kansio would like to access your Documents folder" grants can reset after rebuilding. To keep
  grants during development, sign with a stable self-signed certificate (Keychain Access → Certificate
  Assistant) via `KANSIO_SIGN_IDENTITY`.
- **The "responsible process" matters.** Launching `Kansio.app/Contents/MacOS/Kansio` from a terminal makes
  TCC attribute file access to the terminal app, not Kansio. Use `open build/Kansio.app` when testing permissions.
- Listing `~` doesn't trigger TCC prompts; *entering* Desktop/Documents/Downloads, removable or network
  volumes does. The usage strings in `Info.plist` are what the prompt shows.

## Listing (`getattrlistbulk`)

- One syscall returns many entries with metadata packed into a buffer. Only attributes the kernel actually
  returned are present (check `ATTR_CMN_RETURNED_ATTRS`), in bit order, except `ATTR_CMN_ERROR`, which comes
  right after the returned-attributes set. Fields aren't 8-byte aligned → `loadUnaligned`.
- `ATTR_CMN_FNDRINFO` is 32 bytes, **big-endian**; `finderFlags` at offset 8 gives `kIsAlias` (Finder alias
  files) and `kHasBundle` (package bit). Packages are also recognised by extension via UTType (cached per extension).
- Hidden = name starts with `.` **or** the `UF_HIDDEN` flag (`chflags hidden`), same as Finder/`isHiddenKey`.
- `SF_DATALESS` marks iCloud "optimized storage" files. We read metadata only; opening such a file's contents
  would trigger a download. (Listing a *dataless directory* can still make the system fetch that directory's
  entries, like Finder does; `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)` controls this if needed.)
- Volumes without `getattrlistbulk` (some FUSE/third-party file systems) return `ENOTSUP` → we fall back to FileManager.
- Blocking listing runs on a dedicated concurrent GCD queue, not the Swift concurrency cooperative pool: a hung
  SMB mount would otherwise block one of the pool's few threads (≈ core count) indefinitely.

## Sorting

- Finder order = `localizedStandardCompare` = case-insensitive + numeric ("file2" < "file10") + width-insensitive
  + forced ordering, using the current locale. We call `CFStringCompareWithOptionsAndLocale` on native CFStrings.
- **CF serializes locale-aware comparisons behind a process-wide lock**, so parallel sorting doesn't help (measured).
  Hence: rank names once per listing, then every column sort uses integer keys with the rank as tie-breaker.
- **ICU sort keys as a pre-sort.** The system `libicucore` (no headers in the SDK; loaded with `dlopen`/`dlsym`,
  falling back to CF if missing) builds collation keys in parallel, one collator per thread (secondary strength
  = case- and width-insensitive, numeric on). ICU's order differs from CF's for a few exotic names (the "ﬁ"
  ligature, full-width digits next to ASCII digits), so a final Swift sort with the exact CF comparator runs on
  the ICU order; Swift's sort is run-adaptive, so that pass costs ~n comparisons.
- **CF's comparator isn't a consistent order on pathological names** (e.g. "å…" vs full-width "Ａ…" with
  diacritics and width-insensitivity). For such inputs any sort algorithm gives algorithm-dependent results,
  Finder included; tests require exactness on realistic names and "at least as sorted as a CF sort" otherwise.
- Explorer semantics: ascending puts folders first; descending reverses the whole list. Packages sort with files.
  Symlinks to folders sort with folders once their target is classified (`SymlinkResolver`, one `stat` each,
  after the listing, with a 20 ms deadline so a link into a dead network mount can't hold the folder back).
- Opening a link to a folder keeps the link's path (Explorer behaviour); Finder would jump to the target's real path.

## Unicode names

- APFS preserves the bytes of a name as created (NFC or NFD) but compares names normalization-insensitively;
  HFS+ stores NFD. We keep names byte-exact as returned (building paths from them always works) and compare with
  Swift `==`, which uses canonical equivalence (NFC == NFD).
- Names may contain newlines, tabs and other control characters; the label shows them as Unicode Control
  Pictures (␊, ␉) so they're visible. Display only; the real name is unchanged.
- POSIX `:` is shown by Finder as `/` (legacy HFS path separator). Kansio currently shows the real `:`. Open question.

## AppKit table performance

- `reloadData()` throws away every row view and re-adds each cell to the view tree; with layer-backed views that
  dominated a page update (`sample` profile). We update visible cells in place and only tell the table about count changes.
- `noteNumberOfRowsChanged()` **fades newly visible rows in** from alpha 0 (~0.3 s) — but not inside an
  `NSAnimationContext` group with `duration = 0`. That's what we use: it's also much cheaper than
  `insertRows(at:withAnimation:)`, which walks every inserted index (~4 ms for 23k rows). Removing rows (any API)
  walks every removed row inside AppKit (~8 ms for 100k).
- Dropping the last reference to a huge array of structs with Strings frees each string: ~10 ms for 100k on the
  main thread. Hand the old value to a background queue to be released there.
- `NSWorkspace.icon(for:)` returns an IconServices image that re-renders on every draw; rasterize once per type.
- Every NSTextField gets its own CA layer; `canDrawSubviewsIntoLayer` on the cell view draws the cell's subviews
  into one layer.
- `cacheDisplay(in:to:)` on the window/scroll view can't capture NSTableView rows (they render as empty), but works
  on individual row views. `--snapshot` composes row views into a PNG; that way, checking the UI visually doesn't need
  Screen Recording permission.
- Measuring main-thread hitches: AppKit's layout/display and the Core Animation commit run as *before-waiting*
  run-loop observers. A hitch monitor must observe with the highest order to include them (we bracket each
  iteration with `CFIndex.min` / `CFIndex.max` observers).
- `URLResourceValues.effectiveIcon` is what Finder shows (app icons, custom icons, alias/symlink badges). It reads the
  bundle or resource fork, so per-file icons load off-main, for visible rows only, and are rasterized before use.
- Measuring scrolling: drive it from a display link (`NSView.displayLink(target:selector:)`, macOS 14+), one
  constant-speed step per refresh; late callbacks = dropped frames. Start after launch has settled — app start-up
  work (window activation, menus, input services) lands ~0.4 s after launch and would otherwise be counted.

## Window shell / sidebar

- `NSSplitViewItem(sidebarWithViewController:)` gives the standard sidebar behaviour (vibrancy, collapse,
  `toggleSidebar:` in the responder chain, `.sidebarTrackingSeparator` toolbar alignment). With
  `.fullSizeContentView` the scroll views extend under the toolbar and inset their content automatically.
- Volumes: `FileManager.mountedVolumeURLs(… options: .skipHiddenVolumes)` can block on a stale network mount,
  so it runs on the listing queue. Changes come from `NSWorkspace.shared.notificationCenter` (didMount /
  didUnmount / didRenameVolume) — that's NSWorkspace's *own* notification center, not `NotificationCenter.default`.
- Desktop, Documents and Downloads are TCC-protected: the first listing triggers the system prompt (text from
  the `NS…FolderUsageDescription` keys). If denied, the listing fails with EPERM and the inline error shows.
- Testing mounts safely: `hdiutil create -size 8m -fs APFS -volname X file.dmg` in a temp dir, then
  `hdiutil attach` / `detach`. The volume appears in the sidebar via the mount notification.

## Navigation

- **Mouse side buttons** arrive as `otherMouseDown` with `buttonNumber` 3 (back) and 4 (forward) — 0-based, so
  "button 4/5". We catch them in `NSWindow.sendEvent` so they work wherever the pointer is; no view would see them
  consistently otherwise. (Mouse utilities like Logitech's can instead map them to ⌘[ / ⌘] — that works too.)
- **Key-equivalent localization:** since macOS 12, menus remap shortcuts to the user's keyboard layout. ⌘[ / ⌘] appear
  as ⌘Ö / ⌘Ä on Finnish/Swedish layouts (same physical keys). Don't hard-code "[" when testing shortcuts — read the
  menu item's `keyEquivalent`.
- **Activation:** an app launched from a terminal isn't activated, and macOS 14+ "cooperative activation" may refuse
  to bring even an `open`-launched app forward while you're using another app. Without a key window, menu shortcuts
  have no target. The self-test launches via `open` and skips (doesn't fail) the shortcut checks if not activated.
- **Responder chain:** menu actions that must work whichever pane has focus (Back/Forward/Up, Show Hidden Files) live
  on the window controller (the window's delegate is in the chain), not on the list's view controller.
- **Explorer semantics kept:** Up is a recorded navigation (Back returns to the child) and selects the child folder;
  Back/Forward restore the selection you left, or select the folder you're coming back out of.
- **Startup prefetch:** listing the first folder before `NSApplication.shared` exists overlaps ~80 ms of AppKit
  start-up; the window is created with its rows, so the first frame isn't empty.

## Address bar & debugging

- The bar is an `NSTitlebarAccessoryViewController` (`layoutAttribute = .bottom`): it sits under the toolbar
  over the content area, and scroll views adjust their insets for it automatically.
- The suggestion list is a borderless `NSPanel` child window that refuses key status (`canBecomeKey = false`),
  so typing stays in the address field while the list is clickable.
- `CGRect.insetBy` returns `CGRect.null` (origin at **infinity**) when the rect is smaller than the inset — e.g.
  before the first layout. Frames built from it become autoresizing-mask constraints with out-of-range
  constants ("constant that exceeds internal limits"). Use `safelyInset`.
- Debugging with only the Command Line Tools: `lldb` works, but **not on the Hardened-Runtime-signed app**
  (no `get-task-allow`; attach is refused). Debug the plain SwiftPM binary instead:
  `lldb -- "$(swift build --show-bin-path)/Kansio"`, e.g. with a breakpoint on
  `_NSLayoutConstraintNumberExceedsLimit` or `UIViewAlertForUnsatisfiableConstraints`-style symbols.
- Self-drawing cells: a `NSTableCellView` subclass that draws in `draw(_:)` must redraw on `backgroundStyle`
  changes (selection → `alternateSelectedControlTextColor`) and expose itself to accessibility
  (`accessibilityRole = .staticText`, value = the text) since there's no text field for VoiceOver to read.

## File operations (M7)

- **`rename(2)` silently replaces an existing file at the destination.** Every rename/move goes through
  `renamex_np(…, RENAME_EXCL)`, which fails with `EEXIST` instead. A case-only rename ("a.txt" → "A.txt") on a
  case-insensitive volume reports EEXIST too — the "other" file is the same inode, so that one is retried without EXCL.
- **Trash is per volume.** `FileManager.trashItem` moves to `~/.Trash` on the startup disk but to
  `/Volumes/X/.Trashes/<uid>` on other volumes, and returns the resulting URL (kept for Undo, M12). Tests use a
  temporary disk image so they never put anything in the user's Trash. Paths come back resolved (`/private/var/…`).
- **Quick Look** (`QLPreviewPanel`) finds its controller through the responder chain: the list's view controller
  implements `acceptsPreviewPanelControl` / `begin…` / `end…PreviewPanelControl` (an informal protocol on
  `NSResponder`, declared nonisolated in the SDK although called on the main thread). It logs
  `sandbox_extension_consume failed` in unsandboxed apps — harmless.
- Synthesized `NSEvent`s in tests need a real `timestamp` (`ProcessInfo.systemUptime`); code that compares event
  times (e.g. "Space continues type-to-select within 1 s") misbehaves with 0.
- The second `insetBy` → `CGRect.null` case was the suggestion panel built with a zero frame; all insets in the app
  now go through `safelyInset`.

## Opening (M8)

- `NSWorkspace.open(_:configuration:completionHandler:)` is asynchronous and reports failures (e.g.
  `kLSApplicationNotFoundErr` −10814 when no app claims the type) in its completion — shown inline, never as an alert.
- Finder **aliases** are bookmark files, not symlinks: resolve with `URL(resolvingAliasFileAt:options:
  [.withoutUI, .withoutMounting])` off-main — without `.withoutMounting`, an alias to a server volume would try to
  mount it (and could stall).
- `NSWorkspace.urlsForApplications(toOpen:)` / `urlForApplication(toOpen:)` query LaunchServices; they're done off-main
  per *type* (one representative file per extension) and cached, so Select All on 100k files can't trigger 100k queries.
- An `NSMenu` can be modified while it's open — the Open With submenu shows "Loading…" and fills in when ready.

## Copy/move engine (M9)

- **`clonefile(2)`** clones a file *or a whole directory tree* on the same APFS volume: instant, shares blocks (free
  space barely changes — that's how the test verifies it). It fails with EXDEV/ENOTSUP elsewhere → fall back to
  `copyfile(3)`.
- **`copyfile(3)`** with `COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL` copies data,
  metadata, xattrs (Finder tags are an xattr), ACLs. Its status callback gets `COPYFILE_COPY_DATA/PROGRESS` about once
  per MB (cancel by returning `COPYFILE_QUIT`) and `…/COPYFILE_ERR` per failing file (return `COPYFILE_SKIP` to go on).
  Our progress *reports* are throttled to 20/s, but cancellation is checked on every chunk.
- **Never a half-written file under the real name:** copy to `.kansio-partial-<uuid>-name` in the destination folder,
  then `renamex_np(RENAME_EXCL)` into place. On cancel/failure only that temporary copy (which we created) is removed.
- **Cross-volume move** = copy + verify (item count, bytes) + place + remove source; the source stays if any file failed
  or the copy doesn't match — both copies existing is fine, losing one isn't.
- The engine runs on its own GCD queue (`kansio.fileops`), separate from listing, and bridges the async conflict
  resolver with a semaphore — fine on a GCD thread, never on the Swift cooperative pool.

## Conflicts (M10)

- Name clashes are detected with `lstat` on the target, so on a case-insensitive volume "readme.md" vs "README.md"
  *is* a clash (as it must be — the file system would treat them as the same name).
- The conflict sheet is `NSAlert.beginSheetModal(for:)` (async): window-modal, so other windows keep working; questions
  from several operations queue up. The engine waits on a GCD thread (semaphore), never on the cooperative pool.
- "Replace" never deletes: the existing item is moved to the Trash first (and the engine refuses if that folder
  contains the item being moved — otherwise the source would end up in the Trash with it).

## Operations panel (M11)

- The panel is an `NSPanel` with `.utilityWindow` + `.nonactivatingPanel` and `becomesKeyOnlyIfNeeded`: it can be shown
  with `orderFront` without taking keyboard focus from the user's window.
- The engine's error hook works like the conflict resolver: the engine thread waits (semaphore) for an async answer the
  panel provides through a `CheckedContinuation` when the user clicks Retry / Skip / Stop.
- `copyfile` with a status callback that returns `COPYFILE_SKIP` for an unreadable *single* file returns success and
  creates nothing — check that the destination exists before trying to place it (otherwise a second, bogus "no such
  file" error appears).
- `NSApplicationDelegate.applicationShouldTerminate` → `.terminateLater` lets the app cancel running operations and
  quit once they've cleaned up (`reply(toApplicationShouldTerminate:)`).

## Undo (M12)

- `UndoManager` wants the redo action registered *during* the undo, synchronously. File work is async, so the same
  `UndoStep` is registered in both directions immediately and the work queued on a serial actor (a redo can't overtake
  its undo); Trash locations discovered later go into a shared `TrashSlot`.
- `NSWindow` implements `undo:`/`redo:` and titles the menu items from `undoActionName`; it gets the manager from its
  delegate's `windowWillReturnUndoManager`. We return the app-wide file history — except while a text field is being
  edited, so ⌘Z in the rename field undoes typing, not the last copy.
- `groupsByEvent = false`: each operation is registered as its own group (an async completion isn't part of the
  event that started it).

## Live updates (M13)

- **FSEvents with `kFSEventStreamCreateFlagFileEvents`** reports individual paths (created/removed/renamed/modified)
  — but recursively, for everything below the watched folder, so events are filtered to direct children on the
  watcher's queue. `WatchRoot` adds an event when the folder itself is moved/deleted. Paths are real paths
  (`/private/var/…` for `/var/…`), so the watched folder is compared via `realpath`.
- A rename arrives as two paths (old, new): re-reading both names gives "old gone, new present"; matching inodes tells
  the view it's the same item (selection follows).
- `MustScanSubDirs` / dropped-events flags mean FSEvents lost detail: re-list once and diff instead.
- FSEvents only knows about changes made through *this* Mac's kernel: SMB/AFP shares changed by other machines don't
  report; network folders would need polling (not done).
- `FSEventStreamCreate`/`Start` cost ~2 ms cold — done on the watcher's own dispatch queue, not at navigation.

## Get Info (M15)

- Finder's own Info panel can only be opened by scripting Finder (Apple Events). Under Hardened Runtime that needs
  the `com.apple.security.automation.apple-events` entitlement plus a one-time Automation (TCC) prompt, and it brings
  Finder to the front. So Kansio has its own small window instead.
- `NSWorkspace.icon(forFile:)` goes through IconServices/LaunchServices: called off-main, and the icon is rasterized
  into bitmap reps there before being handed to the main thread (the same pattern as the icon cache).
- Wrapping labels (`NSTextField(wrappingLabelWithString:)`) don't shrink their window when their text gets shorter:
  the window is refitted (`fittingSize`, top edge kept) after each update. When rendering into a 2× bitmap rep, set
  `rep.size` *before* creating the `NSGraphicsContext`, otherwise it draws at 1×.

## Global view settings (M16)

- `NSTableView.autosaveName` + `autosaveTableColumns` persists order/widths/hidden columns *per table* under keys like
  `NSTableView Columns v3 <name>`; each table writes its own copy, so two windows would fight over it and nothing
  tells the other window. Kansio stores the layout itself (`view.columns`, JSON) and broadcasts changes.
- `NSTableView.columnDidResizeNotification` also fires for programmatic width changes (and for autoresizing — off
  here: `.noColumnAutoresizing`), so applying the setting sets a flag to ignore its own notifications.
- `URL.resolvingSymlinksInPath()` turns `/private/var/…` into `/var/…` (it strips `/private`), the opposite of what
  FSEvents reports; use `realpath(3)` when comparing with FSEvents paths.
- Checking for writes by hand (needs root): `sudo fs_usage -w -f filesys Kansio | grep -E 'open|write|rename|setattr'`
  while browsing — only reads (`open` with `O_RDONLY`, `getattrlistbulk`, `stat`) should appear for browsed folders.
- **Header clicks and double-clicks:** `NSTableHeaderView` treats a second click on a header inside the double-click
  interval (`clickCount` 2, 4, …) as a double-click and does *not* change the sort — so clicking a header twice
  quickly to reverse the order did nothing. `FileListHeaderView` passes every click on as a single click (Explorer
  sorts on every click). The self-test sends real mouse-down/up events with click counts 1–4.

