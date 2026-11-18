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

## Settings window (P1-0)

- An AppKit app without the SwiftUI `App` lifecycle can't use the `Settings` scene; the window is an `NSWindow` with
  an `NSHostingController`. Layout is System Settings style (same as Notepadz): a `NavigationSplitView` with a sidebar
  of panes and a `.grouped` `Form` per pane, in a resizable 760×540 window (`.fullSizeContentView`).
- The pane's `.navigationTitle` becomes the window title (the hosting controller bridges it, a moment after the pane
  changes), so the Window menu says "General", "Privacy", … like System Settings.
- `.toolbar(removing: .sidebarToggle)` made `NavigationSplitView` ignore `navigationSplitViewColumnWidth` (sidebar
  shrank to 144 pt and truncated "Navigation Pane"); without it the width is honoured.
- A grouped form's section footer is trailing-aligned on macOS; explanations use `Footnote` (leading frame and
  `multilineTextAlignment(.leading)`), otherwise a wrapped second line hugs the right edge.
- `@Observable` needs the Observation macro plugin, which (like the swift-testing macros) isn't found by default with
  the Command Line Tools; `ObservableObject` + `objectWillChange` needs no macros.

## Navigation-pane tree (P1-1)

- **NSOutlineView cost scales with rows, even for hidden ones:** each `expandItem` cost ~1 ms in a pane with ~370 rows
  (also for rows inside collapsed parents), and collapsing a node with 10,000 children took 22 ms in one call. The tree
  spreads expansions over run-loop turns (≤ 4 ms each) and removes a big node's rows in chunks before collapsing it.
- **Collapsing a parent also reports its expanded descendants as collapsed** (`outlineViewItemDidCollapse`). The model
  ignores those (the parent is no longer expanded) and re-opens remembered children when the parent opens again, so a
  hand-expanded branch survives its parent being collapsed.
- **Autoresizing masks become constraints** once anything in the window uses Auto Layout: a cell narrower than its
  label's offset (deep rows) asked for a negative width and AppKit raised an unsatisfiable-constraints exception.
  Sidebar cells draw themselves and lay out the rare subview (spinner, rename field) by hand, clamped.
- **Custom row views aren't reused automatically:** returning a new `NSTableRowView` from `rowViewForItem` every time
  is measurably slower; give it an identifier and get it from `makeView(withIdentifier:owner:)`.
- **Directory-level FSEvents** (no `kFSEventStreamCreateFlagFileEvents`) report the *folder* whose entries changed —
  exactly what a tree needs, and far fewer events than file-level ones. A stream on `/` sees all system activity:
  filter it on the watcher's queue against the folders the tree has listed, and coalesce before hopping to main.
- **An inactive window's first click only activates it** (no `acceptsFirstMouse`): synthesized clicks in the self-test
  go straight to the view when the test launch isn't frontmost.

## Favorites (P1-2)

- **Bookmark data** (`URL.bookmarkData`) records a file's identity (volume + file ID) as well as its path, so
  `URL(resolvingBookmarkData:)` finds a renamed or moved folder. Resolve with `.withoutUI, .withoutMounting` (never
  prompt or mount a server) and off the main thread. Without the App Sandbox no security scope is needed.
- A folder moved to the Trash still resolves — to the Trash; Kansio treats that as missing (kept, dimmed) so Undo
  brings the favorite back. Resolution returns canonical paths (`/private/var/…`); keep the pinned path when the
  folder didn't move, or "is this folder pinned?" stops matching the path the list shows.
- **Drag sources:** `tableView(_:pasteboardWriterForRow:)` makes the list draggable; `setDraggingSourceOperationMask`
  for non-local drags limits what other apps may do (Kansio allows only `.copy` until P1-4, so a drag can never move
  files out). Favorites rows put only a private pasteboard type on the drag, never the folder's URL.
- An `NSDraggingInfo` stand-in (`FakeDraggingInfo`) drives the outline's `validateDrop`/`acceptDrop` in the self-test;
  conforming needs `@preconcurrency` (AppKit's protocol is main-actor isolated).

## Tabs and windows (P1-3)

- **Native window tabs:** each tab is an `NSWindow` in a tab group (`tabbingIdentifier`, `addTabbedWindow(_:ordered:)`).
  AppKit supplies the tab bar, drag-out, Merge All Windows and the "+" button (`newWindowForTab:` on the responder
  chain). Kansio adds explicit Show Previous/Next Tab items (⌃⇧Tab/⌃Tab) — AppKit's automatic ones didn't appear for an
  app that builds its menus in code. ⌘N sets `tabbingMode = .disallowed` while showing the new window so "Prefer tabs:
  always" can't turn it into a tab.
- **Which tab is shown:** `tabGroup.selectedWindow`. AppKit tells only some windows about a switch (key change,
  occlusion) and not in a fixed order, so every trigger re-evaluates all tabs of the group. "Hidden" = another tab
  selected, minimized or app hidden — *not* "covered by other windows" (occlusion), so a window behind Terminal keeps
  its live updates.
- **FSEvents can replay history:** start a stream with `sinceWhen` = the event id when a tab paused
  (`FSEventsGetCurrentEventId()`); events up to `kFSEventStreamEventFlagHistoryDone` are what changed meanwhile (history
  can be coarse, so Kansio re-lists once and diffs when there is any). Works for `/var/folders` too.
- **Switching native tabs costs AppKit ~13–25 ms per switch** (ordering + compositing the tab's window), independent of
  the content. Our cells keep their layer contents and don't redraw.

## Drag and drop (P1-4)

- **Drop targets:** `NSTableView`/`NSOutlineView` data-source methods (`validateDrop`/`acceptDrop`); `setDropRow(-1,
  dropOperation: .on)` highlights the whole list (drop into the folder on screen); `setDropItem(_, dropChildIndex:
  NSOutlineViewDropOnItemIndex)` targets a folder row. `validateDrop` runs on every mouse move: never touch the disk
  there, and cache per `draggingSequenceNumber`.
- **Modifier keys arrive as the source's operation mask:** ⌥ → `.copy` only, ⌘ → `.generic`/`.move` without `.copy`;
  no modifier → everything the source allows (Finder's rule then: move on the same volume, copy across volumes).
- **File promises** (Mail, Photos): `NSFilePromiseReceiver.readableDraggedTypes` + `receivePromisedFiles(atDestination:…)`.
  The other app writes the file — into a staging folder (`.itemReplacementDirectory` appropriate for the destination
  = same volume), so the copy engine still places it (no silent overwrite). It asserts unless the pasteboard is the
  real drag pasteboard, so it can't be driven from a test.
- **Thousands of items:** AppKit writes every dragged item to the drag pasteboard when the drag starts (~0.6 s for
  10k). `NSPasteboardItemDataProvider` (lazy data) makes that 43 ms but each *read* is a round trip through the
  pasteboard server (~4 ms per item) — far worse for any receiver. Reading many file URLs: `pasteboardItems` +
  `string(forType: .fileURL)` is ~4× faster than `readObjects(forClasses: [NSURL.self])`.

## Search (P1-5)

- **Matching like Finder/Explorer:** `String.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`
  then a byte search. Folding is the expensive part (~1 µs per name), so it happens once per folder version, not per
  keystroke; `memmem` over one contiguous buffer then filters 100k names in a few milliseconds.
- **NSSearchField** sends `controlTextDidChange` per keystroke (and its action for the ⓧ button); Esc arrives as
  `cancelOperation:` through `control(_:textView:doCommandBy:)`. It shares the address bar's delegate, so every
  delegate method checks which field it's for.
- Results from subfolders use the item's *relative path* as its name in the list model ("a/b/x.txt"): opening,
  dragging, copying and trashing work unchanged (`folder + name`); renaming is disabled for them.

## Folder sizes (P1-6)

- **Evicted iCloud folders are "dataless":** `readdir` on one makes the file provider download its listing. The size
  walk skips directories with `SF_DATALESS` in `st_flags` and sets the thread's I/O policy
  `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` to `OFF` while it runs (anything dataless then fails with `EDEADLK`
  instead of downloading). `lstat` alone never materializes, so file sizes in iCloud still count.
- **Privacy prompts block.** Desktop, Documents, Downloads, other apps' containers (macOS 14+), iCloud Drive and
  `~/Library/CloudStorage` ask on first access, and the `opendir` that raised the prompt waits until it's answered —
  a background size walk of `~` would both pop prompts nobody asked for and stall the size queue. Without Full Disk
  Access, automatic sizes skip those folders (`Privacy.automaticSkips`) unless the folder being browsed is inside one
  (its listing worked, so access was granted). Seen from `~`, Desktop/Documents/Downloads then show no size; `~/Library`
  is a lower bound (`Totals.skipped`).
- **Not every protected place is documented:** `~/Movies/TV` (the TV app's library) blocks even `find` from a
  terminal. So besides the known list, a watchdog gives up any size walk whose entry counter (`ProgressCounter`) hasn't
  moved for 3 s: its cancel flag is set (the thread stops once the call returns), the folder shows no size, and later
  folders go to a fresh serial queue. A blocked thread can't be interrupted, only abandoned.
- **Detecting Full Disk Access without a prompt:** try to `open` `~/Library/Application Support/com.apple.TCC/TCC.db`;
  it's readable only with Full Disk Access and fails with `EPERM` otherwise (`Privacy.hasFullDiskAccess`). A grant
  usually needs a relaunch to take effect.
- **FSEvents ids per path:** the callback's last argument has one id per event. Replaying since the *oldest* cached
  size would otherwise re-invalidate folders measured after a change; each cache entry stores the current event id taken
  *before* its measurement, and only events with a newer id drop it.

## Full Disk Access onboarding (P1-9)

- **EPERM vs EACCES:** macOS privacy protection (TCC) refuses with `EPERM` ("Operation not permitted"); a folder's
  own Unix permissions refuse with `EACCES`. Only the first is fixed by Full Disk Access / Privacy settings, so the list
  offers Grant Access… for EPERM and Get Info for EACCES (`FileSystemError.isPrivacyDenied`).
- **The settings pane URL:** `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` opens Privacy &
  Security ▸ Full Disk Access. An app can't add itself; the user flips the switch (or adds Kansio with +).
- **A grant usually needs a relaunch** to reach everything (already-open file descriptors, cached denials); the window
  offers Relaunch Kansio when access arrives while it's open (new instance via `NSWorkspace.openApplication` with
  `createsNewApplicationInstance`, then quit).
- **Ad-hoc builds lose the grant on every rebuild** (TCC keys it to the code signature) — see *Signing, Hardened
  Runtime, TCC*. Sign with a stable identity to keep it while developing.

## Trash (P2-1)

- **One Trash per volume:** `~/.Trash` for the startup disk, `<volume>/.Trashes/<uid>` for other local volumes
  (`FileManager.trashItem` picks it). Finder's Trash shows them all; so does Kansio's Trash view.
- **Network volumes (SMB, NFS, AFP) have no Trash.** `trashItem` fails there with `NSFeatureUnsupportedError`, and Finder
  says "This item will be deleted immediately". Apple dropped network Trash folders because nothing cleans up a Trash
  left on a share that isn't mounted (only network *home* folders keep one). Kansio asks, then deletes; or, with
  Settings ▸ Trash ▸ "Keep a Trash folder on network volumes", moves items to `.Trashes/<uid>` at the top of the share
  itself (visible to Windows users; uses server space until emptied; Finder won't show it, Kansio's Trash view does).
- **Where an item came from:** Kansio records each Move to Trash (`TrashHistory`, Application Support, keyed by path +
  inode). For items trashed by Finder, the Trash folder's `.DS_Store` holds put-back data: per name, `ptbL` (original
  folder, relative to the volume root) and `ptbN` (original name). Kansio reads it (never writes it); a minimal reader of
  the B-tree ("Bud1" buddy allocator) format — confirmed on a real `~/.Trash` (2026-11-18: Finder-deleted items show
  their original location and Put Back restores them). Finder's own Put Back doesn't know about items Kansio trashed — Kansio
  doesn't write `.DS_Store`.
- **`~/.Trash` is privacy-protected:** without Full Disk Access listing it fails with EPERM (even `ls` in Terminal), so
  the Trash view shows the usual "macOS doesn't allow…" + Grant Access….
- **Date Deleted** for items Kansio didn't record: the date the item was added to the Trash folder
  (`addedToDirectoryDate`; a rename into the folder sets it).
- **Keys:** in the Trash view Del deletes immediately after asking (Explorer's Recycle Bin), ⌘⌫ puts back (Finder);
  ⇧⌘⌫ is Empty Trash (Finder). Delete confirmations make Cancel the default button (Return never deletes).
- **Permanent deletion is fenced:** `TrashActions.deletePermanently(_:within:)` canonicalizes each path (`realpath` of
  its folder) and refuses anything not strictly inside one of the given roots — a root itself, `..` escapes and
  symlinked parents included; symlinks are removed, never followed.

## Tabs in the title bar (redesign)

- **A custom view in the title-bar row** is a toolbar item: titlebar accessories can only go *below* the toolbar (or
  at its leading/trailing edge). With `titleVisibility = .hidden` and `.unifiedCompact` the toolbar row is the title
  row, next to the traffic lights.
- **Stretching a toolbar item:** give its view a width *range* (`>= 200`, `<= 6000`) and low hugging. A low-priority
  "be 10,000 wide" constraint instead becomes its fitting width and AppKit moves the item into the overflow menu.
- **Sidebar under the title bar:** an `NSSplitViewItem(sidebarWithViewController:)` is full-height by default, which
  splits the toolbar into a sidebar part and a content part; `allowsFullHeightLayout = false` lets the title row (tabs)
  and the address row span the whole window, like Explorer.
- **Views don't clip by default since macOS 14** (`clipsToBounds` = false for apps built with the newer SDK): the first
  tab design drew its shape 8 pt below the view to look "open" at the bottom, and that part showed as a box hanging
  over the title row's separator. The tab strip and tabs now set `clipsToBounds = true` and draw pills inside their
  bounds (the toolbar centres the strip, so a shape can't be aligned with the row's edge anyway).
- `cacheDisplay` draws a view at its own origin; when composing several views into one image, translate to where
  each one is — or, for a single view, draw it at the image's origin.


## SMB shares don't support RENAME_EXCL

`renamex_np(…, RENAME_EXCL)` — our "rename but never replace" — fails with ENOTSUP ("Operation not supported") on
smbfs: the volume doesn't advertise `VOL_CAP_INT_RENAME_EXCL` (check with `getattrlist` `ATTR_VOL_CAPABILITIES`,
interfaces word). Every copy is placed with that call, so before the fix *every* copy/move onto an SMB share failed.
All exclusive renames now go through `ExclusiveRename.rename`, which on ENOTSUP checks the target is free and then
does a plain `rename(2)`. Another client of the share could create the same name between the check and the rename;
that window is unavoidable on SMB (Finder has it too). FAT/exFAT images do support the flag, so the tests simulate an
SMB folder with `ExclusiveRename.simulateUnsupported(under:)`; the self-test's `KANSIO_TEST_NETWORK` folder behaves
that way as well.

## Archives (P2-3)

- **Two engines.** 7-Zip's `7zz` runs as a separate process (bundled in `Contents/MacOS`, signed with the app, Hardened
  Runtime). macOS's libarchive (`/usr/lib/libarchive.2.dylib`, the library behind `tar`) has no headers in the SDK, so
  `LibArchiveEngine` looks up the ~40 functions it uses with `dlsym` once; if any is missing the engine reports itself
  unavailable and 7-Zip is used.
- **7-Zip switches that matter:** `-spd` (otherwise `*` and `?` in file names are wildcards), `-sccUTF-8`/`-scsUTF-8`
  (console and list-file encoding), `-snl` (store/extract symlinks as links; 7-Zip skips links pointing outside),
  `-sse` (stop if a file can't be read instead of silently leaving it out), `-mcu=on` for zip (UTF-8 names), and a
  dummy `-p…` password: without one, an encrypted archive makes 7zz *prompt on stdin* and wait. Progress: `-bsp1`
  prints "NN%" with backspaces on stdout.
- **libarchive's `ARCHIVE_EXTRACT_SECURE_SYMLINKS` refuses any symlink in the destination path** — including `/var` →
  `/private/var` in `$TMPDIR` — and reported it only as a warning, so nothing was extracted and nothing failed. The
  engine now extracts under the `realpath` of the destination and treats anything but `ARCHIVE_OK` as an error.
- **Unicode:** 7-Zip stores names byte-exact. libarchive's 7z writer stores them precomposed (NFC), so a decomposed
  name (as Finder/APFS often has) comes back NFC — canonically the same name; the verification of "Compress into"
  compares canonically (NFC both sides).
- **Nothing half-made:** compress writes `.kansio-partial-<uuid>-name` next to the result and renames it into place
  (`ExclusiveRename`, free name); extract unpacks into a `.kansio-partial-<uuid>` folder and moves items out with the
  copy engine (same volume → renames; clashes → conflict sheet). Cancel/failure removes only those temporary items.
  7-Zip's list file goes to `$TMPDIR`, never the browsed folder.
- **Context menu peek:** whether "Extract as" is offered depends on the archive's top level. Listing a zip/7z is quick
  (central directory / end header) but still a process launch or file read, so it starts when the archive is selected
  and is cached; tar formats aren't peeked (the whole stream would be decompressed).

## Signing, privacy grants and duplicate apps (2026-11-18)

- **Ad-hoc signing breaks privacy grants on every rebuild.** An ad-hoc signature's designated requirement is the
  binary's hash (`cdhash`), and TCC (Full Disk Access, folder prompts) stores that requirement with the grant. A
  rebuilt app has a new hash, so the old grant silently stops applying, while System Settings still shows "Kansio"
  switched on. `Tools/signing-identity.sh` creates a self-signed code-signing certificate ("Kansio Local Signing") in
  its own keychain file (`~/Library/Keychains/kansio-signing.keychain-db`, not in the search list, key not in the
  repo); signed with it, the requirement is `identifier "dev.kansio.Kansio" and certificate leaf = H"…"`, which stays
  the same across builds. The certificate isn't trusted (`CSSMERR_TP_NOT_TRUSTED`); codesign and TCC don't need it to
  be. Gatekeeper never checks a locally built app (no quarantine attribute). TCC never updates a stored requirement:
  grants made for the ad-hoc builds keep requiring their cdhash (tccd logs "Failed to match existing code
  requirement"), even though System Settings shows the switch on. `tccutil reset All dev.kansio.Kansio` removes them;
  then add /Applications/Kansio.app to Full Disk Access again. Debug with
  `/usr/bin/log stream --level debug --predicate 'subsystem == "com.apple.TCC"'` (in zsh, plain `log` is a builtin).
- **Spotlight and LaunchServices saw every copy:** `/Applications`, `build/`, test copies, and each replaced copy
  moved to the Trash (LaunchServices follows a moved bundle). The build now lives in `build/app.noindex/` (Spotlight
  skips `*.noindex` folders), `build-app.sh`, `self-test.sh` and `install.sh` unregister the development / replaced
  copies (`lsregister -u`). That wasn't enough: tccd registers an app with LaunchServices whenever it's launched (log:
  "Registered LSApplicationRecord"), so each self-test brought the dev copy back. The build now lives in
  `$TMPDIR/kansio-build/` (symlinked as `build/Kansio.app`): LaunchServices flags bundles there `in-temp-dir,
  launch-disabled`, which keeps them out of app lists while `open` still launches them. Copies in the Trash were registered again by the system after an install even when
  unregistered, so `install.sh` trashes the old copy as `Kansio (replaced …).app-old` — not a bundle, so never
  listed; rename it back to use it. A record for a bundle that was replaced by a symlink can only be removed while
  nothing is at that path (`lsregister -u` resolves the symlink).
- **Showing an .app registers it.** Looking up an app bundle's icon (Finder, or Kansio's list) registers it with
  LaunchServices, and Spotlight's app results come from LaunchServices — so browsing `build/` or the test fixtures
  listed them as more "apps" (a fixture without Info.plist appears nameless). `self-test.sh` unregisters every bundle
  under the fixtures folder and the development copy when it ends; browsing `build/app.noindex` by hand registers the
  development copy again until the next build or self-test.
- **App icon:** a plain `.icns` (`CFBundleIconFile`), drawn by `Tools/make-icon.swift` on Apple's icon grid (824 pt
  rounded square in a 1024 canvas) — asset catalogs / Icon Composer need Xcode's `actool`.

## List zoom and most used folders (P2-8)

- **⌘+ is ⌘= on most keyboards.** A menu item with key equivalent "+" only matches when the "+" character is typed
  (a dedicated key on Finnish/German layouts; ⇧= on US). A hidden twin item with "=" and
  `allowsKeyEquivalentWhenHidden` catches the US case. AppKit's *automatic key-equivalent localization* (macOS 12+)
  moves shortcuts to where the character is on the current layout — on a Finnish layout it turned the twin's "=" into
  "`" — so the twin sets `allowsAutomaticKeyEquivalentLocalization = false`.
- **Worker threads have 512 KB stacks.** GCD and Swift-concurrency threads get far less stack than the main thread
  (8 MB), and debug builds use big frames, so a walk that recursed once per folder level crashed (EXC_BAD_ACCESS in
  the stack guard) at only 60 levels. Tree walks keep their own stack/work list instead.
- **Dwell, not visits:** a folder counts for "most used" only if the same tab still shows it after the wait; each
  window has its own timer (`FolderUsageTracker`).
- **`NSMenuItem.subtitle`** (macOS 14.4+) shows the location for names that appear twice in the menu.
- **Self-test launches pass `-ApplePersistenceIgnoreState YES`:** after a run is killed, AppKit's next launch asks
  "reopen windows?" in a modal alert, which blocks the self-test forever.

## Tearing off tabs (P3-1)

- **A tab drag is an `NSDraggingSession` with a private pasteboard type**, and the operation mask is `.move` only
  `withinApplication` (other apps refuse it). The tab items register only for file types, so AppKit walks up to the
  strip, which registers the tab type. "Dropped on nothing" is the session ending with no operation; Esc ends it the
  same way, told apart by the current event being a key press.
- **A drop can close the window the drag started in** (its only tab left). The dragging source view (and its strip)
  is kept in a static until `draggingSession(_:endedAt:operation:)`, so AppKit never calls a freed source.

## Right-button drag (P3-2)

- **AppKit has no right-button drag and drop.** Dragging sessions belong to the left button (Finder has no right-drag
  either), so Kansio runs its own tracking loop: `window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp,
  .keyDown])` — the window that got the press keeps receiving the drag events even outside it. The window under the
  pointer comes from `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`, skipping the drag image and outline
  (borderless panels that ignore the mouse). Only Kansio windows are targets.
- **The context menu now opens on release** (as in Explorer): `rightMouseDown` first waits to see whether the pointer
  moves; NSTableView's own `rightMouseDown` (which pops up the menu) is called with the original press afterwards.
- **Aliases** are bookmark files (`URL.writeBookmarkData` of `.suitableForBookmarkFile` data); it sets the Finder
  alias flag itself. It would overwrite an existing file, so it writes to a temporary name first.

## Pause and time left (P3-4)

- **Pausing blocks the operation's own thread**, never the main thread: `PauseGate.waitIfPaused` waits on an
  `NSCondition` (re-checking Stop every 100 ms). Calling it from copyfile's status callback pauses inside a large file;
  copyfile just doesn't get its callback answered until then. `clonefile` is atomic, so a cloned item is never paused
  half-way (it takes milliseconds).
- **Why not "bytes left ÷ average speed":** per-file costs dominate small files (create, xattrs, ACLs, rename), so a
  run that starts with big files and ends with thousands of small ones would show "a few seconds left" for minutes.
  The estimator separates the two costs; see `TransferEstimator`'s comment.

## Browsing archives (P3-5)

- **Paths through a file.** A location inside an archive is a normal file URL whose path continues past the archive
  file (`…/photos.zip/dir`). Nothing on disk exists there, so every place that would touch the disk checks
  `OpenedArchives` first: listing (the archive's index instead), watching (none), the tree's listing, the address bar,
  drops, folder sizes, search's subfolder walk, free space (the archive's volume), most used folders (not counted).
- **Only opened archives are folders.** The registry is per run; an archive nobody opened stays a file (also in the
  tree), so a folder full of zips costs nothing.
- **Dragging out uses file promises** (`NSFilePromiseProvider`): the receiving app (Finder, Kansio) says where, and only
  then is the item extracted — into a temporary folder there, renamed into place. 7-Zip's `-spd` makes the paths literal
  (no wildcards) and extracts a folder with everything in it.
- Files opened from an archive are read-only copies in `$TMPDIR/kansio-archive-view` (cleared at launch): an app that
  saves gets an error instead of silently editing a copy nobody will see again.

## Open in Terminal / Editor (P3-6)

- **No AppleScript.** Handing a folder URL to a terminal with `NSWorkspace.open(_:withApplicationAt:)` is the same as
  dropping it on the app's Dock icon: Terminal, iTerm2, Warp and Ghostty open a new window there. AppleScript (`do
  script "cd …"`) would need the Automation permission prompt and per-app scripts.
- The apps are set only in Settings ▸ Apps (no default, no chooser while opening): a menu item with nothing set opens
  that pane, so "which app" is always a deliberate choice that Settings shows.
- App lookup by bundle identifier (`urlForApplication(withBundleIdentifier:)`) goes through LaunchServices, so it runs
  off the main thread when the Settings pane appears; the chosen app is stored as path + display name, so menus never
  ask LaunchServices.

## Search filters (P3-7)

- **The query text is the one source of truth.** The popover's controls are a view of `SearchQuery.parse(text)`;
  changing one writes `SearchQuery.formatted` back into the search field (the words are kept as typed) and searches.
  Sizes are stored as number + unit ("1.5GB"), so text → controls → text doesn't drift.
- SwiftUI in the popover (low traffic, like Settings) with an `ObservableObject` model; `@State` is avoided as in
  Settings (its macro plugin isn't in the Command Line Tools).
- Dates are matched in the user's calendar and time zone (`date:today` is local midnight to midnight; weeks start on
  the locale's first weekday).
