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
