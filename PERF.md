# Performance log

All numbers are measured, warm cache unless stated. Times in ms.
Machine: **Mac18,5, Apple M6, 12 cores, 32 GB, macOS 27.2.1 (26B131)**, internal SSD (APFS).
Fixtures: `Tools/make-fixtures.sh` (flat folders with realistic mixed names, ~3 % subfolders).

## 2026-11-16 — Tabs redesigned (one window, Explorer layout)

`--measure-tabs`, 20 tabs, 40 switches, against the native-tab version (P1-3 below):

| | Native window tabs | One window, own tab strip |
|---|---:|---:|
| Switch, median | 13–25 ms | **7.8–13 ms** |
| Switch, worst | 40–60 ms | 23–35 ms |
| Iterations > 16 ms (of 40) | 40 | 3–9 (16.7–17.8 ms in the traced run) |
| Kansio's own work per switch | 0.1 ms | 4–5 ms (address bar 2.7–4.4 ms, pane, list resume) |
| Re-lists | 0 | 0 |
| Idle, 20 tabs | 0.10–0.12 % | **0.045–0.05 %** (1 main wake-up in 5 s) |

The rest of a slow switch is AppKit laying out and drawing the list view that becomes visible.

## 2026-11-16 — P1-5 (search)

`Kansio --measure-search $TMPDIR/kansio-fixtures` (start in `flat-100k`).

| Scenario | Budget | Result |
|---|---|---|
| Keystroke → updated list, 100,000 items (index prepared when the field got focus) | < 50 ms | **3–27 ms** (r → 44,178 matches … "report 12" → 150) |
| First keystroke typed without focusing first (builds the index) | < 50 ms | 77–85 ms (once per folder version) |
| Worst main-thread iteration while typing | ≤ 16 ms | 14–20 ms — the list going from 100k to 44k rows (`noteNumberOfRowsChanged`, see M6) |
| Whole fixtures tree (14,460 folders, ~120k entries) | stream, cancellable | complete in 0.69–0.77 s, worst iteration 5.2–5.8 ms |
| Ending a search 100 ms into the walk | stops | walk stopped (cancel flag), folder rows back |

The first version sorted each keystroke's matches (FolderContents ranking) and built the folded index on the first
keystroke: 85 ms for "r" on 100k. Indexing the already-ordered rows (matches come out in display order) and building
the index when the field gets focus brought every keystroke under the budget.

## 2026-11-16 — P1-4 (drag and drop)

`Kansio --measure-drag $TMPDIR/kansio-fixtures` — every item of `flat-10k` (10,000 files) dragged to another window.

| Step | Before tuning | Now |
|---|---:|---:|
| Drag start: 10,000 pasteboard items (AppKit writes them) | 617 ms | **~610 ms** (open; lazily provided items: 43 ms to write, but 44 s to read) |
| Drag image | 5.3 ms | 5.3 ms |
| First validation, drag from Kansio | 206 ms | **3.4–4.4 ms** (folder + names registered at drag start) |
| First validation, drag from another app | 206 ms | **8.3–8.6 ms** (first 100 items) |
| Each later validation (every mouse move) | 64–72 ms | **0.0 ms** (decision cached per drag + target) |
| Accepting the drop (main thread) | 65 ms + full read | **1.3 ms** (Kansio) / **119–121 ms** (another app: reading 10,000 strings; parsing and checks off-main) |

Pasteboard numbers measured on the way: writing 10k `NSURL`s 617 ms, 10k items with only `public.file-url` 530 ms,
reading 10k via `readObjects(NSURL)` 128 ms vs `pasteboardItems` + `string(forType:)` 35 ms (from an eager pasteboard).

## 2026-11-16 — P1-3 (tabs and windows)

`Kansio --measure-tabs $TMPDIR/kansio-fixtures` — 20 tabs (fixture folders + `deep/level-01…09`), each listed once,
then 40 switches; then idle CPU of the whole process (`getrusage`) over 5 s. Load avg ≈ 4.

| | Result |
|---|---|
| Re-lists during 40 switches | **0** |
| Kansio's own work per switch (pause one tab, resume another) | **0.1–0.2 ms** |
| Switch, whole run-loop iteration | median 13–25 ms, worst 40–60 ms (first switch) — **over budget**, see below |
| Idle, 20 tabs, after 10 s settle | **0.10–0.12 % CPU** (5–6 ms in 5 s), 31–36 main wake-ups — same as one tab (0.15–0.39 %) |
| Idle, 20 tabs, 2 s after 40 rapid switches | 0.7–1.4 % — transient AppKit/window-server settling, gone after ~10 s |
| Cold launch | unchanged (123–139 ms) |

Where the switch goes (traced per switch): `makeKeyAndOrderFront` 8–16 ms (AppKit ordering the tab window, tab bar,
key/first-responder changes) + compositing the newly shown window; cell drawing **0 ms** (layers keep their contents);
the cost is the same for an empty folder and a 10,000-item one, and with 2 tabs (16–34 ms). Not reducible from our side
with native window tabs. Fix if wanted: a custom tab bar in one window (switching = swapping two list views), at the
price of the native tab features. (`sample` couldn't attach to the app in this environment, so the idle hunt used
counters: run-loop wake-ups, activity updates, threads.)

## 2026-11-16 — P1-1 (navigation-pane tree)

`Kansio --measure-tree $TMPDIR/kansio-fixtures` (hidden files on — the fixtures live under `/var` — so the pane holds
~370 rows: `…/T` alone has 346 subfolders). Final runs (2), load avg ≈ 5:

| Scenario | Budget | Result |
|---|---|---|
| Expand `wide-10k` (10,000 subfolders) | first < 100 ms, all < 300 ms, no iteration > 16 ms | **25.8–33.3 ms** (one insert), worst iteration 4.3–4.9 ms |
| Scroll it at 3,000 pt/s, 120 Hz, subfolder checks running | no dropped frames | **0 dropped** of 358, 319 rows checked, worst 5.5–6.4 ms |
| Jump back 10,000 rows (a screenful of new rows) | ≤ 16 ms | 12.2–15.7 ms |
| Collapse `wide-10k` | ≤ 16 ms | 47–56 ms in chunks, worst 9.4–13.1 ms (one call: 22 ms) |
| Reveal `deep/level-01…10`, warm | < 100 ms, no iteration > 16 ms | 15–22 ms after the list, worst 9.5–11.8 ms |
| Reveal, cold (11 levels listed) | same | 26–28 ms after the list; one 21–24 ms iteration with **no tree work in it** (the list's cold first navigation, see "after M12") |
| Another process creates / deletes 1,000 folders in an expanded node | in place, nothing collapses, no iteration > 16 ms | 159–213 / 181–203 ms, still expanded, worst 9.1–13.4 ms |
| `cp -R flat-10k` (10,000 files) next to listed folders, `/` stream running | < 1 ms main thread per batch | 4–5 batches reached main, longest **0.1 ms** |
| Cold launch / open `flat-10k` | unchanged | 126–141 ms / 17.8–21.9 ms median, 0 iterations > 16 ms |

How it got there (each step measured): self-drawing rows instead of image view + text field per row (a reveal or jump
lays out a screenful at once), reusing row views (`makeView`), expanding the revealed path deepest-first at ≤ 4 ms per
run-loop turn with the top (visible) expansion, the selection/scroll and the auto-collapse each in a frame of their
own (each `expandItem` costs ~1 ms with a few hundred rows, even for hidden rows), removing a big node's rows in chunks
before collapsing it (AppKit's collapse of 10k children: 22 ms in one call), coalescing watcher events off-main
(383 → 4 main-thread batches during the copy) and skipping no-op re-reads (FSEvents "must rescan" re-reads every listed
folder; an empty change used to redraw its parent row).

## 2026-11-16 — P1-0 (Settings window, SwiftUI linked)

Cold launch A/B against the M16 build (5 runs × 2 rounds each, load avg 4–6): M16 157–169 ms (one 383 ms outlier on
the very first run), P1-0 139–198 ms — no measurable change. SwiftUI lives in the dyld shared cache; the window and
its views are created only when Settings opens.

## 2026-11-16 — M16 (global view settings)

Columns are now built from `ViewSettings` at launch (5 columns, one hidden); no effect measured.
Cold launch → home listed: 127–157 ms (3 runs). `--measure-open flat-10k`, A/B against the M15 build in a separate
worktree, 4 runs each (load avg ≈ 3.5): worst iteration 18.0–19.4 ms (M15) vs 15.5–20.0 ms (M16); both have the known
single cold-first-navigation iteration (see "after M12"); first rows / full list 17 ms median.

## 2026-11-16 — M14 (status bar)

`Kansio --measure-status <folder>`: Select All, then 20 single selection changes.

| Folder | Select All → count shown | → selected size shown | Single change | Worst iteration | Hitches |
|---|---:|---:|---:|---:|---:|
| flat-10k | 3.8 ms | 3.9 ms (inline) | ≤ 0.8 ms | 11.8 ms | 0 |
| flat-100k | 2.9–3.0 ms | 12.0–12.5 ms (off-main sum) | ≤ 1.0 ms | 9.8–10.3 ms | 0 |

## 2026-11-16 — M13 (live updates)

`Kansio --measure-live $TMPDIR/kansio-fixtures`: an empty scratch folder on screen; another thread creates 1,000 files,
then deletes them.

| | Result |
|---|---|
| 1,000 creates reflected in the list | 202–221 ms |
| 1,000 deletes reflected | 88–98 ms |
| How | 33–43 + 19–30 incremental batches, **0 re-lists** |
| Worst main-thread iteration during the bursts | 8.9–13.3 ms, 0 hitches (after the window's first rows exist) |
| First rows ever shown in an *empty* window | one 16–24 ms iteration ("apply 1 row: 7 ms") — cold first use |

Cold first-use costs (open item from M12, investigated further):
- The first navigation after ~1 s idle cost 24–28 ms at its start; two fixes bring it to 17.5–22 ms: the FSEvents stream
  is now created on the watcher's queue (was 2.4 ms cold on main), and the address bar pre-creates its breadcrumb
  buttons in idle time after launch (navigating into a deeper path created and measured new buttons: 9 ms cold).
- Not App Nap (tested with an activity assertion: same numbers). What remains looks like the CPU/caches cooling down
  while idle: the same work costs 5–10× more on the first action than warm. Ideas left: move more of the navigation
  start (title/sidebar/address bar) into the first apply's run-loop turn.

## 2026-11-16 — after M12 (harness fix; open item: first navigation after idle)

`--measure-open` used to start its first navigation right after the prefetched startup folder appeared — i.e. inside the
window's first-frame iteration, which was then counted as a navigation hitch (the borderline 16.2–16.7 ms values in
M8–M12 runs). It now waits 1 s for launch to settle, like `--measure-copy` / `--measure-scroll`.

That exposed a real effect: **the first navigation after the app has been idle** (for ~1 s) can take one 17–23 ms
main-thread iteration (navigation start, then the first apply), with load average ≈ 6 on this machine; later
navigations stay ≤ 15 ms. Most likely the CPU (and caches) cooling down while idle. Open item: check whether doing
less on the main thread at navigation start (address bar/sidebar/title updates batched into the first apply) brings
the cold case under 16 ms.

| (load avg ≈ 6) | 1k | 10k | 100k |
|---|---:|---:|---:|
| Fully displayed, median of 7 | 6–8 ms | 18–24 ms | 138–152 ms |
| Worst iteration (warm runs) | ≤ 15 ms | ≤ 15 ms | ≤ 12 ms |
| First run after 1 s idle | 17–23 ms (one iteration) | 17–23 ms | ≤ 12 ms |

## 2026-11-16 — M11 (file operations under load)

`Kansio --measure-copy <fixtures folder>` copies the folder into a scratch folder next to it with cloning **off** (so
every byte is really copied), starting 1.5 s after launch, and reports duration, progress updates and main-thread hitches.

| Copy | Duration | Progress updates | Worst main-thread iteration | Hitches |
|---|---:|---:|---:|---:|
| flat-1k (1,001 items, 4 MB) | 134 ms | 6 | 10.8 ms | 0 (panel never shown: < 0.5 s) |
| flat-10k (10,001 items, 39 MB), 3 runs | 1.28–1.41 s | 28–30 | 10.7–13.9 ms | 0 |

Finding: pre-creating the panel window when an operation starts (to make the later "show" cheaper) *caused* a ~21 ms
iteration — window creation's display work landed in the same turn as the operation start. Removed; creating the
panel on first show stays under budget.

## 2026-11-16 — M6 (address bar; lighter cells)

| Scenario | Budget | M6 | M5 |
|---|---|---:|---:|
| Launch → home rows on screen (warm) | < 300 ms | 129–147 | 128–160 |
| Open 1k / 10k / 100k → fully displayed (median) | 50 / 300 / — ms | 11.6 / 27 / 129 | 9.4 / 25 / 126 |
| Main-thread apply when opening (max) | — | **2.1–2.8 ms** | 8.8–9.7 ms |
| Cold first navigation of the session, Home → full folder | ≤ 16 ms | **12–15.6 ms, 0 hitches** | 17–18 ms |
| Worst main-thread iteration while opening (6 runs × 3 folders) | ≤ 16 ms | ≤ 15.8 ms, except one 17.5 ms outlier (no apply in it; load avg ≈ 4) | ≤ 15 ms warm |
| Scroll 10k / 100k, 120 Hz | no drops | 0 / 0 dropped (max busy 11.5–11.7 ms) | 0 / 0 |

- **Lighter cells:** each cell is one view that draws its own icon and text (was `NSImageView` + `NSTextField`).
  Applying a page of new rows dropped from ~9 ms to ~2.5 ms and the cold first-navigation hitch is gone.
- **Address bar:** breadcrumb buttons and separators are pooled and re-titled per navigation (recreating them
  every navigation pushed borderline frames over 16 ms on a loaded machine). Completions and path checks run off-main.

## 2026-11-16 — M5 (navigation & history; launch follow-up)

Machine under background load during these runs (load average ≈ 5); numbers are a bit noisier than earlier sections.

| Scenario | Budget | M5 | M4 |
|---|---|---:|---:|
| Launch → home rows on screen (warm) | < 300 ms | 128–160, rows in the **first** frame | 138–168, empty first frame then rows |
| Open 1k / 10k / 100k → fully displayed (median) | 50 / 300 / — ms | 9.4 / 25.4 / 126 | 6.4 / 23.7 / 127 |
| Worst main-thread iteration while opening (warm runs) | ≤ 16 ms | ≤ 15 ms | ≤ 15.2 ms |
| Cold: first navigation of the session from a small folder to a full one | ≤ 16 ms | 17–18 ms (one iteration) | 17–22 ms |
| Leaving a 100k folder (100k → 25 rows) | ≤ 16 ms | ~8 ms apply, ≤ 16 ms iteration | 11–14 ms apply, hitches |
| Scroll 10k / 100k, 120 Hz | no drops | **0 / 0** dropped of ~600 | 1 / 1 |

What changed and why:
- **Startup prefetch:** the first folder is listed at the top of `main()`, in parallel with AppKit start-up
  (`NSApplication`, menus, window, toolbar ≈ 80 ms). Rows are applied while the window is built, so the first
  frame already has them. Launch timeline (warm): main 4 ms → menu 27 → didFinishLaunching 45 → window built 79
  (NSWindow 11, views 9, toolbar 8) → showWindow 97 → first frame ≈ 130 ms. The rest is AppKit fixed cost.
- **Old listings freed off the main thread:** dropping the last reference to a 100k-item array frees 100k strings
  (~10 ms); it now happens on a background queue.
- **Type icons rasterized off-main** (pre-warmed for common types at launch) and **kinds pre-computed off-main** for
  the first rows: first sight of new types no longer costs main-thread time.
- **Row-count changes:** `noteNumberOfRowsChanged()` inside a zero-duration `NSAnimationContext` (no fade-in, verified by
  the self-test) instead of `insertRows` (which walks every inserted row: ~4 ms for 23k). Shrinking from 100k rows still
  costs ~8 ms: AppKit visits every removed row internally (`sample`: `NSTableRowData removeRowsAtIndexes`), and
  `reloadData` is worse overall (view churn).

Remaining over budget: the cold first-navigation iteration (17–18 ms) is creating ~16 row views × 4 cells the first time
more rows are visible than the startup folder had (confirmed: starting from a full folder → 0 hitches). Proposed fix:
lighter cells — a single custom-drawn label view instead of `NSTextField`s (with accessibility labels set explicitly).

## 2026-11-16 — M4 (window shell: split view, sidebar, toolbar)

| Scenario | Budget | M4 | M3 |
|---|---|---:|---:|
| Launch → home listed (warm) | < 300 ms | 138–168 | 115–140 |
| Launch: first-frame main-thread iteration | (≤ 16 ms) | **22–26 ms** | 16–18 |
| Open 1k / 10k / 100k → fully displayed | 50 / 300 / — ms | 6.4 / 23.7 / 127 | 6.2 / 26 / 125 |
| Worst main-thread iteration while opening | ≤ 16 ms | 14.0 / 14.3 / 15.2, 0 hitches | 14.9 / 14.0 / 15.0 |
| Scroll 10k / 100k, 120 Hz | no drops | 1 / 1 dropped of 599 | 0 / 0–1 |

⚠️ **Regression: launch.** The window now builds a split view, a unified toolbar and a source-list
outline before its first frame: +~25 ms to launch and a 22–26 ms first-frame iteration (before the window
is visible, so no frame the user sees is dropped, but it's over the 16 ms rule). SF Symbols are only
~1–2 ms of it (measured by disabling them). Proposed fix (next milestone): profile launch with `sample`
and look at what AppKit builds eagerly (toolbar/titlebar, source-list vibrancy) — e.g. creating the
toolbar after the first frame, or a lighter sidebar cell. Deferring the sidebar's contents was rejected:
it would flash an empty sidebar.

## 2026-11-16 — M3 (ICU collation, coalesced loading, Type column, per-file icons)

In the app (7 runs each; drawn = end of the run-loop iteration incl. layout, drawing, CA commit):

| Scenario | Budget | M3 | Session 1 |
|---|---|---:|---:|
| Launch → home listed | < 300 ms | 115–140 warm (280 first launch after rebuild) | 111–128 |
| Open 1k → fully displayed | < 50 ms | **6.2** (one update) | 8.0 |
| Open 10k → first rows / full list | < 100 / < 300 ms | 25 / **26** (one update) | 6.3 / 33.6 |
| Open 100k → first rows / full list | < 150 ms / — | 37 / **125** | 9 / 345 |
| /Applications (per-file app icons) | — | 6.5 | — |
| Worst main-thread iteration while opening 1k/10k/100k | ≤ 16 ms | 14.9 / 14.0 / 15.0, 0 hitches | 11.7 / 12.6 / 14.4 |
| Scroll 10k / 100k at 3000 pt/s, 120 Hz, 5 s (`--measure-scroll`) | no dropped frames | 0 / 0–1 dropped of ~600 (max busy 9.9–14.1 ms) | not measured |

FileSystemKit (`kansio-bench`, median): name ranking **100k: 250 → 23 ms**, 10k: 20 → 3 ms (ICU pre-sort);
list + rank + order 100k: 344 → 116 ms. Re-sorts unchanged (≤ 11 ms).

Notes:
- First rows for 10k/100k got *later* by design: batches are coalesced for 10 ms and a partial snapshot is
  only published once a second batch shows more is coming, so folders up to ~10k items appear exactly once,
  complete and sorted, instead of flashing a partial list. Both stay far inside budget.
- Launch: the first window display (all cell views created fresh) is one 16–18 ms iteration before the window
  is on screen. Not a hitch the user can see, but it's over 16 ms; candidate for later (fewer subviews per cell).
- At 120 Hz the per-frame budget is 8.3 ms; scrolling peaks at 10–14 ms main-thread time but CA's pipelining
  keeps frames on time. Scrolling measurements start 1.5 s after launch: before that, one frame around
  ~0.4 s after launch drops due to app start-up work (not scrolling).

## 2026-11-16 — Session 1 baseline

### In the app (real window, AppKit drawing included)

Measured with `Kansio --measure-launch` / `--measure-open <folder>` (7 runs each, home → folder).
"Drawn" = end of the main run-loop iteration that applied the rows, after AppKit layout/drawing
and the Core Animation commit. Hitches = main-thread run-loop iterations longer than 16 ms.

| Scenario | Budget | Result | Status |
|---|---|---:|---|
| Launch → home folder listed (60 entries, 11 visible) | < 300 ms | 111–128 ms warm (148 ms first run; 329 ms on the very first launch after a rebuild) | ✅ |
| Open 1k → fully displayed | < 50 ms | 8.0 median (16.5 first run) | ✅ |
| Open 10k → first rows / full list | < 100 / < 300 ms | 6.3 / 33.6 median (21 / 53 first run) | ✅ |
| Open 100k → first rows | < 150 ms | 9.0 median (19 first run) | ✅ |
| Open 100k → full list (no budget) | — | 345 median | ℹ️ dominated by name ranking, see below |
| Main-thread busy, worst iteration during any of the above | ≤ 16 ms | 11.7 (1k), 12.6 (10k), 14.4 (100k), 15.4 (launch) | ✅ 0 hitches |
| Scrolling | no dropped frames | not yet measured reliably (see "Open items") | ⏳ |

### FileSystemKit (`swift run -c release kansio-bench --home --iterations 15`)

Median (min).

| Folder | Items | getattrlistbulk | FileManager | Speed-up | First batch (bulk) | Name ranks (CF, native strings) | Swift `localizedStandardCompare` sort (reference) | Re-sort by date | Re-sort by size | List + rank + order |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| flat-1k | 1000 | 0.62 (0.57) | 5.27 (4.85) | 8.5× | 0.37 | 2.13 | 3.59 | 0.05 | 0.04 | 2.70 |
| flat-10k | 10000 | 5.65 (4.76) | 56.56 (55.69) | 10.0× | 0.39 | 19.73 | 32.32 | 0.71 | 0.62 | 28.20 |
| flat-100k | 100000 | 82.79 (81.92) | 569.62 (562.96) | 6.9× | 0.39 | **250.34** | 414.04 | 10.59 | 8.89 | 344.46 |
| home | 60 | 0.03 | 0.48 | 16× | 0.04 | 0.12 | 0.18 | 0.00 | 0.00 | 0.13 |

- `getattrlistbulk` is 7–16× faster than `FileManager.contentsOfDirectory(includingPropertiesForKeys:)`
  and can stream (first ~900 entries in 0.4 ms regardless of folder size).
- **Re-sorting by any column** after load is ≤ 11 ms for 100k (integer keys + cached name rank). ✅ < 200 ms.
- **Initial Finder-order name ranking of 100k names: ~250 ms — over the 200 ms sort budget.** ❌
  It runs off-main after the first rows are already on screen, so the UI stays responsive,
  but the full 100k list appears at ~345 ms. See "Open items".

### What changed during the session (and why)

| Change | Before → after |
|---|---|
| Parallel chunked collation (12 threads) → serial | 281 → 250 ms (100k). CF serializes locale-aware comparisons behind a process-wide lock: 12 threads ≈ 1 thread. With a `nil` locale it scales 7×, but that isn't Finder order. |
| Native `CFString`s instead of bridged Swift strings for collation | 414 → 250 ms |
| Re-sort via 16-byte integer keys instead of comparing `FileItem`s in a closure | 60 → 10.6 ms (100k by date) |
| Intermediate snapshots throttled to 250 ms (each one costs a full ranking) | avoids re-ranking 100k several times on local disks |
| `reloadData()` → in-place refresh of visible cells | worst main-thread iteration 19–25 ms → 12–15 ms; 7 hitches/7 runs → 0 |
| `noteNumberOfRowsChanged()` → `insertRows/removeRows(withAnimation: [])` | rows were fading in from alpha 0 over ~0.3 s (looked slow, measured fast) |
| Icons rasterized once per type; `canDrawSubviewsIntoLayer` on cells | full-page draw 11.3 → 8.3 ms |
| Hitch monitor fixed to include AppKit drawing + CA commit | earlier numbers under-counted drawing |

### Open items (as of the baseline; 1–3 resolved in M3)

1. ~~**100k name ranking (250 ms).**~~ Resolved: ICU pre-sort, 23 ms. Options, in order of preference:
   - *ICU sort keys* (`ucol_getSortKey` from the system `libicucore`, declared by hand since the SDK
     ships no ICU headers): keys built in parallel, sorted with `memcmp`, reusable for inserts.
     Expected ≈ 30–50 ms for 100k. Needs proof it matches `localizedStandardCompare` exactly
     (test corpus) and **your OK**, since ICU isn't a documented public API on macOS.
   - Overlap ranking with listing (sort batches as they arrive, merge at the end): saves ≤ 80 ms, no new APIs.
2. Small folders produce two updates (first batch + complete) → two main-thread applies (~4 ms each). Coalesce when the listing finishes within a few ms.
3. Scrolling: build a reliable frame-time measurement (scrolling can draw outside the measured run-loop iteration). `--measure-redraw` exists but isn't conclusive yet.
4. Cold first launch after a rebuild is ~330 ms (code-signature verification of a freshly signed binary); warm launch ~115 ms.
