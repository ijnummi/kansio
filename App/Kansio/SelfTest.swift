import AppKit
import FileSystemKit
import Quartz

/// `Kansio --self-test <fixtures-dir>`: drives navigation in the real app — history, Up,
/// mouse side buttons (synthesized button 4/5 events), keyboard shortcuts through the
/// normal event path, rapid navigation — and checks the result after each step.
/// Read-only: it only lists folders. Prints PASS/FAIL per check; exit code 1 on any failure.
@MainActor
final class SelfTest {
    private let window: MainWindowController
    private let fixtures: URL
    private var failures = 0

    init(window: MainWindowController, fixtures: URL) {
        self.window = window
        self.fixtures = fixtures
    }

    private var list: FileListViewController { window.fileList }
    private var path: String { Self.norm(list.folder) }

    func run() async {
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
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
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
