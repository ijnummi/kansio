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
- Explorer semantics: ascending puts folders first; descending reverses the whole list. Packages sort with files.
  Symlinks currently sort with files (their target type isn't known without a `stat`; see PLAN).

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
- `noteNumberOfRowsChanged()` **fades newly visible rows in** from alpha 0 (~0.3 s). Use
  `insertRows/removeRows(at:withAnimation: [])` (empty options = no animation).
- `NSWorkspace.icon(for:)` returns an IconServices image that re-renders on every draw; rasterize once per type.
- Every NSTextField gets its own CA layer; `canDrawSubviewsIntoLayer` on the cell view draws the cell's subviews
  into one layer.
- `cacheDisplay(in:to:)` on the window/scroll view can't capture NSTableView rows (they render as empty), but works
  on individual row views. `--snapshot` composes row views into a PNG; that way, checking the UI visually doesn't need
  Screen Recording permission.
- Measuring main-thread hitches: AppKit's layout/display and the Core Animation commit run as *before-waiting*
  run-loop observers. A hitch monitor must observe with the highest order to include them (we bracket each
  iteration with `CFIndex.min` / `CFIndex.max` observers).
