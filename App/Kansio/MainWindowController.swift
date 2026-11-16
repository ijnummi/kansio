import AppKit
import FileSystemKit

/// One browser window: sidebar (Favorites + Volumes) | details view, with a unified toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let fileList: FileListViewController
    let sidebar = SidebarViewController()
    private let split = NSSplitViewController()

    init(initialFolder: URL) {
        fileList = FileListViewController(folder: initialFolder)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: fileList)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "MainSplit"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 660))
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed // tabs are P1
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        fileList.onStateChange = { [weak self] state in self?.update(for: state) }
        sidebar.onSelect = { [weak self] url in self?.fileList.navigate(to: url) }
        sidebar.onVolumeRemoved = { [weak self] volume in self?.volumeRemoved(volume) }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
            sidebar.onVolumesChanged = { volumes in
                print("sidebar volumes: \(volumes.map(\.name))")
                fflush(stdout)
            }
        }
        update(for: fileList.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func update(for state: FileListViewController.State) {
        guard let window else { return }
        let url = state.folder
        window.title = url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent
        window.subtitle = state.summary
        sidebar.showCurrentFolder(url)
    }

    /// The volume we're browsing was ejected: go Home and say why (inline, no alert).
    private func volumeRemoved(_ volume: Volume) {
        guard volume.contains(path: fileList.folder.path(percentEncoded: false)) else { return }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil { print("ejected while browsing: \(volume.name) → Home"); fflush(stdout) }
        fileList.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        fileList.showMessage("“\(volume.name)” was ejected.")
    }

    // MARK: Go menu

    enum Favorite: Int { case home, desktop, documents, downloads, applications }

    @objc func goToFavorite(_ sender: NSMenuItem) {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL { fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser }
        let url: URL = switch Favorite(rawValue: sender.tag) {
        case .desktop: dir(.desktopDirectory)
        case .documents: dir(.documentDirectory)
        case .downloads: dir(.downloadsDirectory)
        case .applications: URL(filePath: "/Applications", directoryHint: .isDirectory)
        default: fm.homeDirectoryForCurrentUser
        }
        fileList.navigate(to: url)
        fileList.focusList()
    }

    // MARK: Toolbar (Back/Forward/Up arrive in M5)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil // only system items so far
    }
}
