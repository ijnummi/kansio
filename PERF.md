# Performance log

All numbers are measured, warm cache unless stated. Times in ms.
Machine: **Mac18,5, Apple M6, 12 cores, 32 GB, macOS 27.2.1 (26B131)**, internal SSD (APFS).
Fixtures: `Tools/make-fixtures.sh` (flat folders with realistic mixed names, ~3 % subfolders).

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

### Open items

1. **100k name ranking (250 ms).** Options, in order of preference:
   - *ICU sort keys* (`ucol_getSortKey` from the system `libicucore`, declared by hand since the SDK
     ships no ICU headers): keys built in parallel, sorted with `memcmp`, reusable for inserts.
     Expected ≈ 30–50 ms for 100k. Needs proof it matches `localizedStandardCompare` exactly
     (test corpus) and **your OK**, since ICU isn't a documented public API on macOS.
   - Overlap ranking with listing (sort batches as they arrive, merge at the end): saves ≤ 80 ms, no new APIs.
2. Small folders produce two updates (first batch + complete) → two main-thread applies (~4 ms each). Coalesce when the listing finishes within a few ms.
3. Scrolling: build a reliable frame-time measurement (scrolling can draw outside the measured run-loop iteration). `--measure-redraw` exists but isn't conclusive yet.
4. Cold first launch after a rebuild is ~330 ms (code-signature verification of a freshly signed binary); warm launch ~115 ms.
