import AppKit
import FileSystemKit

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

        print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

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
    private func tableKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let chars: String = switch keyCode {
        case 51: "\u{7F}"
        case 123: "\u{F702}"
        case 124: "\u{F703}"
        default: "\u{F700}"
        }
        var mods = modifiers
        if keyCode != 51 { mods.insert([.numericPad, .function]) } // arrow keys carry these
        guard let window = window.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { return }
        list.tableForTesting.keyDown(with: event)
    }

    private static func norm(_ url: URL) -> String {
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}
