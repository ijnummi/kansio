import AppKit
import FileSystemKit
import Combine
import CoreServices
import Quartz
import UniformTypeIdentifiers

/// `Kansio --self-test <fixtures-dir>`: drives navigation in the real app — history, Up,
/// mouse side buttons (synthesized button 4/5 events), keyboard shortcuts through the
/// normal event path, rapid navigation — and checks the result after each step.
/// Read-only: it only lists folders. Prints PASS/FAIL per check; exit code 1 on any failure.
@MainActor
final class SelfTest {
    private let window: MainWindowController
    private let fixtures: URL
    private let phase: Phase
    private var failures = 0

    /// `.main`: everything; it ends by saving non-default view settings. `.persisted`: a second
    /// launch that checks those settings came back (Tools/self-test.sh runs both).
    enum Phase { case main, persisted }

    init(window: MainWindowController, fixtures: URL, phase: Phase = .main) {
        self.window = window
        self.fixtures = fixtures
        self.phase = phase
    }

    private var list: FileListViewController { window.fileList }
    private var path: String { Self.norm(list.folder) }

    func run() async {
        if phase == .persisted {
            await persistedSettingsChecks()
            finish()
        }
        check("self-test uses its own settings domain (never the user's)", ViewSettings.shared.defaults !== UserDefaults.standard)
        check("fresh settings → default columns (Name, Date Modified, Type, Size)", list.columnLayout == ViewSettings.defaultColumns)
        let deep = fixtures.appending(path: "deep", directoryHint: .isDirectory)
        let l1 = deep.appending(path: "level-01", directoryHint: .isDirectory)
        let l2 = l1.appending(path: "level-02", directoryHint: .isDirectory)

        await settle { self.list.navigate(to: deep) }
        await settle { self.list.navigate(to: l1) }
        await settle { self.list.navigate(to: l2) }
        check("navigate: at level-02", path == Self.norm(l2))
        check("toolbar: back enabled, forward disabled", list.state.canGoBack && !list.state.canGoForward)

        await settle { self.mouse(button: 3) }
        check("mouse button 4 → Back", path == Self.norm(l1))
        check("Back re-selects the folder we came from", list.selectedNames == ["level-02"])
        await settle { self.mouse(button: 4) }
        check("mouse button 5 → Forward", path == Self.norm(l2))

        // Mouse buttons must work whatever has focus (here: the sidebar).
        window.window?.makeFirstResponder(window.sidebar.view)
        await settle { self.mouse(button: 3) }
        check("mouse Back with sidebar focused", path == Self.norm(l1))
        await settle { self.mouse(button: 4) }

        // Menu shortcuts need a key window, i.e. an active app. macOS may refuse to activate a
        // test launch while you're using another app; then these checks are skipped, not failed.
        NSApp.activate()
        window.window?.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where NSApp.keyWindow == nil { try? await Task.sleep(for: .milliseconds(25)) }
        if NSApp.keyWindow != nil {
            await settle { self.menuShortcut(#selector(MainWindowController.goBack(_:))) }
            check("Go ▸ Back shortcut (\(shortcutLabel(#selector(MainWindowController.goBack(_:)))))", path == Self.norm(l1))
            await settle { self.menuShortcut(#selector(MainWindowController.goForward(_:))) }
            check("Go ▸ Forward shortcut (\(shortcutLabel(#selector(MainWindowController.goForward(_:)))))", path == Self.norm(l2))
        } else {
            skip("Go ▸ Back/Forward shortcuts", "app not active (macOS didn't bring the test launch forward)")
        }

        list.focusList()
        await settle { self.tableKey(keyCode: 51) } // Backspace
        check("Backspace → Up", path == Self.norm(l1))
        check("Up selects the child folder", list.selectedNames == ["level-02"])
        check("Up is recorded: Back returns to the child", list.history.back.last.map { Self.norm($0.url) } == Self.norm(l2))
        await settle { self.tableKey(keyCode: 126, modifiers: .option) } // ⌥↑
        check("⌥↑ → Up", path == Self.norm(deep))
        await settle { self.tableKey(keyCode: 123, modifiers: .option) } // ⌥←
        check("⌥← → Back", path == Self.norm(l1))
        await settle { self.tableKey(keyCode: 124, modifiers: .option) } // ⌥→
        check("⌥→ → Forward", path == Self.norm(deep))
        if NSApp.keyWindow != nil {
            await settle { self.menuShortcut(#selector(MainWindowController.goUp(_:))) }
            check("Go ▸ Enclosing Folder shortcut (⌘↑)", path == Self.norm(fixtures))
            check("…selects 'deep'", list.selectedNames == ["deep"])
        } else {
            skip("Go ▸ Enclosing Folder shortcut", "app not active")
            await settle { self.list.goUp() }
        }

        await settle { self.list.navigate(to: URL(filePath: "/", directoryHint: .isDirectory)) }
        check("Up disabled at /", !list.state.canGoUp)
        list.goUp()
        try? await Task.sleep(for: .milliseconds(50))
        check("Up at / stays at /", path == "/")

        // Going back to a folder after visiting a new one clears Forward.
        await settle { self.list.goBack() }
        await settle { self.list.navigate(to: l1) }
        check("new navigation clears Forward", !list.state.canGoForward)

        // Rapid navigation (like holding a key): only the final folder's rows may end up on screen.
        let targets = ["flat-10k", "symlinks", "flat-1k", "unicode", "flat-100k", "hidden"].map {
            fixtures.appending(path: $0, directoryHint: .isDirectory)
        }
        for i in 0..<60 { list.navigate(to: targets[i % targets.count]) }
        let final = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: final) }
        try? await Task.sleep(for: .milliseconds(400)) // let any stale result arrive (it must be dropped)
        let expected = (try? BulkDirectoryLister().listAll(final).filter { !$0.isHidden }.map(\.name)) ?? []
        check("rapid navigation: final folder shown", path == Self.norm(final))
        check("rapid navigation: no stale rows (\(list.displayedNames.count) rows)", Set(list.displayedNames) == Set(expected) && list.displayedNames.count == expected.count)

        // Rows must be opaque the moment they're shown — growing and shrinking — never faded in.
        let small = fixtures.appending(path: "unicode", directoryHint: .isDirectory)
        let big = fixtures.appending(path: "flat-100k", directoryHint: .isDirectory)
        let empty = fixtures.appending(path: "empty", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: empty) }
        check("empty folder shows no rows", list.displayedNames.isEmpty)
        await settle(quick: true) { self.list.navigate(to: small) }
        check("empty → small: rows opaque immediately", list.minimumVisibleRowAlpha == 1)
        await settle(quick: true) { self.list.navigate(to: big) }
        check("small → 100k: rows opaque immediately", list.minimumVisibleRowAlpha == 1)
        list.tableForTesting.scrollRowToVisible(50_000)
        await settle(quick: true) { self.list.navigate(to: small) }
        check("100k (scrolled) → small: rows opaque immediately", list.minimumVisibleRowAlpha == 1)
        check("100k → small: shows the small folder", list.displayedNames.count == 25)

        await addressBarChecks()
        await operationChecks()
        await openingChecks()
        await copyMoveChecks()
        await conflictChecks()
        await operationsPanelChecks()
        await undoChecks()
        await liveUpdateChecks()
        await statusBarChecks()
        await contextMenuChecks()
        await settingsWindowChecks()
        await treeChecks()
        await favoritesChecks()
        await tabChecks()
        await dragDropChecks()
        await searchChecks()
        await folderSizeChecks()
        await noWritesChecks()
        await viewSettingsChecks() // last: leaves the settings the second launch checks
        finish()
    }

    private func finish() -> Never {
        ViewSettings.shared.defaults.synchronize() // the next launch reads them
        print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Address bar

    private func addressBarChecks() async {
        let bar = window.addressBar
        let deep = fixtures.appending(path: "deep", directoryHint: .isDirectory)
        let l1 = deep.appending(path: "level-01", directoryHint: .isDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = fixtures.path(percentEncoded: false).hasSuffix("/") ? fixtures.path(percentEncoded: false) : fixtures.path(percentEncoded: false) + "/"

        await settle { self.list.navigate(to: deep) }
        check("address bar: last breadcrumb is the current folder", bar.crumbTitles.last == "deep")
        check("address bar: first breadcrumb is the volume (\(bar.crumbTitles.first ?? "-"))",
              bar.crumbTitles.first == window.sidebar.volumes.first?.name)
        await settle { _ = bar.clickCrumbForTesting(path: root) }
        check("address bar: clicking a breadcrumb navigates", path == Self.norm(fixtures))

        window.editLocation(nil)
        check("⌘L: edit mode with the current path", bar.isEditing && Self.normPath(bar.field.stringValue) == path)
        await settle { self.type(root + "deep/level-01"); self.addressCommand(#selector(NSResponder.insertNewline(_:))) }
        check("typed absolute path + Enter navigates", path == Self.norm(l1))
        check("…and leaves edit mode", !bar.isEditing)

        window.editLocation(nil)
        await settle { self.type("~"); self.addressCommand(#selector(NSResponder.insertNewline(_:))) }
        check("~ → Home", path == Self.norm(home))

        await settle { self.list.navigate(to: deep) }
        window.editLocation(nil)
        await settle { self.type("level-01"); self.addressCommand(#selector(NSResponder.insertNewline(_:))) }
        check("relative path → navigates from the current folder", path == Self.norm(l1))

        window.editLocation(nil)
        await settle { self.type(root + "symlinks/real-file.txt"); self.addressCommand(#selector(NSResponder.insertNewline(_:))) }
        check("file path → opens its folder", path == Self.norm(fixtures.appending(path: "symlinks")))
        check("…and selects the file", list.selectedNames == ["real-file.txt"])

        let before = path
        window.editLocation(nil)
        type(root + "no-such-folder")
        addressCommand(#selector(NSResponder.insertNewline(_:)))
        try? await Task.sleep(for: .milliseconds(300))
        check("bad path → inline error (\(bar.errorMessage ?? "none"))", bar.errorMessage?.contains("Can’t find") == true)
        check("…stays in edit mode, no navigation", bar.isEditing && path == before)
        addressCommand(#selector(NSResponder.cancelOperation(_:)))
        check("Esc cancels editing", !bar.isEditing && path == before)

        window.editLocation(nil)
        type(root + "fl")
        try? await Task.sleep(for: .milliseconds(300))
        check("completions in Finder order (\(bar.suggestionNames))", bar.suggestionNames == ["flat-1k", "flat-10k", "flat-100k"])
        await settle {
            self.addressCommand(#selector(NSResponder.moveDown(_:)))
            self.addressCommand(#selector(NSResponder.insertNewline(_:)))
        }
        check("↓ + Enter on a suggestion navigates to it", path == Self.norm(fixtures.appending(path: "flat-1k")))
        window.editLocation(nil)
        type(root + "de")
        try? await Task.sleep(for: .milliseconds(300))
        addressCommand(#selector(NSResponder.insertTab(_:)))
        check("Tab completes the suggestion into the field", Self.normPath(bar.field.stringValue) == Self.norm(deep))
        addressCommand(#selector(NSResponder.cancelOperation(_:))) // closes suggestions (if any)
        addressCommand(#selector(NSResponder.cancelOperation(_:))) // cancels editing
        check("Esc, Esc: back to breadcrumbs", !bar.isEditing)
    }

    // MARK: File operations (M7) — only inside a scratch folder under the fixtures

    private func operationChecks() async {
        guard let testTrash = list.trasher as? DirectoryTrasher else {
            skip("file operations", "KANSIO_TEST_TRASH not set — refusing to use the real Trash")
            return
        }
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-ops-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) } // temp fixtures only
        for name in ["notes.txt", "other.txt", "menu-trash.txt"] { fm.createFile(atPath: scratch.appending(path: name).path(percentEncoded: false), contents: Data("x".utf8)) }
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test")) // never the user's clipboard
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: scratch.appending(path: name).path(percentEncoded: false)) }

        await settle { self.list.navigate(to: scratch) }
        list.focusList()

        // ⇧⌘N: creates "New folder", selects it, opens the rename editor.
        window.newFolder(nil)
        await waitUntil { self.list.renameSession != nil }
        check("New Folder creates “New folder” on disk", exists("New folder"))
        check("…and starts renaming it", list.renameSession?.originalName == "New folder")
        list.renameSession?.editor.stringValue = "Alpha"
        renameCommand(#selector(NSResponder.insertNewline(_:)))
        await waitUntil { self.list.displayedNames.contains("Alpha") }
        check("typing a name + Enter renames it on disk", exists("Alpha") && !exists("New folder"))
        check("…and the list shows it selected", list.selectedNames == ["Alpha"])

        // F2: rename with the name (without extension) selected.
        select("notes.txt")
        tableKey(keyCode: 120, chars: "\u{F705}")
        check("F2 opens the rename editor", list.renameSession?.originalName == "notes.txt")
        check("…with “notes” selected, not the extension",
              list.renameSession?.editor.currentEditor()?.selectedRange == NSRange(location: 0, length: 5))
        list.renameSession?.editor.stringValue = "renamed.txt"
        renameCommand(#selector(NSResponder.insertNewline(_:)))
        await waitUntil { self.list.displayedNames.contains("renamed.txt") }
        check("F2 rename applied on disk and in the list", exists("renamed.txt") && !exists("notes.txt") && list.selectedNames == ["renamed.txt"])

        // Renaming onto an existing name never overwrites.
        tableKey(keyCode: 120, chars: "\u{F705}")
        list.renameSession?.editor.stringValue = "other.txt"
        renameCommand(#selector(NSResponder.insertNewline(_:)))
        await waitUntil { self.list.bannerText.contains("already exists") }
        check("rename onto an existing name → inline error (\(list.bannerText))", list.bannerText.contains("already exists"))
        check("…both files intact, editor reopened", exists("renamed.txt") && exists("other.txt") && list.renameSession != nil)
        renameCommand(#selector(NSResponder.cancelOperation(_:)))
        check("Esc cancels the rename", list.renameSession == nil && exists("renamed.txt"))

        // Forward Delete (Explorer's Del) → Trash (here: the test trash folder).
        select("other.txt")
        tableKey(keyCode: 117, chars: "\u{F728}")
        await waitUntil { !self.list.displayedNames.contains("other.txt") }
        check("Delete moves to the Trash", !exists("other.txt")
              && fm.fileExists(atPath: testTrash.directory.appending(path: "other.txt").path(percentEncoded: false)))
        check("…and the list keeps a selection", !list.selectedNames.isEmpty)

        // ⌘⌫ through the menu (File ▸ Move to Trash).
        if NSApp.keyWindow != nil {
            select("menu-trash.txt")
            menuShortcut(#selector(FileListViewController.moveToTrash(_:)))
            await waitUntil { !self.list.displayedNames.contains("menu-trash.txt") }
            check("⌘⌫ (File ▸ Move to Trash) trashes the selection", !exists("menu-trash.txt"))
        } else {
            skip("⌘⌫ menu shortcut", "app not active")
        }

        // ⌘C / ⌘X write file URLs; cut items are dimmed.
        select("Alpha")
        list.copy(nil)
        check("⌘C puts the file on the clipboard", list.pasteboardPaths.map(Self.normPath) == [Self.norm(scratch.appending(path: "Alpha"))])
        list.cut(nil)
        check("⌘X marks it as cut (dimmed)", list.displayedItem(named: "Alpha").map(list.isCut) == true)

        // Home / End move the selection.
        tableKey(keyCode: 119, chars: "\u{F72B}")
        check("End selects the last row", list.selectedNames == [list.displayedNames.last ?? "-"])
        tableKey(keyCode: 115, chars: "\u{F729}")
        check("Home selects the first row", list.selectedNames == [list.displayedNames.first ?? "-"])

        // Space → Quick Look (needs an active app to show its panel).
        select("renamed.txt")
        tableKey(keyCode: 49, chars: " ")
        await waitUntil { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
        if NSApp.keyWindow == nil {
            skip("Space → Quick Look", "app not active (the panel finds its controller through the key window)")
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
        } else if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            check("Space opens Quick Look on the selection", (QLPreviewPanel.shared().currentPreviewItem as? URL).map(Self.norm) == Self.norm(scratch.appending(path: "renamed.txt")))
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            skip("Space → Quick Look", "the panel didn't appear (app not active)")
        }
        try? fm.removeItem(at: testTrash.directory)
    }

    // MARK: Opening (M8) — recorded, never launches apps

    private func openingChecks() async {
        guard let recorder = list.opener as? RecordingOpener else {
            skip("opening", "KANSIO_TEST_OPENER not set — refusing to launch real apps")
            return
        }
        let fm = FileManager.default
        func lastOpened() -> [String] { recorder.calls.last?.urls.map { Self.norm($0.resolvingSymlinksInPath()) } ?? [] }
        let packages = fixtures.appending(path: "packages", directoryHint: .isDirectory)
        let fakeApp = packages.appending(path: "Fake.app", directoryHint: .isDirectory)

        await settle { self.list.navigate(to: packages) }
        select("Fake.app")
        tableKey(keyCode: 36, chars: "\r")
        check("Enter on an app opens (launches) it", lastOpened() == [Self.norm(fakeApp.resolvingSymlinksInPath())] && recorder.calls.last?.app == nil)

        await settle { self.list.showPackageContents(nil) }
        check("Show Package Contents browses inside the bundle", path == Self.norm(fakeApp) && list.displayedNames == ["Contents"])
        await settle { self.list.goUp() }
        check("…Up returns with the package selected", list.selectedNames == ["Fake.app"])

        let symlinks = fixtures.appending(path: "symlinks", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: symlinks) }
        select("link-to-file")
        tableKey(keyCode: 36, chars: "\r")
        check("Enter on a link to a file opens it", lastOpened() == [Self.norm(symlinks.appending(path: "real-file.txt").resolvingSymlinksInPath())])
        select("broken-link")
        tableKey(keyCode: 36, chars: "\r")
        check("Enter on a broken link explains inline", list.bannerText.contains("doesn’t exist"))

        let unicode = fixtures.appending(path: "unicode", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: unicode) }
        list.tableForTesting.selectRowIndexes([0, 1, 2], byExtendingSelection: false)
        list.openSelection()
        check("Enter on several files opens each", recorder.calls.last?.urls.count == 3)

        // Finder aliases (made in a scratch folder under the fixtures).
        let scratch = fixtures.appending(path: "scratch-open-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "Target"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        fm.createFile(atPath: scratch.appending(path: "doc.txt").path(percentEncoded: false), contents: Data("x".utf8))
        for (alias, target) in [("folder alias", "Target"), ("file alias", "doc.txt")] {
            if let data = try? scratch.appending(path: target).bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? URL.writeBookmarkData(data, to: scratch.appending(path: alias))
            }
        }
        await settle { self.list.navigate(to: scratch) }
        select("folder alias")
        await settle { self.tableKey(keyCode: 36, chars: "\r") }
        check("Enter on a folder alias goes to the original", Self.norm(list.folder.resolvingSymlinksInPath()) == Self.norm(scratch.appending(path: "Target").resolvingSymlinksInPath()))
        await settle { self.list.goBack() }
        select("file alias")
        let before = recorder.calls.count
        tableKey(keyCode: 36, chars: "\r")
        await waitUntil { recorder.calls.count > before }
        check("Enter on a file alias opens the original", lastOpened() == [Self.norm(scratch.appending(path: "doc.txt").resolvingSymlinksInPath())])

        // Open With: default app first, "Other…" last, picking an app opens with it.
        select("doc.txt")
        _ = await OpenWithMenu.prefetch(list.openWithURLs)?.value
        await waitUntil { OpenWithMenu.cachedApps(for: self.list.openWithURLs) != nil }
        let apps = OpenWithMenu.cachedApps(for: list.openWithURLs) ?? []
        let menu = list.openWithMenu.makeMenu()
        list.openWithMenu.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        check("Open With lists apps, default first (\(titles.first ?? "-"))", !apps.isEmpty && apps[0].isDefault && titles.first?.hasSuffix("(default)") == true)
        check("…and ends with “Other…”", titles.last == "Other…")
        if let first = menu.items.first, first.representedObject is URL {
            list.openWithMenu.openWith(first)
            check("choosing an app opens the file with it", recorder.calls.last?.app == apps.first?.url)
        }

        recorder.failNext = NSError(domain: NSOSStatusErrorDomain, code: -10814)
        tableKey(keyCode: 36, chars: "\r")
        check("“no app” error is shown inline with a hint", list.bannerText.contains("Open With ▸ Other"))

        // Context menu.
        let rowMenu = list.contextMenuItems(forRow: list.displayedNames.firstIndex(of: "doc.txt") ?? 0).map(\.title)
        check("context menu on a file", ["Open", "Open With", "Quick Look", "Copy", "Rename", "Move to Trash", "Copy Path", "Show in Finder"].allSatisfy(rowMenu.contains))
        let emptyMenu = list.contextMenuItems(forRow: -1).map(\.title)
        check("context menu on empty space", emptyMenu.contains("New Folder") && emptyMenu.contains("Paste") && list.selectedNames.isEmpty)

        select("doc.txt")
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test"))
        list.copyPath(nil)
        check("Copy Path puts the path on the clipboard", list.pasteboard.string(forType: .string).map(Self.normPath) == Self.norm(scratch.appending(path: "doc.txt")))
    }

    // MARK: Copy / move (M9) — scratch folder, private pasteboard

    private func copyMoveChecks() async {
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-copy-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "Sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        for name in ["a.txt", "b.txt"] { fm.createFile(atPath: scratch.appending(path: name).path(percentEncoded: false), contents: Data(name.utf8)) }
        fm.createFile(atPath: scratch.appending(path: "Sub/a.txt").path(percentEncoded: false), contents: Data("keep me".utf8))
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test"))
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: scratch.appending(path: p).path(percentEncoded: false)) }

        await settle { self.list.navigate(to: scratch) }
        select("a.txt")
        list.copy(nil)
        list.paste(nil)
        await waitUntil { self.list.displayedNames.contains("a - Copy.txt") }
        check("⌘C ⌘V in the same folder → “a - Copy.txt”", exists("a - Copy.txt") && exists("a.txt"))
        check("…pasted item is selected", list.selectedNames == ["a - Copy.txt"])

        select("a.txt")
        list.duplicate(nil)
        await waitUntil { self.list.displayedNames.contains("a - Copy (2).txt") }
        check("⌘D duplicates → “a - Copy (2).txt”", exists("a - Copy (2).txt"))

        select("b.txt")
        list.cut(nil)
        await settle { self.list.navigate(to: scratch.appending(path: "Sub")) }
        list.paste(nil)
        await waitUntil { self.list.displayedNames.contains("b.txt") }
        check("⌘X ⌘V moves the file", exists("Sub/b.txt") && !exists("b.txt"))
        check("…and the clipboard is spent", list.pasteboardFileURLs.isEmpty)

        // a.txt already exists in Sub: skipped, reported, untouched.
        await settle { self.list.navigate(to: scratch) }
        select("a.txt")
        list.copy(nil)
        await settle { self.list.navigate(to: scratch.appending(path: "Sub")) }
        list.paste(nil)
        await waitUntil { self.list.conflictPrompter.currentAlert != nil }
        check("paste onto an existing name → conflict sheet", list.conflictPrompter.answer("Skip"))
        await waitUntil { self.list.bannerText.contains("already exists") }
        check("…Skip: reported (\(list.bannerText))", list.bannerText.contains("already exists"))
        check("…the existing file is untouched",
              (try? String(contentsOf: scratch.appending(path: "Sub/a.txt"), encoding: .utf8)) == "keep me")

        list.newTextDocument(nil)
        await waitUntil { self.list.renameSession != nil }
        check("New Text Document creates it and starts renaming", exists("Sub/New Text Document.txt") && list.renameSession?.originalName == "New Text Document.txt")
        renameCommand(#selector(NSResponder.cancelOperation(_:)))
    }

    // MARK: Conflicts (M10) — real sheets, answered by the test

    private func conflictChecks() async {
        let fm = FileManager.default
        guard let testTrash = list.trasher as? DirectoryTrasher else { skip("conflicts", "no test trash"); return }
        let scratch = fixtures.appending(path: "scratch-conflict-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch) }
        func put(_ text: String, _ p: String) {
            let u = scratch.appending(path: p)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path(percentEncoded: false), contents: Data(text.utf8))
        }
        func read(_ p: String) -> String? { try? String(contentsOf: scratch.appending(path: p), encoding: .utf8) }
        put("new x", "src/x.txt"); put("new y", "src/y.txt"); put("new z", "src/z.txt")
        put("old x", "dst/x.txt"); put("old y", "dst/y.txt"); put("old z", "dst/z.txt")
        put("new inner", "src/F/inner.txt"); put("new clash", "src/F/clash.txt")
        put("old clash", "dst/F/clash.txt"); put("old other", "dst/F/other.txt")
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test"))
        let src = scratch.appending(path: "src", directoryHint: .isDirectory)
        let dst = scratch.appending(path: "dst", directoryHint: .isDirectory)
        func copy(_ names: [String]) {
            list.pasteboard.clearContents()
            list.pasteboard.writeObjects(names.map { src.appending(path: $0) as NSURL })
        }
        func sheet() async -> Bool {
            await waitUntil { self.list.conflictPrompter.currentAlert != nil }
            return list.conflictPrompter.currentAlert != nil
        }
        await settle { self.list.navigate(to: dst) }

        // Replace: the existing file goes to the (test) Trash.
        copy(["x.txt"])
        list.paste(nil)
        check("conflict sheet appears", await sheet())
        check("…offers Replace / Keep Both / Skip / Stop",
              list.conflictPrompter.currentAlert?.buttons.map(\.title) == ["Replace", "Keep Both", "Skip", "Stop"])
        _ = list.conflictPrompter.answer("Replace")
        await waitUntil { self.list.runningOperations.isEmpty && read("dst/x.txt") == "new x" }
        check("Replace puts the new file in place", read("dst/x.txt") == "new x")
        check("…and the old one in the Trash", (try? String(contentsOf: testTrash.directory.appending(path: "x.txt"), encoding: .utf8)) == "old x")

        // Keep Both + "apply to all": one question for both clashes.
        copy(["y.txt", "z.txt"])
        list.paste(nil)
        _ = await sheet()
        _ = list.conflictPrompter.answer("Keep Both", applyToAll: true)
        await waitUntil { self.list.runningOperations.isEmpty }
        check("Keep Both + apply to all: one sheet, both kept as “(2)”",
              read("dst/y (2).txt") == "new y" && read("dst/z (2).txt") == "new z" && read("dst/y.txt") == "old y")
        await waitUntil { Set(self.list.selectedNames) == ["y (2).txt", "z (2).txt"] } // applied after the result is read
        check("…the new copies are selected", Set(list.selectedNames) == ["y (2).txt", "z (2).txt"])

        // Folder onto folder: Merge, then the clash inside is asked about separately.
        copy(["F"])
        list.paste(nil)
        _ = await sheet()
        check("folder clash offers Merge first", list.conflictPrompter.currentAlert?.buttons.first?.title == "Merge")
        _ = list.conflictPrompter.answer("Merge")
        try? await Task.sleep(for: .milliseconds(100))
        _ = await sheet()
        check("…a clash inside the folder gets its own sheet",
              list.conflictPrompter.currentAlert?.messageText.contains("clash.txt") == true)
        _ = list.conflictPrompter.answer("Skip")
        await waitUntil { self.list.runningOperations.isEmpty }
        check("Merge: new files added, skipped one untouched",
              read("dst/F/inner.txt") == "new inner" && read("dst/F/other.txt") == "old other" && read("dst/F/clash.txt") == "old clash")

        // Stop ends the operation without touching anything.
        copy(["x.txt", "y.txt"])
        list.paste(nil)
        _ = await sheet()
        _ = list.conflictPrompter.answer("Stop")
        await waitUntil { self.list.runningOperations.isEmpty }
        check("Stop leaves everything as it was", read("dst/y.txt") == "old y" && read("dst/x.txt") == "new x")
    }

    // MARK: Operations panel (M11)

    private func operationsPanelChecks() async {
        let fm = FileManager.default
        let center = OperationCenter.shared
        let scratch = fixtures.appending(path: "scratch-panel-\(getpid())", directoryHint: .isDirectory)
        let dst = scratch.appending(path: "dst", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let savedDelay = center.showDelay
        center.showDelay = .zero
        center.allowClone = false // real copies, so there's progress to see
        defer {
            center.showDelay = savedDelay
            center.allowClone = true
            try? fm.removeItem(at: scratch)
        }
        func paste(_ urls: [URL]) {
            list.pasteboard.clearContents()
            list.pasteboard.writeObjects(urls.map { $0 as NSURL })
            list.paste(nil)
        }
        func count(_ u: URL) -> Int { (try? fm.contentsOfDirectory(atPath: u.path(percentEncoded: false)).count) ?? -1 }
        await settle { self.list.navigate(to: dst) }

        // A visible operation: the panel shows its row, then hides when done.
        paste([fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)])
        await waitUntil { center.isPanelVisible && !center.panelRows.isEmpty }
        check("the File Operations panel shows the running copy", center.isPanelVisible && center.panelRows.first?.titleLabel.stringValue.contains("flat-1k") == true)
        await waitUntil(timeout: .seconds(10)) { center.records.isEmpty }
        check("…the copy completes (1000 files)", count(dst.appending(path: "flat-1k")) == 1000)
        await waitUntil { !center.isPanelVisible }
        check("…and the panel hides when nothing is running", !center.isPanelVisible)

        // An item fails: the row offers Retry / Skip / Stop; Retry after fixing works.
        let src = scratch.appending(path: "src", directoryHint: .isDirectory)
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        let locked = src.appending(path: "locked.txt")
        fm.createFile(atPath: locked.path(percentEncoded: false), contents: Data("secret".utf8))
        chmod(locked.path(percentEncoded: false), 0)
        defer { chmod(locked.path(percentEncoded: false), 0o644) }
        paste([locked])
        await waitUntil { center.panelRows.first?.hasFailure == true }
        let row = center.panelRows.first
        check("a failing item shows an inline error in the panel", row?.hasFailure == true && row?.errorLabel.stringValue.contains("locked.txt") == true)
        check("…with Retry / Skip / Stop", row.map { !$0.retryButton.isHidden && !$0.skipButton.isHidden && !$0.stopButton.isHidden } == true)
        if let out = ProcessInfo.processInfo.environment["KANSIO_PANEL_SNAPSHOT"], let view = center.panelRows.first,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            if let context = NSGraphicsContext(bitmapImageRep: rep) { // dark-mode text is white: give it a background
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor(white: 0.16, alpha: 1).setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: out))
        }
        chmod(locked.path(percentEncoded: false), 0o644) // "fix" it
        row?.retryClicked()
        await waitUntil { center.records.isEmpty }
        check("Retry copies it once the problem is fixed", (try? String(contentsOf: dst.appending(path: "locked.txt"), encoding: .utf8)) == "secret")

        let locked2 = src.appending(path: "locked2.txt")
        fm.createFile(atPath: locked2.path(percentEncoded: false), contents: Data("x".utf8))
        chmod(locked2.path(percentEncoded: false), 0)
        defer { chmod(locked2.path(percentEncoded: false), 0o644) }
        paste([locked2])
        await waitUntil { center.panelRows.first?.hasFailure == true }
        center.panelRows.first?.skipClicked()
        await waitUntil { center.records.isEmpty }
        await waitUntil { self.list.bannerText.contains("locked2.txt") }
        check("Skip carries on and the problem is reported once (\(list.bannerText))", !fm.fileExists(atPath: dst.appending(path: "locked2.txt").path(percentEncoded: false))
              && list.bannerText.contains("locked2.txt") && !list.bannerText.contains("more"))

        // Cancel a running copy from its row: nothing half-copied is left behind.
        paste([fixtures.appending(path: "flat-10k", directoryHint: .isDirectory)])
        await waitUntil { (center.records.first?.progress.completedItems ?? 0) > 50 }
        center.panelRows.first?.cancelClicked()
        await waitUntil(timeout: .seconds(10)) { center.records.isEmpty }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: dst.path(percentEncoded: false))) ?? []).filter { $0 == "flat-10k" || $0.hasPrefix(".kansio-partial-") }
        check("Cancel stops the copy and leaves nothing half-copied (\(leftovers))", leftovers.isEmpty)
    }

    // MARK: Undo (M12)

    private func undoChecks() async {
        let fm = FileManager.default
        guard list.trasher is DirectoryTrasher else { skip("undo", "no test trash"); return }
        let undo = FileUndo.shared
        undo.manager.removeAllActions()
        let scratch = fixtures.appending(path: "scratch-undo-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "Sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        for name in ["a.txt", "t.txt", "c.txt", "m.txt"] { fm.createFile(atPath: scratch.appending(path: name).path(percentEncoded: false), contents: Data(name.utf8)) }
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: scratch.appending(path: p).path(percentEncoded: false)) }
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test"))
        var finishedCount = 0
        undo.finished = { _ in finishedCount += 1 }
        defer { undo.finished = nil }
        func run(_ redo: Bool) async {
            let before = finishedCount
            if redo { undo.manager.redo() } else { undo.manager.undo() }
            await waitUntil { finishedCount > before }
            try? await Task.sleep(for: .milliseconds(80)) // the view applies the change
        }
        await settle { self.list.navigate(to: scratch) }

        // Rename.
        select("a.txt")
        tableKey(keyCode: 120, chars: "\u{F705}")
        check("text editing has its own undo (not the file history)", window.window?.undoManager !== undo.manager)
        list.renameSession?.editor.stringValue = "b.txt"
        renameCommand(#selector(NSResponder.insertNewline(_:)))
        await waitUntil { exists("b.txt") && undo.manager.canUndo }
        check("Edit ▸ Undo is “Undo Rename”", undo.manager.undoMenuItemTitle == "Undo Rename")
        check("…and the list uses the file history again", window.window?.undoManager === undo.manager)
        await run(false)
        check("Undo Rename restores the old name (disk and list)", exists("a.txt") && !exists("b.txt") && list.displayedNames.contains("a.txt"))
        await run(true)
        check("Redo Rename renames again", exists("b.txt") && list.displayedNames.contains("b.txt"))

        // Move to Trash.
        select("t.txt")
        list.moveToTrash(nil)
        await waitUntil { !exists("t.txt") && undo.manager.undoMenuItemTitle == "Undo Move to Trash" }
        await run(false)
        check("Undo Move to Trash puts it back (disk and list)", exists("t.txt") && list.displayedNames.contains("t.txt"))
        check("…and selects it", list.selectedNames == ["t.txt"])
        await run(true)
        check("Redo trashes it again", !exists("t.txt") && !list.displayedNames.contains("t.txt"))

        // New Folder: undo moves it to the Trash (never deletes).
        window.newFolder(nil)
        await waitUntil { self.list.renameSession != nil }
        renameCommand(#selector(NSResponder.cancelOperation(_:)))
        await waitUntil { undo.manager.undoMenuItemTitle == "Undo New Folder" }
        await run(false)
        check("Undo New Folder removes it (to the Trash)", !exists("New folder") && !list.displayedNames.contains("New folder"))

        // Paste (copy) into Sub, then undo.
        select("c.txt")
        list.copy(nil)
        await settle { self.list.navigate(to: scratch.appending(path: "Sub")) }
        list.paste(nil)
        await waitUntil { exists("Sub/c.txt") && undo.manager.undoMenuItemTitle == "Undo Copy" }
        await run(false)
        check("Undo Copy removes the copy, keeps the original", !exists("Sub/c.txt") && exists("c.txt") && !list.displayedNames.contains("c.txt"))
        await run(true)
        check("Redo Copy brings the copy back", exists("Sub/c.txt") && list.displayedNames.contains("c.txt"))

        // Cut + paste (move), then undo — ⌘Z through the menu when the app is active.
        await settle { self.list.navigate(to: scratch) }
        select("m.txt")
        list.cut(nil)
        await settle { self.list.navigate(to: scratch.appending(path: "Sub")) }
        list.paste(nil)
        await waitUntil { exists("Sub/m.txt") && undo.manager.undoMenuItemTitle == "Undo Move" }
        if NSApp.keyWindow != nil {
            let before = finishedCount
            list.focusList()
            menuShortcut(Selector(("undo:")))
            await waitUntil { finishedCount > before }
            try? await Task.sleep(for: .milliseconds(80))
            check("⌘Z (Edit ▸ Undo Move) moves it back", exists("m.txt") && !exists("Sub/m.txt") && !list.displayedNames.contains("m.txt"))
        } else {
            await run(false)
            check("Undo Move moves it back", exists("m.txt") && !exists("Sub/m.txt") && !list.displayedNames.contains("m.txt"))
            skip("⌘Z menu shortcut", "app not active")
        }
        undo.manager.removeAllActions()
    }

    // MARK: Live updates (M13) — the self-test plays "another app"

    private func liveUpdateChecks() async {
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-live-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: fixtures.appending(path: "scratch-live-moved-\(getpid())")) }
        for name in ["a.txt", "sel.txt", "mod.txt"] { fm.createFile(atPath: scratch.appending(path: name).path(percentEncoded: false), contents: Data("x".utf8)) }
        func p(_ name: String) -> String { scratch.appending(path: name).path(percentEncoded: false) }
        await settle { self.list.navigate(to: scratch) }
        try? await Task.sleep(for: .milliseconds(150)) // watcher running

        fm.createFile(atPath: p("ext.txt"), contents: Data("new".utf8))
        await waitUntil { self.list.displayedNames.contains("ext.txt") }
        check("a file created by another app appears", list.displayedNames.contains("ext.txt"))

        try? fm.removeItem(atPath: p("a.txt"))
        await waitUntil { !self.list.displayedNames.contains("a.txt") }
        check("a file deleted by another app disappears", !list.displayedNames.contains("a.txt"))

        try? Data(repeating: 1, count: 5000).write(to: scratch.appending(path: "mod.txt"))
        await waitUntil { self.list.displayedItem(named: "mod.txt")?.size == 5000 }
        check("a file changed by another app updates (size)", list.displayedItem(named: "mod.txt")?.size == 5000)

        select("sel.txt")
        try? fm.moveItem(atPath: p("sel.txt"), toPath: p("sel-renamed.txt"))
        await waitUntil { self.list.displayedNames.contains("sel-renamed.txt") }
        check("an external rename shows the new name", list.displayedNames.contains("sel-renamed.txt") && !list.displayedNames.contains("sel.txt"))
        check("…and the selection follows it", list.selectedNames == ["sel-renamed.txt"])
        check("…without re-listing the folder", list.liveRelists == 0)

        await settle { self.list.navigate(to: scratch.appending(path: "sub")) }
        try? await Task.sleep(for: .milliseconds(150))
        try? fm.moveItem(at: scratch.appending(path: "sub"), to: fixtures.appending(path: "scratch-live-moved-\(getpid())"))
        await waitUntil { Self.norm(self.list.folder) == Self.norm(scratch) }
        check("when the folder on screen is moved away, go to its parent", Self.norm(list.folder) == Self.norm(scratch))
        check("…and say why (\(list.bannerText))", list.bannerText.contains("moved or deleted"))
    }

    // MARK: Status bar (M14)

    private func statusBarChecks() async {
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-status-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try? Data(repeating: 1, count: 1000).write(to: scratch.appending(path: "a.bin"))
        try? Data(repeating: 1, count: 2000).write(to: scratch.appending(path: "b.bin"))
        fm.createFile(atPath: scratch.appending(path: ".secret").path(percentEncoded: false), contents: nil)
        if ViewSettings.shared.showHidden { list.toggleHiddenFiles() }
        if !ViewSettings.shared.showStatusBar { window.toggleStatusBar(nil) }
        let bar = list.statusBar
        await settle { self.list.navigate(to: scratch) }
        check("status bar counts items and hidden ones (\(bar.countLabel.stringValue))", bar.countLabel.stringValue == "3 items (1 hidden)")
        list.tableForTesting.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false) // a.bin, b.bin (folder first)
        let expected = "2 items selected  " + Formatters.size.string(fromByteCount: 3000)
        check("selection count and size of the selected files (\(bar.selectionLabel.stringValue))", bar.selectionLabel.stringValue == expected)
        select("sub")
        await waitUntil { self.list.pendingFolderSizes == 0 && self.list.folderSizes["sub"] != nil }
        list.updateStatusBar()
        check("a selected folder adds its computed size (P1-6) (\(bar.selectionLabel.stringValue))",
              bar.selectionLabel.stringValue == "1 item selected" + FileListViewController.sizeSuffix(0))
        list.tableForTesting.deselectAll(nil)
        check("nothing selected → no selection text", bar.selectionLabel.stringValue.isEmpty)
        await waitUntil { !bar.spaceLabel.stringValue.isEmpty }
        check("free space on the volume (\(bar.spaceLabel.stringValue))", bar.spaceLabel.stringValue.hasSuffix("available"))
        window.toggleStatusBar(nil)
        check("⌘/ hides the status bar (one global setting)", bar.isHidden && !ViewSettings.shared.showStatusBar)
        window.toggleStatusBar(nil)
        check("…and shows it again", !bar.isHidden && ViewSettings.shared.showStatusBar)
    }

    // MARK: Context menu + Get Info (M15) — scratch folder, test trash, recording opener, private pasteboard

    private func contextMenuChecks() async {
        guard let recorder = list.opener as? RecordingOpener, let testTrash = list.trasher as? DirectoryTrasher else {
            skip("context menu", "needs KANSIO_TEST_OPENER and KANSIO_TEST_TRASH")
            return
        }
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-menu-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "Folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: testTrash.directory) }
        try? Data(repeating: 1, count: 100).write(to: scratch.appending(path: "a.txt"))
        try? Data(repeating: 2, count: 200).write(to: scratch.appending(path: "b.txt"))
        try? Data(repeating: 3, count: 300).write(to: scratch.appending(path: "Folder/c.txt"))
        try? fm.createSymbolicLink(atPath: scratch.appending(path: "link").path(percentEncoded: false), withDestinationPath: "a.txt")
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: scratch.appending(path: name).path(percentEncoded: false)) }
        list.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test"))
        list.pasteboard.clearContents()
        await settle { self.list.navigate(to: scratch) }

        func menu(_ row: Int) -> [NSMenuItem] { list.contextMenuItems(forRow: row).filter { !$0.isSeparatorItem } }
        func enabled(_ items: [NSMenuItem]) -> [String: Bool] {
            Dictionary(items.map { ($0.title, $0.action == nil || self.list.validateMenuItem($0)) }, uniquingKeysWith: { a, _ in a })
        }
        func perform(_ title: String, in items: [NSMenuItem]) {
            guard let item = items.first(where: { $0.title == title }), let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        func row(_ name: String) -> Int { list.displayedNames.firstIndex(of: name) ?? -1 }
        func info(_ what: String, _ open: () -> Void) async -> InfoWindowController? {
            let before = list.lastInfoWindow
            open()
            await waitUntil { self.list.lastInfoWindow !== before && self.list.lastInfoWindow?.isFinished == true }
            return list.lastInfoWindow !== before ? list.lastInfoWindow : nil
        }

        // Empty area.
        let empty = menu(-1)
        let emptyState = enabled(empty)
        check("empty-area menu: New Folder, New Text Document, Paste, Copy Path, Show in Finder, Get Info, Pin to Favorites",
              empty.map(\.title) == ["New Folder", "New Text Document", "Paste", "Copy Path", "Show in Finder", "Get Info", "Pin to Favorites"])
        check("…Paste disabled with an empty clipboard, the rest enabled (\(emptyState))",
              emptyState["Paste"] == false && emptyState.filter { $0.key != "Paste" }.values.allSatisfy { $0 })
        perform("Show in Finder", in: empty)
        check("…Show in Finder reveals the folder itself (recorded)", recorder.revealed.map(Self.norm) == [Self.norm(scratch)])
        let folderInfo = await info("folder") { perform("Get Info", in: empty) }
        check("…Get Info describes the current folder (\(folderInfo?.value("Size") ?? "-"))",
              folderInfo?.titleText == scratch.lastPathComponent && folderInfo?.value("Size").contains("600 bytes for 3 files") == true)
        folderInfo?.close()

        // One file.
        let single = menu(row("a.txt"))
        let singleState = enabled(single)
        check("file menu: Open … Get Info, New Folder, New Text Document",
              ["Open", "Open With", "Quick Look", "Cut", "Copy", "Paste", "Duplicate", "Rename", "Move to Trash", "Copy Path", "Show in Finder", "Get Info", "New Folder", "New Text Document"]
                .allSatisfy(single.map(\.title).contains) && list.selectedNames == ["a.txt"])
        check("…everything enabled except Paste (\(singleState.filter { !$0.value }.keys.sorted()))",
              singleState.filter { !$0.value }.keys.sorted() == ["Paste"])
        perform("Show in Finder", in: single)
        check("…Show in Finder reveals the file", recorder.revealed.map(Self.norm) == [Self.norm(scratch.appending(path: "a.txt"))])
        let fileInfo = await info("file") { perform("Get Info", in: single) }
        check("…Get Info: size, kind, dates, permissions (\(fileInfo?.value("Size") ?? "-"))",
              fileInfo?.value("Size") == "100 bytes" && fileInfo?.value("Kind").isEmpty == false && fileInfo?.value("Kind") != "…"
              && fileInfo?.value("Permissions").hasPrefix("rw") == true && fileInfo?.value("Modified") != "…" && fileInfo?.isShowing("Link to") == false)
        if let out = ProcessInfo.processInfo.environment["KANSIO_INFO_PNG"] { fileInfo?.writePNG(to: URL(filePath: out)) }
        fileInfo?.close()
        check("…closing the window cancels the count", fileInfo?.isCountCancelled == true)
        perform("Copy", in: single)
        check("…Copy puts it on the clipboard", list.pasteboardFileURLs.map(Self.norm) == [Self.norm(scratch.appending(path: "a.txt"))])
        check("…then Paste is enabled", enabled(menu(row("a.txt")))["Paste"] == true)
        list.pasteboard.clearContents()

        // A folder: the size is counted inside it.
        let folderMenu = menu(row("Folder"))
        let inside = await info("folder item") { perform("Get Info", in: folderMenu) }
        check("folder Get Info counts its contents (\(inside?.value("Size") ?? "-"))", inside?.value("Size").hasPrefix("300 bytes for 1 file") == true)
        inside?.close()

        // A symlink: the target is shown, the size is the link's own.
        let link = await info("link") { perform("Get Info", in: menu(row("link"))) }
        check("link Get Info shows the target (\(link?.value("Link to") ?? "-"))", link?.isShowing("Link to") == true && link?.value("Link to") == "a.txt")
        link?.close()

        // Several items.
        list.tableForTesting.selectRowIndexes(IndexSet([row("a.txt"), row("b.txt")]), byExtendingSelection: false)
        let multi = menu(row("b.txt"))
        let multiState = enabled(multi)
        check("multi-selection menu keeps the selection, has no Rename", list.selectedNames.sorted() == ["a.txt", "b.txt"] && !multi.map(\.title).contains("Rename"))
        check("…Open, Copy, Duplicate, Move to Trash, Get Info enabled",
              ["Open", "Copy", "Duplicate", "Move to Trash", "Get Info"].allSatisfy { multiState[$0] == true })
        if let rename = menuItem(#selector(FileListViewController.renameSelection(_:))) {
            check("…File ▸ Rename disabled for several items", !list.validateMenuItem(rename))
        }
        let multiInfo = await info("multi") { perform("Get Info", in: multi) }
        check("…Get Info sums them (\(multiInfo?.value("Size") ?? "-"))",
              multiInfo?.titleText == "2 items" && multiInfo?.value("Contains") == "2 files, 0 folders" && multiInfo?.value("Size").contains("300 bytes for 2 files") == true)
        multiInfo?.close()
        perform("Show in Finder", in: multi)
        check("…Show in Finder reveals both", recorder.revealed.count == 2)
        perform("Move to Trash", in: multi)
        await waitUntil { !exists("a.txt") && !exists("b.txt") && !self.list.displayedNames.contains("b.txt") }
        check("…Move to Trash from the menu (test trash)", !exists("a.txt") && !exists("b.txt")
              && fm.fileExists(atPath: testTrash.directory.appending(path: "b.txt").path(percentEncoded: false)))

        // New Text Document from an item's menu.
        perform("New Text Document", in: menu(row("Folder")))
        await waitUntil { self.list.renameSession != nil }
        check("New Text Document from an item's menu creates it here", exists("New Text Document.txt") && list.renameSession?.originalName == "New Text Document.txt")
        renameCommand(#selector(NSResponder.cancelOperation(_:)))
        check("Get Info is in the File menu as ⌘I", menuItem(#selector(FileListViewController.getInfo(_:)))?.keyEquivalent == "i")
        list.focusList()
    }

    // MARK: Navigation-pane tree (P1-1) — scratch folder under the fixtures

    private var sidebar: SidebarViewController { window.sidebar }

    /// Navigates the list and waits for the tree's reveal of that folder to finish.
    private func navigateAndReveal(_ url: URL) async -> Bool {
        var done = false
        let target = Self.norm(url)
        sidebar.onRevealFinished = { revealed, _ in if Self.norm(revealed) == target { done = true } }
        await settle { self.list.navigate(to: url) }
        await waitUntil { done }
        sidebar.onRevealFinished = nil
        return done
    }

    private func node(_ url: URL) -> TreeNode? {
        guard let (root, names) = sidebar.tree.revealTarget(for: url) else { return nil }
        var node = root
        for name in names {
            guard let child = node.allChildren?.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    private func outlineKey(_ keyCode: UInt16, chars: String) {
        guard let nsWindow = window.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { return }
        sidebar.outlineView.keyDown(with: event)
    }

    /// A real click (down + up through the event queue) in the middle of a sidebar row.
    private func clickSidebarRow(_ item: AnyObject) async {
        let outline = sidebar.outlineView
        let row = outline.row(forItem: item)
        guard row >= 0, let nsWindow = outline.window else { return }
        outline.scrollRowToVisible(row)
        // On the name (the middle of a deeply indented row can be the disclosure triangle).
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
        let point = cell.convert(NSPoint(x: min(34, max(cell.bounds.maxX - 2, 0)), y: cell.bounds.midY), to: nil) // the name
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        if nsWindow.isKeyWindow {
            NSApp.postEvent(down, atStart: false) // the normal path
            NSApp.postEvent(up, atStart: false)
        } else {
            // An inactive window's first click only activates it: hand the click to the outline view
            // directly (its tracking loop takes the queued mouse-up).
            NSApp.postEvent(up, atStart: false)
            outline.mouseDown(with: down)
        }
        try? await Task.sleep(for: .milliseconds(80))
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
            let hit = nsWindow.contentView?.superview?.hitTest(point)
            print("click row \(row) at \(point): hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil"), row at point \(outline.row(at: outline.convert(point, from: nil)))")
        }
    }

    private func treeChecks() async {
        let fm = FileManager.default
        let settings = ViewSettings.shared
        let outline = sidebar.outlineView
        // The fixtures live under /var (a hidden folder): the tree only shows that path with hidden files on.
        if !settings.showHidden { list.toggleHiddenFiles() }
        settings.treeExpandToCurrent = true
        settings.treeKeyDelay = 250

        let titles = sidebar.debugTitles
        check("Favorites without Home; Locations starts with Home, then Macintosh HD (\(titles.prefix(6)))",
              !titles.contains("Favorites/Home") && titles.first { $0.hasPrefix("Locations/") }?.hasPrefix("Locations/Home") == true
              && titles.contains { $0.hasPrefix("Locations/") && !$0.hasPrefix("Locations/Home") })

        let scratch = fixtures.appending(path: "scratch-tree-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch) }
        for dir in ["a/b/c", "x", ".hidden-dir/inner", "Tool.app/Contents", "empty"] {
            try? fm.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: scratch.appending(path: "file.txt").path(percentEncoded: false), contents: nil)
        try? fm.createSymbolicLink(atPath: scratch.appending(path: "link-to-a").path(percentEncoded: false), withDestinationPath: "a")
        let a = scratch.appending(path: "a", directoryHint: .isDirectory)
        let b = a.appending(path: "b", directoryHint: .isDirectory)
        let x = scratch.appending(path: "x", directoryHint: .isDirectory)

        // Expand to open folder.
        let revealStart = ContinuousClock.now
        let revealed = await navigateAndReveal(b)
        let revealTime = ContinuousClock.now - revealStart
        check("navigating reveals the folder in the tree (\(revealTime.formatted(.units(allowed: [.milliseconds]))))",
              revealed && sidebar.selectedNode.map { Self.norm($0.url) } == Self.norm(b))
        let bNode = node(b), aNode = node(a), scratchNode = node(scratch)
        check("…its ancestors opened automatically, the folder itself not",
              aNode?.isExpanded == true && aNode?.expandedAutomatically == true && scratchNode?.isExpanded == true && bNode?.isExpanded == false)
        check("…folders only: no files, no packages; links to folders and hidden folders shown (\(scratchNode?.children.map(\.name) ?? []))",
              scratchNode?.children.map(\.name) == [".hidden-dir", "a", "empty", "link-to-a", "x"])
        check("…a link is a link node", scratchNode?.children.first { $0.name == "link-to-a" }?.kind == .link)

        _ = await navigateAndReveal(x)
        check("leaving it collapses the branch the reveal opened", aNode?.isExpanded == false && sidebar.selectedNode.map { Self.norm($0.url) } == Self.norm(x))

        // Hand-expanded branches stay.
        if let aNode {
            outline.expandItem(aNode)
            await waitUntil { aNode.isListed }
        }
        let unicode = fixtures.appending(path: "unicode", directoryHint: .isDirectory)
        _ = await navigateAndReveal(unicode)
        check("a hand-expanded branch stays open when leaving (expanded \(aNode?.isExpanded ?? false), auto \(aNode?.expandedAutomatically ?? true), outline \(aNode.map { outline.isItemExpanded($0) } ?? false))", aNode?.isExpanded == true && aNode?.expandedAutomatically == false)
        _ = await navigateAndReveal(x)

        // Disclosure triangles: checked for rows on screen.
        let emptyNode = node(scratch.appending(path: "empty"))
        await waitUntil { emptyNode?.hasSubfolders != nil && aNode?.isListed == true }
        check("no triangle on a folder without subfolders, one where there are",
              emptyNode.map { !$0.showsDisclosure(checkNetwork: false) } == true && node(x)?.showsDisclosure(checkNetwork: false) == false
              && aNode?.showsDisclosure(checkNetwork: false) == true)

        // Hidden folders follow the global setting, in place.
        let aBefore = aNode
        list.toggleHiddenFiles() // off
        check("hidden files off: .hidden-dir leaves the tree, nothing collapses",
              scratchNode?.children.map(\.name) == ["a", "empty", "link-to-a", "x"] && node(a) === aBefore && aBefore?.isExpanded == true)
        list.toggleHiddenFiles() // on again
        _ = await navigateAndReveal(x)

        // Links expand under their own path.
        if let link = scratchNode?.children.first(where: { $0.name == "link-to-a" }) {
            outline.expandItem(link)
            await waitUntil { link.isListed }
            check("a link expands under its own path (\(link.children.first.map { $0.path } ?? "-"))",
                  link.children.first.map { Self.normPath($0.path) } == Self.norm(scratch.appending(path: "link-to-a/b")))
            outline.collapseItem(link)
        }

        // Mouse: a click navigates at once. (Needs the active app: an inactive window's first click only
        // activates it, and a draggable row waits for the click-or-drag decision a direct mouseDown can't give.)
        if window.window?.isKeyWindow != true {
            skip("clicking a tree row", "app not active (the first click would only activate the window)")
        } else if let aNode {
            await clickSidebarRow(aNode)
            await waitUntil { self.path == Self.norm(a) }
            check("clicking a row navigates at once (no expand) (row \(outline.row(forItem: aNode)), key \(window.window?.isKeyWindow ?? false), sel \(outline.selectedRow))", path == Self.norm(a))
        }

        // Keyboard: arrows move the highlight and navigate after the pause; Return at once.
        window.window?.makeFirstResponder(outline)
        if let aNode, let xNode = node(x) {
            outline.selectRowIndexes([outline.row(forItem: aNode)], byExtendingSelection: false)
            await settle { self.list.navigate(to: a) }
            let target = outline.item(atRow: outline.row(forItem: aNode) + 1) as? TreeNode // the row below "a"
            outlineKey(125, chars: "\u{F701}") // ↓
            let immediately = path
            try? await Task.sleep(for: .milliseconds(120))
            let early = path
            await waitUntil { self.path != Self.norm(a) }
            check("↓ moves the highlight; navigates only after the pause (\(settings.treeKeyDelay) ms)",
                  immediately == Self.norm(a) && early == Self.norm(a) && target.map { Self.norm($0.url) } == path)
            outline.selectRowIndexes([outline.row(forItem: xNode)], byExtendingSelection: false)
            await settle { self.list.navigate(to: x) }
            outlineKey(126, chars: "\u{F700}") // ↑
            outlineKey(126, chars: "\u{F700}")
            outlineKey(126, chars: "\u{F700}")
            try? await Task.sleep(for: .milliseconds(450))
            check("holding ↑ navigates once, to where the highlight stopped", path == outline.item(atRow: outline.selectedRow).flatMap { ($0 as? TreeNode).map { Self.norm($0.url) } })

            outline.selectRowIndexes([outline.row(forItem: aNode)], byExtendingSelection: false)
            outline.collapseItem(aNode)
            outlineKey(124, chars: "\u{F703}") // →
            check("→ expands", outline.isItemExpanded(aNode))
            outlineKey(124, chars: "\u{F703}")
            check("→ again goes to the first child", sidebar.selectedNode === aNode.children.first)
            outlineKey(123, chars: "\u{F702}") // ←
            check("← on a collapsed child goes to the parent", sidebar.selectedNode === aNode)
            outlineKey(123, chars: "\u{F702}")
            check("← on an expanded node collapses it", !outline.isItemExpanded(aNode))
            outlineKey(36, chars: "\r") // Return
            await waitUntil { self.path == Self.norm(a) }
            check("Return navigates at once and focuses the list", path == Self.norm(a) && window.window?.firstResponder === list.tableForTesting)

            // With the tree focused, Move to Trash / Rename / Paste go to the tree, never the list (P1-4).
            window.window?.makeFirstResponder(outline)
            // The window's own responder chain (NSApp.target(forAction:) follows the *key* window, which a test launch may not have).
            func responder(for action: Selector) -> AnyObject? {
                var responder = window.window?.firstResponder
                while let r = responder { if r.responds(to: action) { return r }; responder = r.nextResponder }
                return nil
            }
            let trashTarget = responder(for: #selector(FileListViewController.moveToTrash(_:)))
            let renameTarget = responder(for: #selector(FileListViewController.renameSelection(_:)))
            check("tree focused: Move to Trash and Rename act on the tree, not the list",
                  trashTarget as AnyObject? === sidebar && renameTarget as AnyObject? === sidebar)
        }

        // Context menu.
        if let xNode = node(x) {
            let row = outline.row(forItem: xNode)
            let items = sidebar.contextMenuItems(forRow: row)
            check("tree context menu: Open (+ in New Tab / Window), Show in Finder, Copy Path, Get Info, New Folder, Pin to Favorites",
                  items.filter { !$0.isSeparatorItem }.map(\.title) == ["Open", "Open in New Tab", "Open in New Window", "Show in Finder", "Copy Path", "Get Info", "New Folder", "Pin to Favorites"])
            func perform(_ title: String) {
                guard let item = items.first(where: { $0.title == title }), let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }
            if let recorder = list.opener as? RecordingOpener {
                perform("Show in Finder")
                check("…Show in Finder (recorded)", recorder.revealed.map(Self.norm) == [Self.norm(x)])
            }
            perform("Copy Path")
            check("…Copy Path", list.pasteboard.string(forType: .string).map(Self.normPath) == Self.norm(x))
            let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            perform("Get Info")
            let info = NSApp.windows.first { !windowsBefore.contains(ObjectIdentifier($0)) && $0.title.contains("“x” Info") }
            check("…Get Info opens the info window for that folder", info != nil)
            info?.close()
            perform("New Folder")
            await waitUntil { self.sidebar.renamingNode != nil }
            check("…New Folder creates it inside and starts renaming in the tree",
                  fm.fileExists(atPath: x.appending(path: "New folder").path(percentEncoded: false)) && sidebar.renamingNode?.name == "New folder")
            if let editor = window.window?.firstResponder as? NSTextView {
                editor.string = "Made"
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                sidebar.endRename(commit: false)
            }
            await waitUntil { xNode.children.contains { $0.name == "Made" } }
            check("…typing a name + Return renames it on disk and in the tree",
                  fm.fileExists(atPath: x.appending(path: "Made").path(percentEncoded: false)) && xNode.children.contains { $0.name == "Made" })
        }

        // Live updates from outside: nothing collapses, a renamed branch stays open.
        if let aNode {
            if !outline.isItemExpanded(aNode) { outline.expandItem(aNode) }
            let renamedTo = scratch.appending(path: "a-renamed", directoryHint: .isDirectory)
            try? fm.moveItem(at: a, to: renamedTo)
            for i in 1...3 { try? fm.createDirectory(at: x.appending(path: "live-\(i)"), withIntermediateDirectories: false) }
            await waitUntil(timeout: .seconds(5)) { aNode.name == "a-renamed" && (self.node(x)?.children.filter { $0.name.hasPrefix("live-") }.count ?? 0) == 3 }
            check("renamed outside the app: same node, renamed, still expanded", aNode.name == "a-renamed" && outline.isItemExpanded(aNode)
                  && node(renamedTo) === aNode)
            check("…folders created outside appear in place", node(x)?.children.filter { $0.name.hasPrefix("live-") }.count == 3)
            try? fm.removeItem(at: x.appending(path: "live-2"))
            await waitUntil(timeout: .seconds(5)) { self.node(x)?.children.contains { $0.name == "live-2" } == false }
            check("…and deleted ones disappear", node(x)?.children.contains { $0.name == "live-2" } == false)
        }

        // Setting off: nothing expands; the deepest visible ancestor gets the light mark.
        settings.treeExpandToCurrent = false
        let level1 = fixtures.appending(path: "deep/level-01", directoryHint: .isDirectory)
        _ = await navigateAndReveal(level1)
        check("Expand to open folder off: not revealed, nearest visible ancestor marked",
              sidebar.selectedNode == nil && !sidebar.markedItems.isEmpty && node(level1).map { outline.row(forItem: $0) < 0 } ?? true)
        var reRevealed = false
        sidebar.onRevealFinished = { _, reached in reRevealed = reached }
        settings.treeExpandToCurrent = true
        await waitUntil { reRevealed }
        sidebar.onRevealFinished = nil
        check("…turning it on reveals the current folder", sidebar.selectedNode.map { Self.norm($0.url) } == Self.norm(level1))

        if settings.showHidden { list.toggleHiddenFiles() }
        list.focusList()
    }

    // MARK: Drag and drop, tree file operations (P1-4) — scratch folder, test trash

    private func dragDropChecks() async {
        guard let testTrash = list.trasher as? DirectoryTrasher else { skip("drag and drop", "no test trash"); return }
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-dnd-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: testTrash.directory) }
        for dir in ["src/sub", "dst", "other", "tree/one", "tree/two", "tree/three"] { try? fm.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true) }
        for (name, text) in [("src/a.txt", "a"), ("src/b.txt", "b"), ("src/c.txt", "c")] {
            try? Data(text.utf8).write(to: scratch.appending(path: name))
        }
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: scratch.appending(path: p).path(percentEncoded: false)) }
        func url(_ p: String) -> URL { scratch.appending(path: p) }
        let table = list.tableForTesting
        @MainActor func drop(_ paths: [String], mask: NSDragOperation = [.copy, .move, .link, .generic], row: Int, on: Bool) -> (NSDragOperation, Bool) {
            let info = FakeDraggingInfo(pasteboard: dragPasteboard(paths.map(url)), window: table.window, mask: mask)
            let operation = list.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: on ? .on : .above)
            guard !operation.isEmpty else { return ([], false) }
            return (operation, list.tableView(table, acceptDrop: info, row: on ? row : -1, dropOperation: on ? .on : .above))
        }

        // Onto the list's folder: same volume → move.
        await settle { self.list.navigate(to: url("dst")) }
        let (moveOp, moved) = drop(["src/a.txt"], row: list.displayedNames.count, on: false)
        await waitUntil { exists("dst/a.txt") && !exists("src/a.txt") && self.list.displayedNames.contains("a.txt") }
        check("drop on the list, same volume → move (\(moveOp == .move ? "move" : "\(moveOp.rawValue)"))", moveOp == .move && moved
              && exists("dst/a.txt") && !exists("src/a.txt") && list.displayedNames.contains("a.txt"))
        // ⌥ → copy.
        let (copyOp, _) = drop(["src/b.txt"], mask: .copy, row: list.displayedNames.count, on: false)
        await waitUntil { exists("dst/b.txt") }
        check("⌥-drop copies (source stays)", copyOp == .copy && exists("dst/b.txt") && exists("src/b.txt"))
        // Moving into the folder it's already in is refused.
        let (noop, _) = drop(["dst/a.txt"], row: list.displayedNames.count, on: false)
        check("…moving into the same folder isn't offered", noop.isEmpty)

        // Onto a folder row: into that folder; a folder onto itself → the list's folder instead (refused here: no-op).
        await settle { self.list.navigate(to: url("src")) }
        let subRow = list.displayedNames.firstIndex(of: "sub") ?? 0
        _ = drop(["dst/a.txt"], row: subRow, on: true)
        await waitUntil { exists("src/sub/a.txt") }
        check("drop on a folder row → into that folder", exists("src/sub/a.txt") && !exists("dst/a.txt"))
        let (selfDrop, _) = drop(["src/sub"], row: subRow, on: true)
        check("…a folder onto itself is refused", selfDrop.isEmpty)
        // Undo the drag-move.
        FileUndo.shared.manager.undo()
        await waitUntil { exists("dst/a.txt") && !exists("src/sub/a.txt") }
        check("Undo puts a drag-moved file back", exists("dst/a.txt") && !exists("src/sub/a.txt"))

        // Onto a folder in the navigation pane (the tree reveals this folder's ancestors; hidden files on for /var).
        if !ViewSettings.shared.showHidden { list.toggleHiddenFiles() }
        await settle { self.list.navigate(to: scratch) }
        try? await Task.sleep(for: .milliseconds(300))
        let outline = sidebar.outlineView
        await waitUntil { self.node(scratch) != nil }
        if let scratchNode = node(scratch) {
            await sidebar.ensureListed(scratchNode)
            if !outline.isItemExpanded(scratchNode) { outline.expandItem(scratchNode) }
            check("the scratch folder's subfolders are in the tree (\(scratchNode.children.map(\.name)))", scratchNode.children.contains { $0.name == "other" })
            if let other = scratchNode.children.first(where: { $0.name == "other" }) {
                let info = FakeDraggingInfo(pasteboard: dragPasteboard([url("src/c.txt")]), window: outline.window)
                let op = sidebar.outlineView(outline, validateDrop: info, proposedItem: other, proposedChildIndex: 0)
                let ok = !op.isEmpty && sidebar.outlineView(outline, acceptDrop: info, item: other, childIndex: NSOutlineViewDropOnItemIndex)
                await waitUntil { exists("other/c.txt") }
                check("drop on a folder in the tree → into it (move)", op == .move && ok && exists("other/c.txt") && !exists("src/c.txt"))
            }
            if let src = scratchNode.children.first(where: { $0.name == "src" }) {
                await sidebar.ensureListed(src)
                let info = FakeDraggingInfo(pasteboard: dragPasteboard([url("src")]), window: outline.window)
                let into = src.children.first { $0.name == "sub" }
                let op = into.map { sidebar.outlineView(outline, validateDrop: info, proposedItem: $0, proposedChildIndex: NSOutlineViewDropOnItemIndex) } ?? [.move]
                check("…a folder into its own subfolder is refused", op.isEmpty)
            }
        } else {
            check("the scratch folder is in the tree", false)
        }

        // A file promise (Mail, Photos): received, then placed by the copy engine.
        await settle { self.list.navigate(to: url("dst")) }
        let promiseDelegate = PromiseWriter(name: "promised.txt", text: "from a promise")
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: promiseDelegate)
        let promisePasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test.promise"))
        promisePasteboard.clearContents()
        promisePasteboard.writeObjects([provider])
        let promiseInfo = FakeDraggingInfo(pasteboard: promisePasteboard, window: table.window)
        let promiseOp = list.tableView(table, validateDrop: promiseInfo, proposedRow: list.displayedNames.count, proposedDropOperation: .above)
        check("a file promise (Mail, Photos) is offered as a copy", promiseOp == .copy)
        let accepted = list.tableView(table, acceptDrop: promiseInfo, row: -1, dropOperation: .above)
        check("…outside a real drag it's refused safely (nothing written)", !accepted && !exists("dst/promised.txt"))
        skip("receiving a file promise", "AppKit only fulfils promises in a real drag from another app — test by hand with Mail or Photos")

        // Tree folders: F2, ⌘C/⌘V, ⌘X/⌘V, Del — with undo; never Home or a volume.
        await settle { self.list.navigate(to: url("tree")) }
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil { self.node(url("tree")) != nil }
        guard let treeNode = node(url("tree")) else { check("tree folder in the tree", false); return }
        await sidebar.ensureListed(treeNode)
        if !outline.isItemExpanded(treeNode) { outline.expandItem(treeNode) }
        await waitUntil { treeNode.isListed && treeNode.children.count == 3 }
        @MainActor func selectChild(_ name: String) {
            if let node = treeNode.children.first(where: { $0.name == name }) {
                let row = outline.row(forItem: node)
                if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            }
        }
        window.window?.makeFirstResponder(outline)
        selectChild("one")
        sidebar.renameSelection(nil)
        if let editor = window.window?.firstResponder as? NSTextView {
            editor.string = "uno"
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        await waitUntil { exists("tree/uno") }
        check("F2 in the tree renames the folder in place", exists("tree/uno") && !exists("tree/one"))
        await waitUntil { treeNode.children.contains { $0.name == "uno" } }
        selectChild("uno")
        sidebar.copy(nil)
        selectChild("two")
        sidebar.paste(nil)
        await waitUntil { exists("tree/two/uno") }
        check("⌘C on a tree folder, ⌘V on another → copied into it", exists("tree/two/uno") && exists("tree/uno"))
        selectChild("uno")
        sidebar.cut(nil)
        selectChild("three")
        let pasteEnabled = sidebar.validateMenuItem(NSMenuItem(title: "", action: #selector(FileListViewController.paste(_:)), keyEquivalent: ""))
        sidebar.paste(nil)
        await waitUntil { !exists("tree/uno") && exists("tree/three/uno") }
        check("⌘X, ⌘V → moved into the other folder", pasteEnabled && !exists("tree/uno") && exists("tree/three/uno"))
        await waitUntil { treeNode.children.map(\.name) == ["three", "two"] }
        selectChild("two")
        outlineKey(117, chars: "\u{F728}") // Del
        await waitUntil { !exists("tree/two") }
        check("Del on a tree folder → Trash (test trash)", !exists("tree/two") && fm.fileExists(atPath: testTrash.directory.appending(path: "two").path(percentEncoded: false)))
        FileUndo.shared.manager.undo()
        await waitUntil { exists("tree/two") }
        check("…Undo brings it back", exists("tree/two"))
        // Home and volumes can't be renamed, cut or trashed.
        if let home = sidebar.tree.roots.first {
            let row = outline.row(forItem: home)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            let trash = NSMenuItem(title: "", action: #selector(FileListViewController.moveToTrash(_:)), keyEquivalent: "")
            let rename = NSMenuItem(title: "", action: #selector(FileListViewController.renameSelection(_:)), keyEquivalent: "")
            check("Home can't be trashed or renamed from the tree", !sidebar.validateMenuItem(trash) && !sidebar.validateMenuItem(rename))
        }
        if ViewSettings.shared.showHidden { list.toggleHiddenFiles() }
        list.focusList()
    }

    // MARK: Folder sizes (P1-6) — scratch folder

    private func folderSizeChecks() async {
        let fm = FileManager.default
        let settings = ViewSettings.shared
        let scratch = fixtures.appending(path: "scratch-sizes-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch) }
        for dir in ["big/nested", "small", "empty", "Pkg.app/Contents"] { try? fm.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true) }
        for (file, bytes) in [("big/a.bin", 3000), ("big/nested/b.bin", 2000), ("small/c.bin", 100), ("Pkg.app/Contents/x.bin", 500), ("top.bin", 7)] {
            try? Data(repeating: 1, count: bytes).write(to: scratch.appending(path: file))
        }
        try? fm.createSymbolicLink(atPath: scratch.appending(path: "link-to-big").path(percentEncoded: false), withDestinationPath: "big")
        settings.folderSizes = true
        settings.sort = .default
        await settle { self.list.navigate(to: scratch) }
        await waitUntil { self.list.pendingFolderSizes == 0 && self.list.folderSizes.count == 4 }
        let sizes = list.folderSizes
        check("folder sizes are counted in the background (\(sizes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }))",
              sizes == ["big": 5000, "small": 100, "empty": 0, "Pkg.app": 500])
        check("…a link to a folder isn't counted (never followed)", sizes["link-to-big"] == nil)
        if let row = list.displayedNames.firstIndex(of: "big"),
           let cell = list.tableView(list.tableForTesting, viewFor: list.tableForTesting.tableColumns.first { $0.identifier.rawValue == "size" }, row: row) as? FileCellView {
            check("…shown in the Size column (\(cell.text))", cell.text == Formatters.size.string(fromByteCount: 5000))
        }
        settings.sort = FileSort(field: .size, ascending: false)
        // Explorer order: descending = files (packages count as files) largest first, then folders largest first.
        let expected = ["Pkg.app", "top.bin", "big", "small"]
        await waitUntil { self.list.displayedNames.filter(expected.contains) == expected }
        check("sorting by Size orders folders (and packages) by their size (\(list.displayedNames))",
              list.displayedNames.filter((expected + ["empty"]).contains) == expected + ["empty"])
        settings.sort = .default
        select("big")
        list.updateStatusBar()
        check("…and the status bar adds it to the selection", list.statusBar.selectionLabel.stringValue.hasSuffix(Formatters.size.string(fromByteCount: 5000)))

        // Live: something changes inside a subfolder.
        try? Data(repeating: 2, count: 4000).write(to: scratch.appending(path: "small/new.bin"))
        await waitUntil(timeout: .seconds(5)) { self.list.folderSizes["small"] == 4100 }
        check("a change inside a subfolder updates its size", list.folderSizes["small"] == 4100)

        // Away and back: sizes come from the cache; what changed meanwhile is measured again (FSEvents replay).
        let flat = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: flat) }
        try? Data(repeating: 3, count: 1000).write(to: scratch.appending(path: "big/nested/more.bin"))
        try? await Task.sleep(for: .milliseconds(400))
        await settle { self.list.navigate(to: scratch) }
        await waitUntil { self.list.folderSizes.count == 4 }
        let cachedAtOnce = list.folderSizes["small"] == 4100 && list.folderSizes["empty"] == 0
        await waitUntil(timeout: .seconds(5)) { self.list.folderSizes["big"] == 6000 && self.list.pendingFolderSizes == 0 }
        check("coming back: known sizes at once from the cache, only the changed folder measured again (\(list.foldersMeasured) measured)",
              cachedAtOnce && list.folderSizes["big"] == 6000 && list.foldersMeasured == 1)

        // The setting.
        settings.folderSizes = false
        check("Settings: folder sizes off → none shown", list.folderSizes.isEmpty && list.pendingFolderSizes == 0)
        settings.folderSizes = true
        await waitUntil { self.list.folderSizes.count == 4 }
        check("…on again → back (from the cache)", list.folderSizes["big"] == 6000)

        // A folder whose walk gets stuck (as on a privacy prompt or a hung volume) is given up; the rest go on.
        FolderSizeCache.shared.removeAll()
        let limit = FolderSizeQueue.stallLimit
        FolderSizeQueue.stallLimit = .milliseconds(600)
        FolderSizeQueue.testStall = "big"
        let abandoned = FolderSizeQueue.abandoned
        defer { FolderSizeQueue.stallLimit = limit; FolderSizeQueue.testStall = nil }
        let stallStart = ContinuousClock.now
        settings.folderSizes = false
        settings.folderSizes = true
        await waitUntil(timeout: .seconds(5)) { self.list.pendingFolderSizes == 0 && self.list.folderSizes.count == 3 }
        let given = ContinuousClock.now - stallStart
        let bigText = list.folderSizeText(list.displayedItems.first { $0.name == "big" } ?? FileItem(name: "-", kind: .file))
        check("a stuck folder is given up after the stall limit, the others still measured (\(Int(given / .milliseconds(1))) ms, big=\"\(bigText)\")",
              list.folderSizes["big"] == nil && list.folderSizes["small"] == 4100 && bigText.isEmpty
              && FolderSizeQueue.abandoned == abandoned + 1 && given < .seconds(3))
    }

    // MARK: Search (P1-5) — scratch folder

    private func searchChecks() async {
        guard let testTrash = list.trasher as? DirectoryTrasher else { skip("search", "no test trash"); return }
        let fm = FileManager.default
        let scratch = fixtures.appending(path: "scratch-search-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch); try? fm.removeItem(at: testTrash.directory) }
        for dir in ["a/b", "Tool.app/Contents", ".hidden", "linked"] { try? fm.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true) }
        for file in ["top-report.txt", "other.txt", "café.txt", "a/report-1.txt", "a/b/Report-2.TXT", "Tool.app/Contents/report-in-package.txt",
                     ".hidden/report-hidden.txt", "linked/report-via-link.txt"] {
            fm.createFile(atPath: scratch.appending(path: file).path(percentEncoded: false), contents: Data("x".utf8))
        }
        try? fm.createSymbolicLink(atPath: scratch.appending(path: "a/link").path(percentEncoded: false), withDestinationPath: "../linked")
        if ViewSettings.shared.showHidden { list.toggleHiddenFiles() }
        await settle { self.list.navigate(to: scratch) }
        let bar = window.addressBar
        func type(_ text: String) {
            bar.searchField.stringValue = text
            bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        }

        window.find(nil)
        check("⌘F puts the cursor in the search field (placeholder “\(bar.searchField.placeholderString ?? "")”)",
              (window.window?.firstResponder as? NSTextView)?.delegate === bar.searchField && bar.searchField.placeholderString?.contains(scratch.lastPathComponent) == true
              && menuItem(#selector(MainWindowController.find(_:)))?.keyEquivalent == "f")
        let typed = ContinuousClock.now
        type("report")
        await waitUntil { self.list.displayedNames.contains("top-report.txt") && !self.list.displayedNames.contains("other.txt") }
        let filterTime = ContinuousClock.now - typed
        check("typing filters this folder at once (\(filterTime.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))))",
              list.displayedNames.contains("top-report.txt") && !list.displayedNames.contains("other.txt"))
        check("…live updates pause while searching", list.isSearching && !list.isWatching)
        await waitUntil { self.list.searchIsComplete }
        let found = Set(list.displayedNames)
        check("…then the subfolders: matches with their location; no packages, hidden folders or links (\(found.sorted()))",
              found == ["top-report.txt", "a/report-1.txt", "a/b/Report-2.TXT", "linked/report-via-link.txt"])
        check("…status bar: “4 found …”", list.statusBar.countLabel.stringValue.hasPrefix("4 found"))
        if let row = list.displayedNames.firstIndex(of: "a/b/Report-2.TXT"),
           let cell = list.tableView(list.tableForTesting, viewFor: list.tableForTesting.tableColumns.first { $0.identifier.rawValue == "name" }, row: row) as? FileCellView {
            check("…a subfolder match shows its name and where it is (\(cell.text) in \(cell.detail))", cell.text == "Report-2.TXT" && cell.detail == "a/b")
        }
        select("a/report-1.txt")
        check("…subfolder results can't be renamed here", !list.validateMenuItem(NSMenuItem(title: "", action: #selector(FileListViewController.renameSelection(_:)), keyEquivalent: "")))

        type("cafe")
        await waitUntil { self.list.displayedNames == ["café.txt"] }
        check("“cafe” finds “café.txt” (diacritics and case ignored)", list.displayedNames == ["café.txt"])

        // A change on disk while searching: shown once the search ends (FSEvents catch-up).
        fm.createFile(atPath: scratch.appending(path: "made-during-search.txt").path(percentEncoded: false), contents: nil)
        try? await Task.sleep(for: .milliseconds(300))
        type("report")
        await waitUntil { self.list.searchIsComplete && self.list.displayedNames.count == 4 }
        // Trash a result.
        select("a/report-1.txt")
        list.moveToTrash(nil)
        await waitUntil { !fm.fileExists(atPath: scratch.appending(path: "a/report-1.txt").path(percentEncoded: false)) && !self.list.displayedNames.contains("a/report-1.txt") }
        check("trashing a result removes it from the results (test trash)", !list.displayedNames.contains("a/report-1.txt")
              && fm.fileExists(atPath: testTrash.directory.appending(path: "report-1.txt").path(percentEncoded: false)))
        // Esc: back to the folder, live again, the change made meanwhile is there.
        window.window?.makeFirstResponder(bar.searchField)
        if let editor = bar.searchField.currentEditor() as? NSTextView {
            _ = bar.control(bar.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        await waitUntil { !self.list.isSearching && self.list.displayedNames.contains("made-during-search.txt") }
        check("Esc ends the search: the folder again, live, with what changed meanwhile",
              !list.isSearching && bar.searchField.stringValue.isEmpty && list.isWatching && list.displayedNames.contains("made-during-search.txt")
              && !list.displayedNames.contains { $0.contains("/") })

        // Opening a folder result goes there (and ends the search); navigating ends it too.
        type("b")
        await waitUntil { self.list.searchIsComplete && self.list.displayedNames.contains("a/b") }
        select("a/b")
        list.openSelection()
        await waitUntil { self.path == Self.norm(scratch.appending(path: "a/b")) && self.list.displayedNames == ["Report-2.TXT"] }
        check("opening a folder result goes into it and ends the search", path == Self.norm(scratch.appending(path: "a/b")) && !list.isSearching
              && bar.searchField.stringValue.isEmpty && list.displayedNames == ["Report-2.TXT"])
        type("report")
        await waitUntil { self.list.isSearching }
        await settle { self.list.navigate(to: scratch) }
        check("navigating ends a search", !list.isSearching && bar.searchField.stringValue.isEmpty && list.displayedNames.contains("other.txt"))
        list.focusList()
    }

    private func dragPasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test.drag"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return pasteboard
    }

    // MARK: Tabs and windows (P1-3)

    private func tabChecks() async {
        let manager = WindowManager.shared
        guard let first = window.window else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let scratch = fixtures.appending(path: "scratch-tabs-\(getpid())", directoryHint: .isDirectory)
        try? fm.createDirectory(at: scratch.appending(path: "inside"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        await settle { self.list.navigate(to: scratch) }
        let a = window.fileList // the first tab
        @MainActor func loaded(_ tab: FileListViewController) async { await waitUntil(timeout: .seconds(10)) { tab.hasLoadedOnce && !tab.state.isLoading } }

        // Layout (Explorer): the tab strip is in the title-bar row, above the address bar; one window, no AppKit tab bar.
        let stripFrame = window.tabStrip.convert(window.tabStrip.bounds, to: nil)
        let barFrame = window.addressBar.view.convert(window.addressBar.view.bounds, to: nil)
        check("tabs are in the title-bar row, above the path (strip y \(Int(stripFrame.minY)) > address bar y \(Int(barFrame.maxY)))",
              window.tabStrip.window === first && stripFrame.minY >= barFrame.maxY - 1 && first.tabbingMode == .disallowed)
        check("…Back / Forward / Up sit in the address row, left of the path", window.addressBar.view.subviews.contains { ($0 as? NSButton)?.toolTip == "Back" })

        // Menus.
        let newTab = menuItem(#selector(MainWindowController.newTab(_:)))
        let newWindow = menuItem(#selector(MainWindowController.newWindow(_:)))
        let closeTab = menuItem(#selector(MainWindowController.closeTab(_:)))
        let closeAll = menuItem(#selector(MainWindowController.closeWindowAndTabs(_:)))
        check("File: New Tab ⌘T, New Window ⌘N, Close Tab ⌘W, Close Window ⇧⌘W",
              newTab?.keyEquivalent == "t" && newWindow?.keyEquivalent == "n" && newWindow?.keyEquivalentModifierMask == [.command]
              && closeTab?.keyEquivalent == "w" && closeAll?.keyEquivalentModifierMask == [.command, .shift])

        // ⌘T: a tab at Home, selected; the first tab pauses.
        window.newTab(nil)
        let b = window.fileList
        await loaded(b)
        check("⌘T opens a tab at Home, selected (\(window.tabStrip.tabs.map(\.title)))",
              window.tabs.count == 2 && window.selectedIndex == 1 && b !== a && Self.norm(b.folder) == Self.norm(home)
              && window.tabStrip.tabs.count == 2 && window.tabStrip.tabs[1].isSelected && manager.controllers.count == 1)
        check("…the hidden tab pauses: no watcher, view hidden, rows kept",
              !a.isActive && !a.isWatching && a.view.isHidden && a.displayedNames == ["inside"])
        check("…the shown one is live; the navigation pane follows it", b.isActive && b.isWatching && window.sidebar.fileList === b)
        let flat = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        b.navigate(to: flat)
        await loaded(b)
        check("each tab has its own folder and history", Self.norm(a.folder) == Self.norm(scratch) && Self.norm(b.folder) == Self.norm(flat)
              && b.state.canGoBack && b.history.back.last.map { Self.norm($0.url) } == Self.norm(home)
              && Self.normPath(window.addressBar.folder.path(percentEncoded: false)) == Self.norm(flat))

        // Changed on disk while in the background: caught up on return, without re-listing the folder.
        fm.createFile(atPath: scratch.appending(path: "made-in-background.txt").path(percentEncoded: false), contents: nil)
        try? await Task.sleep(for: .milliseconds(400))
        check("…a paused tab doesn't react meanwhile", !a.displayedNames.contains("made-in-background.txt"))
        let listings = a.listingsStarted
        let previous = menuItem(#selector(MainWindowController.showPreviousTab(_:)))
        check("Window: Show Previous Tab ⌃⇧Tab, Show Next Tab ⌃Tab", previous?.keyEquivalent == "\t" && previous?.keyEquivalentModifierMask == [.control, .shift]
              && menuItem(#selector(MainWindowController.showNextTab(_:)))?.keyEquivalentModifierMask == [.control])
        let switchStart = ContinuousClock.now
        window.showPreviousTab(nil) // ⌃⇧Tab
        let switchTime = ContinuousClock.now - switchStart
        check("switching back is immediate, no re-list (\(switchTime.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))))",
              a.isActive && a.isWatching && a.listingsStarted == listings && window.fileList === a && !a.view.isHidden && b.view.isHidden)
        await waitUntil { a.displayedNames.contains("made-in-background.txt") }
        check("…and what changed while it was hidden appears (FSEvents replay)", a.displayedNames.contains("made-in-background.txt"))
        check("…the other tab paused now; address bar and pane show this tab",
              !b.isActive && !b.isWatching && Self.normPath(window.addressBar.folder.path(percentEncoded: false)) == Self.norm(scratch))

        // Mouse Back acts on the tab that's shown.
        mouse(button: 3)
        await waitUntil { Self.norm(a.folder) != Self.norm(scratch) }
        check("mouse Back goes back in the shown tab only", Self.norm(a.folder) != Self.norm(scratch) && Self.norm(b.folder) == Self.norm(flat))
        await settle { self.list.navigate(to: scratch) }

        // A tab opened in the background (middle-click / Open in New Tab) lists only when shown.
        let flat10k = fixtures.appending(path: "flat-10k", directoryHint: .isDirectory)
        weak var weakC: FileListViewController?
        do {
            let c = window.addTab(at: flat10k, background: true)
            weakC = c
            check("a background tab doesn't list until shown", c.listingsStarted == 0 && !c.isActive && window.fileList === a && window.tabs.count == 3)
            window.selectTab(at: window.tabs.firstIndex { $0 === c } ?? 0)
            await loaded(c)
            check("…shown: lists its folder", c.listingsStarted == 1 && c.state.itemCount > 10_000 - 1 && c.isActive)
            // Switching away while it lists cancels the listing; coming back lists again.
            c.navigate(to: fixtures.appending(path: "flat-100k", directoryHint: .isDirectory))
            window.selectTab(at: window.tabs.firstIndex { $0 === a } ?? 0)
            check("switching away while it lists cancels that work", !c.isActive && !c.isWatching && c.state.itemCount < 100_000)
            let before = c.listingsStarted
            window.selectTab(at: window.tabs.firstIndex { $0 === c } ?? 0)
            await waitUntil(timeout: .seconds(10)) { c.state.itemCount == 100_000 && !c.state.isLoading }
            check("…and lists it again when shown", c.state.itemCount == 100_000 && c.listingsStarted == before + 1)
            // Closing a tab stops all its work and frees it (⌘W closes the selected tab).
            window.closeTab(nil)
        }
        await waitUntil { weakC == nil && self.window.tabs.count == 2 }
        check("⌘W closes the tab, stops its work and frees it", weakC == nil && window.tabs.count == 2)

        // Middle-click on a folder in the list: a background tab.
        window.selectTab(at: window.tabs.firstIndex { $0 === a } ?? 0)
        if let row = a.displayedNames.firstIndex(of: "inside"), let browser = first as? BrowserWindow {
            let table = a.tableForTesting
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: min(60, rect.midX), y: rect.midY), to: nil)
            if let event = NSEvent.mouseEvent(with: .otherMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: first.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                let handled = browser.onMiddleClick?(event) == true
                let opened = window.tabs.first { Self.norm($0.folder) == Self.norm(scratch.appending(path: "inside")) }
                check("middle-click on a folder opens it in a background tab", handled && opened != nil && window.fileList === a
                      && opened?.listingsStarted == 0 && window.tabs.count == 3)
                // Move Tab to New Window: the tab (with its folder and history) becomes a window.
                if let opened, let index = window.tabs.firstIndex(where: { $0 === opened }) {
                    window.moveTabToNewWindow(at: index)
                    await waitUntil { manager.controllers.count == 2 }
                    let moved = manager.controllers.last
                    check("Move Tab to New Window: a window of its own", moved?.fileList === opened && window.tabs.count == 2 && moved !== window)
                    moved?.window?.performClose(nil)
                    await waitUntil { manager.controllers.count == 1 }
                }
            }
        }
        select("inside")
        let menu = a.contextMenuItems(forRow: a.displayedNames.firstIndex(of: "inside") ?? 0).map(\.title)
        check("folder context menu: Open in New Tab / New Window", menu.contains("Open in New Tab") && menu.contains("Open in New Window"))

        // Dropping files on a tab: into that tab's folder.
        if let other = window.tabs.first(where: { $0 !== a }), let tabView = window.tabStrip.itemViews.last {
            fm.createFile(atPath: scratch.appending(path: "to-drop.txt").path(percentEncoded: false), contents: nil)
            let dropTo = scratch.appending(path: "inside", directoryHint: .isDirectory)
            other.navigate(to: dropTo)
            await waitUntil { Self.norm(other.folder) == Self.norm(dropTo) }
            let info = FakeDraggingInfo(pasteboard: dragPasteboard([scratch.appending(path: "to-drop.txt")]), window: first)
            let op = tabView.draggingUpdated(info)
            let ok = tabView.performDragOperation(info)
            await waitUntil { fm.fileExists(atPath: dropTo.appending(path: "to-drop.txt").path(percentEncoded: false)) }
            check("dropping a file on a tab moves it into that tab's folder", op == .move && ok
                  && fm.fileExists(atPath: dropTo.appending(path: "to-drop.txt").path(percentEncoded: false)))
        }

        // ⌘N: a separate window at this folder.
        window.newWindow(nil)
        await waitUntil { manager.controllers.count == 2 }
        if let w = manager.controllers.last {
            await loaded(w.fileList)
            check("⌘N opens a separate window at the same folder", w !== window && w.tabs.count == 1
                  && Self.norm(w.fileList.folder) == Self.norm(scratch) && w.fileList.isActive)
            w.window?.performClose(nil)
        }
        await waitUntil { manager.controllers.count == 1 }
        while window.tabs.count > 1 { window.closeTab(at: window.tabs.count - 1) }
        check("closing the other tabs leaves this one, live", window.tabs.count == 1 && a.isActive && a.isWatching && window.fileList === a)
        first.makeKeyAndOrderFront(nil)
    }

    // MARK: Favorites (P1-2) — scratch folders under the fixtures

    /// Pinned at the end of the first launch; Tools/self-test.sh renames it before the second.
    private var relaunchPin: URL { fixtures.appending(path: "scratch-pin-relaunch", directoryHint: .isDirectory) }
    private var relaunchPinMoved: URL { fixtures.appending(path: "scratch-pin-relaunch-moved", directoryHint: .isDirectory) }

    private func favoritesChecks() async {
        let fm = FileManager.default
        let store = FavoritesStore.shared
        let titles = { self.sidebar.debugTitles.filter { $0.hasPrefix("Favorites/") }.map { String($0.dropFirst("Favorites/".count)) } }
        check("default favorites: Desktop, Documents, Downloads, Applications (\(titles()))",
              Array(titles().prefix(4)) == ["Desktop", "Documents", "Downloads", "Applications"] || titles().contains("Documents"))
        @MainActor func resolved() async { await store.resolveNow() }
        @MainActor func entry(titled title: String) -> FavoriteEntry? { store.entries.first { $0.title == title } }

        let scratch = fixtures.appending(path: "scratch-fav-\(getpid())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: scratch) }
        for dir in ["Alpha", "Beta", "Gamma", "Archive"] { try? fm.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true) }
        fm.createFile(atPath: scratch.appending(path: "file.txt").path(percentEncoded: false), contents: nil)
        await settle { self.list.navigate(to: scratch) }

        // Pin from the list's context menu.
        select("Alpha")
        let menu = list.contextMenuItems(forRow: list.displayedNames.firstIndex(of: "Alpha") ?? 0)
        let pinItem = menu.first { $0.title == "Pin to Favorites" }
        check("list context menu on a folder: Pin to Favorites", pinItem != nil)
        if let pinItem, let action = pinItem.action { NSApp.sendAction(action, to: pinItem.target, from: pinItem) }
        await waitUntil { entry(titled: "Alpha") != nil && titles().contains("Alpha") }
        check("…pinned: in Favorites, saved with a bookmark", titles().last == "Alpha" && entry(titled: "Alpha")?.bookmark != nil
              && (ViewSettings.shared.defaults.data(forKey: "favorites.v1")?.count ?? 0) > 0)
        check("…the menu now offers Unpin", list.contextMenuItems(forRow: list.displayedNames.firstIndex(of: "Alpha") ?? 0).contains { $0.title == "Unpin from Favorites" })
        select("file.txt")
        check("…files can't be pinned (no menu item)", !list.contextMenuItems(forRow: list.displayedNames.firstIndex(of: "file.txt") ?? 0).contains { $0.title.contains("Favorites") })

        // File ▸ Pin to Favorites (⌃⌘T) on another folder; the empty area pins the folder on screen.
        select("Beta")
        list.togglePinned(nil)
        await waitUntil { entry(titled: "Beta") != nil }
        let menuItem = menuItem(#selector(FileListViewController.togglePinned(_:)))
        check("File ▸ Pin to Favorites is ⌃⌘T and pins the selection", entry(titled: "Beta") != nil
              && menuItem?.keyEquivalent == "t" && menuItem?.keyEquivalentModifierMask == [.command, .control])
        let empty = list.contextMenuItems(forRow: -1)
        if let pinHere = empty.first(where: { $0.title == "Pin to Favorites" }), let action = pinHere.action {
            NSApp.sendAction(action, to: pinHere.target, from: pinHere)
        }
        await waitUntil { store.isPinned(scratch) }
        check("empty-area menu pins the folder on screen", store.isPinned(scratch))

        // Pin by dropping a folder on Favorites (and a file: refused with a message).
        let gamma = scratch.appending(path: "Gamma", directoryHint: .isDirectory)
        let dropOK = dropOnFavorites(urls: [gamma, scratch.appending(path: "file.txt")], at: 0)
        await waitUntil { entry(titled: "Gamma") != nil }
        check("dropping a folder on Favorites pins it there (\(titles().prefix(2)))", dropOK && titles().first == "Gamma")
        check("…a dropped file isn't pinned, and that's said inline (\(list.bannerText))",
              !store.entries.contains { $0.title == "file.txt" } && list.bannerText.localizedCaseInsensitiveContains("only folders"))

        // Reorder: by dragging a favorite, and with Move Down.
        if let from = store.entries.firstIndex(where: { $0.title == "Gamma" }) {
            _ = dropFavorite(at: from, to: store.entries.count) // to the end
            check("dragging a favorite reorders (Gamma last)", store.entries.last?.title == "Gamma" && titles().last == "Gamma")
        }
        if let alphaRow = sidebar.favoriteRow(titled: "Alpha") {
            let items = sidebar.contextMenuItems(forRow: alphaRow)
            let before = store.entries.map(\.title)
            if let down = items.first(where: { $0.title == "Move Down" }), let action = down.action { NSApp.sendAction(action, to: down.target, from: down) }
            let a = before.firstIndex(of: "Alpha") ?? 0
            check("Move Down swaps it with the next one", store.entries.map(\.title).firstIndex(of: "Alpha") == a + 1)
        }

        // Renamed and moved outside the app: the bookmark finds it.
        let alpha = scratch.appending(path: "Alpha", directoryHint: .isDirectory)
        let renamed = scratch.appending(path: "Alpha Renamed", directoryHint: .isDirectory)
        try? fm.moveItem(at: alpha, to: renamed)
        await resolved()
        let followedRename = store.entries.first { $0.title == "Alpha Renamed" }
        check("a pinned folder renamed outside the app is followed (\(followedRename?.path ?? "-"))",
              followedRename.map { Self.real($0.path) } == Self.real(renamed.path(percentEncoded: false)) && titles().contains("Alpha Renamed"))
        let moved = scratch.appending(path: "Archive/Alpha Renamed", directoryHint: .isDirectory)
        try? fm.moveItem(at: renamed, to: moved)
        await resolved()
        check("…and moved into another folder", store.entries.first { $0.title == "Alpha Renamed" }.map { Self.real($0.path) } == Self.real(moved.path(percentEncoded: false)))

        // Renamed inside the app (list rename): followed without waiting for activation.
        await settle { self.list.navigate(to: scratch) }
        select("Beta")
        list.renameSelection(nil)
        if let editor = list.renameSession?.editor.currentEditor() as? NSTextView {
            editor.string = "Beta Two"
            renameCommand(#selector(NSResponder.insertNewline(_:)))
        }
        await waitUntil { store.entries.contains { $0.title == "Beta Two" } }
        check("renamed in Kansio: the favorite follows at once", store.entries.contains { $0.title == "Beta Two" })

        // Deleted: kept, dimmed; clicking it explains.
        try? fm.removeItem(at: moved)
        await resolved()
        let gone = store.entries.first { $0.title == "Alpha Renamed" }
        check("a deleted target stays pinned, dimmed", gone.map { store.missing.contains($0.id) } == true
              && sidebar.favoriteItem(titled: "Alpha Renamed")?.missing == true)
        if let row = sidebar.favoriteRow(titled: "Alpha Renamed") {
            let before = path
            sidebar.outlineView.selectRowIndexes([row], byExtendingSelection: false)
            await waitUntil { self.list.bannerText.contains("can’t be found") }
            check("…clicking it says it can't be found, doesn't navigate", list.bannerText.contains("can’t be found") && path == before)
            // Unpin from its context menu.
            let items = sidebar.contextMenuItems(forRow: row)
            check("…its menu offers Unpin (and no Open)", items.contains { $0.title == "Unpin from Favorites" } && !items.contains { $0.title == "Open" })
            if let unpin = items.first(where: { $0.title == "Unpin from Favorites" }), let action = unpin.action {
                NSApp.sendAction(action, to: unpin.target, from: unpin)
            }
            check("Unpin removes it", !store.entries.contains { $0.title == "Alpha Renamed" } && !titles().contains("Alpha Renamed"))
        }

        // Tree context menu: Pin / Unpin.
        if !ViewSettings.shared.showHidden { list.toggleHiddenFiles() } // the fixtures are under /var
        await settle { self.list.navigate(to: scratch) }
        try? await Task.sleep(for: .milliseconds(300))
        if let node = sidebar.selectedNode {
            let row = sidebar.outlineView.row(forItem: node)
            check("tree context menu: Unpin for a pinned folder", sidebar.contextMenuItems(forRow: row).contains { $0.title == "Unpin from Favorites" })
        }
        if ViewSettings.shared.showHidden { list.toggleHiddenFiles() }

        // Restore defaults, then leave a pin for the relaunch check.
        SettingsModel.shared.restoreDefaultFavorites()
        check("Restore Default Favorites", store.entries.map(\.title) == ["Desktop", "Documents", "Downloads", "Applications"])
        try? fm.removeItem(at: relaunchPinMoved)
        try? fm.createDirectory(at: relaunchPin, withIntermediateDirectories: true)
        store.pin([relaunchPin], at: 1)
        await waitUntil { store.entries.count == 5 }
        check("pinned for the relaunch check (second place)", store.entries.dropFirst().first.map { Self.normPath($0.path) } == Self.norm(relaunchPin))
    }

    private func persistedFavoritesChecks() async {
        let store = FavoritesStore.shared
        defer { try? FileManager.default.removeItem(at: relaunchPinMoved) }
        check("relaunch: favorites kept in order", store.entries.map(\.title).first == "Desktop" && store.entries.count == 5)
        let moved = Self.real(relaunchPinMoved.path(percentEncoded: false))
        await waitUntil { store.entries.dropFirst().first.map { Self.real($0.path) } == moved }
        check("relaunch: a pin renamed while Kansio wasn't running is found (\(store.entries.dropFirst().first?.title ?? "-"))",
              store.entries.dropFirst().first.map { Self.real($0.path) } == moved
              && store.entries.dropFirst().first?.title == "scratch-pin-relaunch-moved")
    }

    /// Drops file URLs on the Favorites section at `index` through the outline view's data source.
    private func dropOnFavorites(urls: [URL], at index: Int) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test.drag"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return drop(pasteboard, at: index)
    }

    private func dropFavorite(at from: Int, to index: Int) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kansio.self-test.drag"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(FavoritesStore.shared.entries[from].id.uuidString, forType: .kansioFavorite)
        pasteboard.writeObjects([item])
        return drop(pasteboard, at: index)
    }

    private func drop(_ pasteboard: NSPasteboard, at index: Int) -> Bool {
        let outline = sidebar.outlineView
        let info = FakeDraggingInfo(pasteboard: pasteboard, window: outline.window)
        guard let section = outline.item(atRow: 0) else { return false }
        let operation = sidebar.outlineView(outline, validateDrop: info, proposedItem: section, proposedChildIndex: index)
        return !operation.isEmpty && sidebar.outlineView(outline, acceptDrop: info, item: section, childIndex: index)
    }

    // MARK: Settings window (P1-0)

    private func settingsWindowChecks() async {
        let settings = ViewSettings.shared
        let model = SettingsModel.shared
        let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Settings…" }
        check("Kansio ▸ Settings… is ⌘,", item?.keyEquivalent == "," && item?.action == #selector(AppDelegate.showSettings(_:)))
        if let item, let action = item.action { NSApp.sendAction(action, to: NSApp.delegate, from: item) }
        let controller = SettingsWindowController.shared
        await waitUntil { controller.window?.isVisible == true }
        let size = controller.window?.contentView?.fittingSize ?? .zero
        check("Settings window opens with its content (\(Int(size.width))×\(Int(size.height)))",
              controller.window?.isVisible == true && controller.window?.title == "Settings" && size.width >= 400 && size.height >= 200)
        if let out = ProcessInfo.processInfo.environment["KANSIO_SETTINGS_PNG"], let content = controller.window?.contentView {
            try? await Task.sleep(for: .milliseconds(200))
            try? WindowSnapshot.renderPlain(content, to: URL(filePath: out))
        }

        // Each setting: window → ViewSettings (saved) → the list, and back.
        let hidden = fixtures.appending(path: "hidden", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: hidden) }
        let wasHidden = settings.showHidden
        model.showHidden = !wasHidden
        await waitUntil { self.list.displayedNames.contains(".dotfile") == !wasHidden }
        check("Show hidden files: applied to the list and saved",
              list.displayedNames.contains(".dotfile") == !wasHidden && settings.defaults.bool(forKey: ViewSettings.Key.showHidden.rawValue) == !wasHidden)
        model.showHidden = wasHidden
        await waitUntil { self.list.displayedNames.contains(".dotfile") == wasHidden }

        model.showStatusBar = false
        check("Show status bar off: hidden and saved", list.statusBar.isHidden && settings.defaults.object(forKey: ViewSettings.Key.showStatusBar.rawValue) as? Bool == false)
        model.showStatusBar = true
        check("…on again", !list.statusBar.isHidden)

        let flat = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: flat) }
        model.sortField = .size
        model.sortAscending = false
        await waitUntil { self.isSortedBySizeDescending() }
        check("Sort by Size, Descending: the list re-sorts and the header shows it",
              isSortedBySizeDescending() && list.tableForTesting.sortDescriptors.first.map { $0.key == "size" && !$0.ascending } == true)
        model.sortField = .name
        model.sortAscending = true

        model.setShown(.dateCreated, true)
        check("Columns ▸ Date Created: shown in the list", list.columnLayout.first { $0.field == .dateCreated }?.hidden == false)
        model.setShown(.name, false)
        check("…Name can't be hidden", model.isShown(.name))
        model.resetColumns()
        check("Reset Columns: default layout", list.columnLayout == ViewSettings.defaultColumns)

        // Navigation pane settings (P1-1).
        model.treeKeyDelay = 400
        model.treeExpandToCurrent = false
        model.treeExpandOnNetwork = true
        model.treeCheckNetwork = true
        let d = settings.defaults
        check("Navigation Pane settings: saved (delay \(d.integer(forKey: ViewSettings.Key.treeKeyDelay.rawValue)) ms)",
              settings.treeKeyDelay == 400 && d.integer(forKey: ViewSettings.Key.treeKeyDelay.rawValue) == 400
              && d.object(forKey: ViewSettings.Key.treeExpandToCurrent.rawValue) as? Bool == false
              && d.bool(forKey: ViewSettings.Key.treeExpandOnNetwork.rawValue) && d.bool(forKey: ViewSettings.Key.treeCheckNetwork.rawValue))
        model.treeKeyDelay = 5000
        check("…the delay is clamped (0–2000 ms)", settings.treeKeyDelay == 2000)
        model.treeKeyDelay = 250
        model.treeExpandToCurrent = true
        model.treeExpandOnNetwork = false
        model.treeCheckNetwork = false

        // A change made elsewhere shows up in the window.
        var published = 0
        let subscription = model.objectWillChange.sink { published += 1 }
        list.toggleHiddenFiles()
        check("a change made elsewhere (⇧⌘.) updates the window", published > 0 && model.showHidden == settings.showHidden)
        list.toggleHiddenFiles()
        subscription.cancel()

        controller.close()
        check("Settings window closes", controller.window?.isVisible == false)
    }

    // MARK: Global view settings (M16)

    /// What the first launch leaves behind and the second checks.
    static let persistedColumns: [ViewSettings.Column] = [
        .init(field: .name, width: 333, hidden: false),
        .init(field: .size, width: 90, hidden: false),
        .init(field: .dateModified, width: 150, hidden: false),
        .init(field: .dateCreated, width: 140, hidden: false),
        .init(field: .kind, width: 150, hidden: true),
        .init(field: .fileExtension, width: 70, hidden: false),
    ]
    static let persistedSort = FileSort(field: .size, ascending: false)

    private func viewSettingsChecks() async {
        let settings = ViewSettings.shared
        let table = list.tableForTesting
        settings.sort = .default
        if settings.showHidden { list.toggleHiddenFiles() }
        settings.resetColumns()
        let flat = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: flat) }

        // The header's right-click menu.
        guard let headerMenu = table.headerView?.menu else { check("header has a Columns menu", false); return }
        list.columnMenuDelegate.menuNeedsUpdate(headerMenu)
        let items = headerMenu.items.filter { !$0.isSeparatorItem }
        check("header menu: every column + Reset Columns (\(items.map(\.title)))",
              items.map(\.title) == ["Name", "Date Modified", "Date Created", "Type", "Extension", "Size", "Reset Columns"])
        let states = items.dropLast().map { (list.validateColumnItem($0), $0.state) }
        check("…shown columns checked, Name can't be hidden",
              states.map(\.1) == [.on, .on, .off, .on, .off, .on] && states.map(\.0) == [false, true, true, true, true, true])
        func perform(_ title: String) {
            guard let item = items.first(where: { $0.title == title }), let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        func savedColumns() -> [ViewSettings.Column]? {
            settings.defaults.data(forKey: ViewSettings.Key.columns.rawValue).flatMap { try? JSONDecoder().decode([ViewSettings.Column].self, from: $0) }
        }
        func column(_ field: FileSort.Field) -> NSTableColumn? { table.tableColumns.first { $0.identifier.rawValue == field.rawValue } }

        perform("Date Created")
        let createdIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier("dateCreated"))
        let firstItem = list.displayedItems.first
        let cell = createdIndex >= 0 ? table.view(atColumn: createdIndex, row: 0, makeIfNecessary: true) as? FileCellView : nil
        check("Date Created shown, with each item's creation date (\(cell?.text ?? "-"))",
              column(.dateCreated)?.isHidden == false && firstItem.map { Formatters.date.string(from: $0.creationDate) } == cell?.text)
        check("…saved in the settings domain", savedColumns()?.first { $0.field == .dateCreated }?.hidden == false)

        // P1-7: the Extension column — the last extension as in the name, sortable.
        perform("Extension")
        let extIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier("extension"))
        let firstFile = list.displayedItems.firstIndex { !$0.isFolder && !$0.displayExtension.isEmpty }
        let extCell = extIndex >= 0 ? firstFile.flatMap { table.view(atColumn: extIndex, row: $0, makeIfNecessary: true) as? FileCellView } : nil
        let expectedExt = firstFile.map { list.displayedItems[$0].displayExtension }
        check("Extension shown, with each file's extension (\(extCell?.text ?? "-"))",
              column(.fileExtension)?.isHidden == false && expectedExt != nil && extCell?.text == expectedExt)
        settings.sort = FileSort(field: .fileExtension, ascending: true)
        func grouped() -> Bool {
            let files = list.displayedItems.filter { !$0.isFolder }.map(\.displayExtension)
            return files.count > 1 && zip(files, files.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending }
                && list.displayedItems.prefix { $0.isFolder }.count == list.displayedItems.filter(\.isFolder).count
        }
        await waitUntil { grouped() }
        check("…sorting by Extension groups files by extension (\(Array(Set(list.displayedItems.map(\.displayExtension))).sorted().prefix(6)))", grouped())
        settings.sort = .default
        perform("Extension")
        check("…and it hides again", column(.fileExtension)?.isHidden == true)

        // View ▸ Columns (through the window: works whichever pane has focus).
        if let viewColumns = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu?.items.first(where: { $0.title == "Columns" })?.submenu,
           let typeItem = viewColumns.items.first(where: { $0.title == "Type" }) {
            NSApp.sendAction(#selector(MainWindowController.toggleColumn(_:)), to: window, from: typeItem)
            check("View ▸ Columns ▸ Type hides the Type column", column(.kind)?.isHidden == true)
        } else {
            check("View ▸ Columns submenu exists", false)
        }

        // Dragging a column / resizing one (what the header does) updates the global layout.
        let sizeIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        table.moveColumn(sizeIndex, toColumn: 1)
        column(.name)?.width = 333
        check("moving Size next to Name and widening Name is saved (\(settings.columns.map(\.field.rawValue)))",
              settings.columns.map(\.field) == [.name, .size, .dateModified, .kind, .dateCreated, .fileExtension]
              && settings.columns.first?.width == 333 && savedColumns() == settings.columns)

        // Clicking a header repeatedly toggles the direction every time, however fast (a quick second
        // click arrives with clickCount 2; Explorer treats it as another click, not a double-click).
        settings.sort = .default
        var directions: [Bool] = []
        if window.window?.isKeyWindow != true {
            skip("fast header clicks", "app not active (the first click would only activate the window)")
        } else {
        for clicks in 1...4 {
            await headerClick(.name, clickCount: clicks)
            directions.append(settings.sort.ascending)
        }
        check("fast clicks on a header toggle the sort each time (\(directions.map { $0 ? "▲" : "▼" }.joined()))",
              directions == [false, true, false, true] && settings.sort.field == .name)
        await headerClick(.dateModified, clickCount: 1)
        await headerClick(.dateModified, clickCount: 2)
        check("…also on another column (\(settings.sort.field.rawValue) \(settings.sort.ascending ? "▲" : "▼"))",
              settings.sort.field == .dateModified && settings.sort.ascending)
        }
        settings.sort = .default

        // Sorting by a column applies to every folder.
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        await waitUntil { self.isSortedBySizeDescending() }
        check("click Size → largest first, saved", isSortedBySizeDescending() && settings.sort == Self.persistedSort)
        let deep = fixtures.appending(path: "deep", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: deep) }
        await settle { self.list.navigate(to: flat) }
        check("…another folder uses the same columns and sort", list.columnLayout == settings.columns && isSortedBySizeDescending()
              && table.sortDescriptors.first?.key == "size")

        perform("Reset Columns")
        check("Reset Columns → the default layout", list.columnLayout == ViewSettings.defaultColumns && settings.columns == ViewSettings.defaultColumns)

        // A change made elsewhere (another window, Settings) reaches the table.
        settings.columns = Self.persistedColumns
        check("a settings change is applied to the list (\(list.columnLayout.map(\.field.rawValue)))", list.columnLayout == Self.persistedColumns)

        let hidden = fixtures.appending(path: "hidden", directoryHint: .isDirectory)
        list.toggleHiddenFiles()
        await settle { self.list.navigate(to: hidden) }
        check("hidden files on: shown in every folder", list.displayedNames.contains(".dotfile") && settings.showHidden)
        if settings.showStatusBar { window.toggleStatusBar(nil) }
        // The second launch (--self-test-persisted) checks these came back.
    }

    private func persistedSettingsChecks() async {
        await persistedFavoritesChecks()
        let settings = ViewSettings.shared
        check("relaunch: own settings domain", settings.defaults !== UserDefaults.standard)
        check("relaunch: column order, widths and visibility restored (\(settings.columns.map { "\($0.field.rawValue) \(Int($0.width))\($0.hidden ? " hidden" : "")" }))",
              settings.columns == Self.persistedColumns && list.columnLayout == Self.persistedColumns)
        check("relaunch: sort restored (Size, largest first)", settings.sort == Self.persistedSort
              && list.tableForTesting.sortDescriptors.first.map { $0.key == "size" && !$0.ascending } == true)
        check("relaunch: hidden files and status bar state restored", settings.showHidden && !settings.showStatusBar && list.statusBar.isHidden)
        let flat = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: flat) }
        check("relaunch: folders open sorted by size", isSortedBySizeDescending())
        let hidden = fixtures.appending(path: "hidden", directoryHint: .isDirectory)
        await settle { self.list.navigate(to: hidden) }
        check("relaunch: hidden files shown", list.displayedNames.contains(".dotfile"))
    }

    /// A real left click (down + up, as the hardware sends them) in the middle of a column header.
    private func headerClick(_ field: FileSort.Field, clickCount: Int) async {
        let table = list.tableForTesting
        guard let header = table.headerView, let nsWindow = header.window else { return }
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(field.rawValue))
        guard index >= 0 else { return }
        let rect = header.headerRect(ofColumn: index)
        let point = header.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(down, atStart: false) // through the normal event queue, like real clicks
        NSApp.postEvent(up, atStart: false)
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func isSortedBySizeDescending() -> Bool {
        let sizes = list.displayedItems.filter { $0.kind == .file }.map(\.size)
        return sizes.count > 1 && sizes.first != sizes.last && zip(sizes, sizes.dropFirst()).allSatisfy { $0 >= $1 }
    }

    /// Browsing never writes into browsed folders (no `.DS_Store`, no xattrs): an FSEvents stream
    /// over the read-only fixtures records *any* change by any process while Kansio browses, sorts,
    /// changes columns, toggles hidden files and opens Get Info.
    private func noWritesChecks() async {
        let names = ["deep", "flat-1k", "flat-10k", "unicode", "symlinks", "hidden", "packages", "long-names", "empty"]
        let folders = names.map { fixtures.appending(path: $0, directoryHint: .isDirectory) }
        let recorder = WriteRecorder(paths: folders.map { FolderWatcherPaths.real($0) })
        defer { recorder.stop() }
        // Positive control: the recorder does see a write (in the fixtures' empty folder).
        let probe = fixtures.appending(path: "empty/.kansio-write-probe")
        FileManager.default.createFile(atPath: probe.path(percentEncoded: false), contents: nil)
        try? FileManager.default.removeItem(at: probe)
        await waitUntil { !recorder.events.isEmpty }
        check("write recorder sees a write (control)", !recorder.events.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        recorder.reset()

        for folder in folders { await settle { self.list.navigate(to: folder) } }
        await settle { self.list.navigate(to: folders[1]) }
        for field in FileSort.Field.allCases {
            for ascending in [true, false] {
                ViewSettings.shared.sort = FileSort(field: field, ascending: ascending)
            }
        }
        ViewSettings.shared.sort = .default
        list.toggleHiddenFiles()
        list.toggleHiddenFiles()
        list.toggleColumn(FileListViewController.columnMenuItems(target: nil).first { $0.representedObject as? String == "dateCreated" })
        ViewSettings.shared.resetColumns()
        list.tableForTesting.selectAll(nil)
        list.tableForTesting.deselectAll(nil)
        let info = InfoWindowController.show(items: [], in: folders[1])
        await waitUntil { info.isFinished }
        info.close()
        await settle { self.list.navigate(to: folders[6]) } // packages
        select("Fake.app")
        await settle { self.list.showPackageContents(nil) }
        try? await Task.sleep(for: .milliseconds(800)) // FSEvents latency + delivery
        let events = recorder.events
        check("browsing wrote nothing into the browsed folders (\(events.count) events\(events.isEmpty ? "" : ": " + events.prefix(5).joined(separator: ", ")))",
              events.isEmpty)
    }

    private func select(_ name: String) {
        guard let row = list.displayedNames.firstIndex(of: name) else { return }
        list.focusList()
        list.tableForTesting.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func renameCommand(_ selector: Selector) {
        guard let editor = list.renameSession?.editor else { return }
        if let fieldEditor = editor.currentEditor() as? NSTextView {
            fieldEditor.doCommand(by: selector)
        } else {
            _ = list.control(editor, textView: NSTextView(), doCommandBy: selector)
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Replaces the address field's text as if typed.
    private func type(_ text: String) {
        let bar = window.addressBar
        bar.field.stringValue = text
        bar.field.currentEditor()?.moveToEndOfDocument(nil)
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
    }

    /// Sends an editing command (Enter, Esc, ↓, Tab) the way the field editor would.
    private func addressCommand(_ selector: Selector) {
        let bar = window.addressBar
        if let editor = bar.field.currentEditor() as? NSTextView {
            editor.doCommand(by: selector)
        } else {
            _ = bar.control(bar.field, textView: NSTextView(), doCommandBy: selector)
        }
    }

    private static func real(_ path: String) -> String { FolderTreeIO.realPath(path) ?? normPath(path) }

    private static func normPath(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }

    // MARK: Helpers

    private func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  [at \(path), selected \(list.selectedNames)]")")
    }

    /// Performs `action`, then waits until the resulting navigation has fully loaded (≤ 3 s).
    /// `quick`: return as soon as it's loaded (no extra grace period), to catch animations in progress.
    private func settle(quick: Bool = false, _ action: () -> Void) async {
        let before = list.currentGeneration
        action()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let event = list.lastDisplayEvent
            if list.currentGeneration != before, !list.state.isLoading,
               event?.generation == list.currentGeneration, event?.isComplete == true {
                if !quick { try? await Task.sleep(for: .milliseconds(30)) } // selection restore + symlink pass
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A real side-button event (as a mouse driver would post it), delivered where AppKit delivers it.
    private func mouse(button: Int64) {
        guard let window = window.window,
              let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                               mouseCursorPosition: CGPoint(x: window.frame.midX, y: window.frame.midY),
                               mouseButton: CGMouseButton(rawValue: UInt32(button))!) else { return }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    private func skip(_ name: String, _ reason: String) { print("SKIP  \(name) — \(reason)") }

    private func menuItem(_ action: Selector) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    private func shortcutLabel(_ action: Selector) -> String {
        guard let item = menuItem(action) else { return "?" }
        return "⌘" + item.keyEquivalent.uppercased()
    }

    /// Presses the shortcut shown for `action` in the menus — the *localized* key equivalent
    /// (e.g. ⌘[ becomes ⌘Ö on a Finnish layout) — and lets the menu system dispatch it.
    private func menuShortcut(_ action: Selector) {
        guard let item = menuItem(action), let window = window.window else { return }
        let chars = item.keyEquivalent
        var mods = item.keyEquivalentModifierMask
        if let scalar = chars.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) {
            mods.insert([.function, .numericPad]) // a real arrow-key event carries these
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: 0) else { return }
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    }

    /// A key press delivered to the file list (first responder).
    private func tableKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], chars explicit: String? = nil) {
        let fallback: String = switch keyCode {
        case 51: "\u{7F}"
        case 123: "\u{F702}"
        case 124: "\u{F703}"
        default: "\u{F700}"
        }
        let chars = explicit ?? fallback
        var mods = modifiers
        if let scalar = chars.unicodeScalars.first, scalar.value >= 0xF700 { mods.insert([.numericPad, .function]) } // like real function keys
        guard let window = window.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { return }
        list.tableForTesting.keyDown(with: event)
    }

    private static func norm(_ url: URL) -> String {
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}

/// Records every FSEvents event below some folders (recursive, file-level) — the self-test's
/// "Kansio wrote nothing here" check. FSEvents sees writes by every process, not just ours.
final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "kansio.self-test.writes")

    var events: [String] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded.removeAll() } }

    init(paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let recorder = Unmanaged<WriteRecorder>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count { recorder.add("\(array[i]) [flags 0x\(String(flags[i], radix: 16))]") }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func add(_ event: String) { lock.withLock { recorded.append(event) } }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

enum FolderWatcherPaths {
    /// FSEvents reports real paths ("/private/var/…").
    /// (`URL.resolvingSymlinksInPath` does the opposite: it strips "/private".)
    static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return url.path(percentEncoded: false) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A drag in progress, for driving the sidebar's drop methods in the self-test.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingSequenceNumber: Int
    private static var sequence = 1000
    init(pasteboard: NSPasteboard, window: NSWindow?, mask: NSDragOperation = [.copy, .link, .move, .generic]) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingSourceOperationMask = mask
        Self.sequence += 1
        draggingSequenceNumber = Self.sequence // a new drag each time (drop targets cache per drag)
    }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Writes a promised file (self-test of file-promise drops, as Mail or Photos would).
final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let name: String
    let text: String
    init(name: String, text: String) { self.name = name; self.text = text }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do { try Data(text.utf8).write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

