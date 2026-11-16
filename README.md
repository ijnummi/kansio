# Kansio

A fast, Explorer-style file manager for macOS, written in Swift 6 + AppKit.

- Speed is the main feature: `getattrlistbulk()` listing, progressive display, virtualized `NSTableView`,
  everything off the main thread except UI. Numbers in [PERF.md](PERF.md).
- Windows File Explorer behaviour: keyboard model, folders-first sorting, one global view setting.
- Never loses data: delete means Move to Trash.

Status: early development — see [PLAN.md](PLAN.md).

## Build (no Xcode needed — Command Line Tools are enough)

```sh
Tools/build-app.sh          # → build/Kansio.app (ad-hoc signed, Hardened Runtime)
open build/Kansio.app
Tools/test.sh               # unit tests (swift-testing)
Tools/make-fixtures.sh      # test folders in $TMPDIR/kansio-fixtures
swift run -c release kansio-bench
```

Requires macOS 15+ and Swift 6.
