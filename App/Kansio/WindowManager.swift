import AppKit
import FileSystemKit

/// Browser windows (P1-3). Tabs live inside a window (`MainWindowController` — chosen 2026-11-16:
/// one window, our own tab strip in the title-bar row, Explorer layout), so switching tabs is a view
/// swap, not an AppKit window switch. This keeps track of the windows.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [MainWindowController] = []

    /// A window controller (not shown yet).
    func make(at url: URL, active: Bool = true) -> MainWindowController {
        register(MainWindowController(initialFolder: url, startsActive: active))
    }

    private func register(_ controller: MainWindowController) -> MainWindowController {
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        return controller
    }

    /// ⌘N / Open in New Window: a separate window, cascaded from `window`.
    @discardableResult
    func openWindow(at url: URL, cascadingFrom window: NSWindow?) -> MainWindowController {
        show(make(at: url), cascadingFrom: window)
    }

    /// Move Tab to New Window: the tab (its folder, history, selection) becomes a window of its own.
    @discardableResult
    func openWindow(adopting list: FileListViewController, cascadingFrom window: NSWindow?) -> MainWindowController {
        show(register(MainWindowController(tabs: [list])), cascadingFrom: window)
    }

    private func show(_ controller: MainWindowController, cascadingFrom window: NSWindow?) -> MainWindowController {
        if let window, let newWindow = controller.window {
            newWindow.setFrame(window.frame, display: false)
            newWindow.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY)))
        }
        controller.showWindow(nil)
        return controller
    }
}
