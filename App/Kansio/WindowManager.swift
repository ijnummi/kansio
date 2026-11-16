import AppKit
import FileSystemKit

/// Browser windows and tabs (P1-3). A tab is a window in a native macOS tab group, so the tab bar,
/// ⌃Tab cycling, dragging tabs between windows and "Merge All Windows" are AppKit's; each tab has
/// its own folder, history, selection and navigation pane. A tab that isn't shown (another tab
/// selected, minimized, app hidden) pauses: no listing, watching or icon loading — its model stays,
/// and FSEvents replays what changed when it's shown again.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    static let tabbingIdentifier = "dev.kansio.browser"

    private(set) var controllers: [MainWindowController] = []

    /// A window controller (not shown yet). `active: false`: lists its folder only when first shown.
    func make(at url: URL, active: Bool = true) -> MainWindowController {
        let controller = MainWindowController(initialFolder: url, startsActive: active)
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        return controller
    }

    /// ⌘T / Open in New Tab / middle-click: a tab after `window`'s. `background`: not selected.
    @discardableResult
    func openTab(at url: URL, next window: NSWindow, background: Bool) -> MainWindowController {
        let controller = make(at: url, active: !background)
        guard let tab = controller.window else { return controller }
        window.addTabbedWindow(tab, ordered: .above)
        if background {
            window.makeKeyAndOrderFront(nil) // keep the current tab selected
        } else {
            tab.makeKeyAndOrderFront(nil)
        }
        controller.updateActivity()
        (window.windowController as? MainWindowController)?.updateActivity()
        return controller
    }

    /// ⌘N / Open in New Window: a separate window (even with "prefer tabs" on), cascaded from `window`.
    @discardableResult
    func openWindow(at url: URL, cascadingFrom window: NSWindow?) -> MainWindowController {
        let controller = make(at: url)
        guard let newWindow = controller.window else { return controller }
        newWindow.tabbingMode = .disallowed
        if let window {
            newWindow.setFrame(window.frame, display: false)
            newWindow.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY)))
        }
        controller.showWindow(nil)
        newWindow.tabbingMode = .automatic
        return controller
    }
}
