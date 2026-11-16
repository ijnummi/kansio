import AppKit
import FileSystemKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let fileList: FileListViewController

    init(initialFolder: URL) {
        fileList = FileListViewController(folder: initialFolder)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = fileList
        window.setContentSize(NSSize(width: 960, height: 620))
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed // tabs are P1
        super.init(window: window)
        window.delegate = self
        fileList.onStateChange = { [weak self] state in self?.update(for: state) }
        update(for: fileList.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func update(for state: FileListViewController.State) {
        guard let window else { return }
        let url = state.folder
        window.title = url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent
        window.representedURL = url // proxy icon; Cmd-click the title shows the path
        window.subtitle = state.summary
    }
}
