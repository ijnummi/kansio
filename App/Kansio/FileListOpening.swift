import AppKit
import FileSystemKit
import UniformTypeIdentifiers

/// Opens files with apps. Injectable: the self-test records calls so no real app launches.
@MainActor
protocol Opener: AnyObject {
    /// Opens `urls` with `app` (nil = each file's default app). `completion` gets the first error.
    func open(_ urls: [URL], withApplication app: URL?, completion: @escaping @MainActor (Error?) -> Void)
    /// Show in Finder.
    func reveal(_ urls: [URL])
}

/// The real thing: LaunchServices via NSWorkspace (asynchronous; errors come back in the completion).
@MainActor
final class WorkspaceOpener: Opener {
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func open(_ urls: [URL], withApplication app: URL?, completion: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let done: @Sendable (Error?) -> Void = { error in
            let message = error.map { $0 as NSError }
            Task { @MainActor in completion(message) }
        }
        if let app {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in done(error) }
        } else {
            for url in urls {
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in done(error) }
            }
        }
    }
}

/// Self-test double: records what would have been opened.
@MainActor
final class RecordingOpener: Opener {
    private(set) var calls: [(urls: [URL], app: URL?)] = []
    private(set) var revealed: [URL] = []
    var failNext: Error?
    func reveal(_ urls: [URL]) { revealed = urls }
    func open(_ urls: [URL], withApplication app: URL?, completion: @escaping @MainActor (Error?) -> Void) {
        calls.append((urls, app))
        let error = failNext
        failNext = nil
        completion(error)
    }
}

/// M8: opening items, Open With, Show Package Contents, and the list's context menu.
extension FileListViewController: NSMenuDelegate {

    // MARK: Open

    /// Enter / double-click / File ▸ Open.
    func openSelection() {
        let items = selectedItems
        if items.count == 1 { open(items[0]); return }
        // Several items: open the files (Explorer); folders would each need a window/tab (P1).
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else { NSSound.beep(); return }
        openWithApps(files.map(url(of:)), app: nil)
    }

    @objc func openSelectionAction(_ sender: Any?) { openSelection() }

    func open(_ item: FileItem) {
        let url = url(of: item)
        switch item.kind {
        case .directory where item.isFolder:
            navigate(to: url)
        case .symlink where item.flags.contains(.linkToFolder):
            // Explorer-style: stay on the link's own path (Up returns to where the link lives).
            navigate(to: URL(filePath: self.url(of: item).path(percentEncoded: false), directoryHint: .isDirectory))
        case .symlink where item.flags.contains(.brokenLink):
            showMessage("“\(Self.displayName(item.name))” points to an item that doesn’t exist.")
        case .symlink where item.flags.isDisjoint(with: .linkTarget):
            // Not classified yet (resolution still running): resolve off-main, it can hang on a dead mount.
            Task.detached { [weak self] in
                let flags = SymlinkResolver.classify(url.path(percentEncoded: false))
                await self?.openLink(named: item.name, at: url, flags: flags)
            }
        case .file where item.flags.contains(.alias):
            openAlias(item, at: url)
        default:
            openWithApps([url], app: nil)
        }
    }

    private func openLink(named name: String, at url: URL, flags: FileItem.Flags) {
        if flags.contains(.linkToFolder) {
            navigate(to: folder.appending(path: name, directoryHint: .isDirectory))
        } else if flags.contains(.brokenLink) {
            showMessage("“\(Self.displayName(name))” points to an item that doesn’t exist.")
        } else {
            openWithApps([url], app: nil)
        }
    }

    /// Finder aliases point elsewhere (unlike symlinks there's no "logical path" to keep):
    /// a folder alias navigates to the real target, a file alias opens the target.
    private func openAlias(_ item: FileItem, at url: URL) {
        let gen = generation
        Task { [weak self] in
            let target = await Aliases.resolve(url)
            guard let self, gen == self.generation else { return }
            guard let target else {
                self.showMessage("“\(Self.displayName(item.name))” can’t be opened because the original item can’t be found.")
                return
            }
            switch await PathInput.target(of: target, timeout: .seconds(3)) {
            case .folder: self.navigate(to: target)
            case .item: self.openWithApps([target], app: nil)
            default: self.showMessage("“\(Self.displayName(item.name))” can’t be opened because the original item can’t be found.")
            }
        }
    }

    /// Opens files with an app (nil = default), reporting failures inline.
    func openWithApps(_ urls: [URL], app: URL?) {
        guard !urls.isEmpty else { return }
        opener.open(urls, withApplication: app) { [weak self] error in
            guard let self, let error else { return }
            self.showMessage(Self.openErrorText(error, urls: urls))
        }
    }

    private static func openErrorText(_ error: Error, urls: [URL]) -> String {
        let ns = error as NSError
        let noApp = ns.code == -10814 || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -10814 // kLSApplicationNotFoundErr
        let name = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        if noApp { return "No app is set to open \(name). Use Open With ▸ Other… to choose one." }
        return "Couldn’t open \(name): \(ns.localizedDescription)"
    }

    // MARK: Show Package Contents

    @objc func showPackageContents(_ sender: Any?) {
        guard selectedItems.count == 1, let item = selectedItems.first,
              item.isPackage || item.flags.contains(.linkToPackage) else { NSSound.beep(); return }
        navigate(to: URL(filePath: url(of: item).path(percentEncoded: false), directoryHint: .isDirectory))
    }

    var selectionIsSinglePackage: Bool {
        selectedItems.count == 1 && (selectedItems[0].isPackage || selectedItems[0].flags.contains(.linkToPackage))
    }

    /// The selected items that Open With applies to (not folders).
    var openWithURLs: [URL] {
        selectedItems.filter { !$0.isFolder }.map(url(of:))
    }

    // MARK: Copy Path / Show in Finder

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedItems.isEmpty ? [folder] : selectedItems.map(url(of:))
        pasteboard.clearContents()
        pasteboard.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedItems.isEmpty ? [folder] : selectedItems.map(url(of:))
        opener.reveal(urls)
    }

    /// The folder in `row` (folders and links to folders), for middle-click / Open in New Tab.
    func folderURL(atRow row: Int) -> URL? {
        guard row >= 0, row < rows.count, rows[row].isFolder else { return nil }
        return url(of: rows[row])
    }

    private var windowController: MainWindowController? { view.window?.windowController as? MainWindowController }

    @objc func openInNewTab(_ sender: Any?) {
        selectedItems.filter(\.isFolder).map(url(of:)).forEach { windowController?.openInNewTab($0, background: false) }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        selectedItems.filter(\.isFolder).map(url(of:)).forEach { windowController?.openInNewWindow($0) }
    }

    /// What Pin to Favorites acts on: the selected folders (files are skipped), or this folder.
    var pinTargets: [URL] {
        selectedItems.isEmpty ? [folder] : selectedItems.filter(\.isFolder).map(url(of:))
    }

    /// "Unpin from Favorites" when every target is pinned already.
    var pinTitle: String {
        let targets = pinTargets
        return !targets.isEmpty && targets.allSatisfy(FavoritesStore.shared.isPinned) ? "Unpin from Favorites" : "Pin to Favorites"
    }

    /// ⌃⌘T (Finder's "Add to Sidebar"): pin the selected folders or this folder; unpin if all are pinned.
    @objc func togglePinned(_ sender: Any?) {
        let targets = pinTargets
        guard !targets.isEmpty else { NSSound.beep(); return }
        let store = FavoritesStore.shared
        if targets.allSatisfy(store.isPinned) {
            targets.compactMap(store.entry(for:)).forEach { store.unpin($0.id) }
        } else {
            store.pin(targets.filter { !store.isPinned($0) })
        }
    }

    /// ⌘I: Kansio's own info window for the selection (or for this folder when nothing is selected).
    @objc func getInfo(_ sender: Any?) {
        lastInfoWindow = InfoWindowController.show(items: selectedItems, in: folder)
    }

    // MARK: Context menu

    /// Builds the right-click menu for `row` (-1 = empty area). Right-clicking an unselected
    /// row selects it first (Finder/Explorer); empty space clears the selection.
    func contextMenuItems(forRow row: Int) -> [NSMenuItem] {
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            tableView.deselectAll(nil)
        }
        if isShowingTrash { return trashContextMenuItems() }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mods
            menuItem.target = self
            return menuItem
        }
        var items: [NSMenuItem] = []
        if selectedItems.isEmpty {
            items.append(item("New Folder", #selector(newFolder(_:)), "n", [.command, .shift]))
            items.append(item("New Text Document", #selector(newTextDocument(_:))))
            items.append(.separator())
            items.append(item("Paste", #selector(paste(_:)), "v"))
            items.append(.separator())
            items.append(item("Copy Path", #selector(copyPath(_:))))
            items.append(item("Show in Finder", #selector(showInFinder(_:))))
            items.append(item("Get Info", #selector(getInfo(_:)), "i"))
            items.append(item(pinTitle, #selector(togglePinned(_:)), "t", [.command, .control]))
            return items
        }
        items.append(item("Open", #selector(openSelectionAction(_:)), "o"))
        if !selectedItems.isEmpty, selectedItems.allSatisfy(\.isFolder) {
            items.append(item("Open in New Tab", #selector(openInNewTab(_:))))
            items.append(item("Open in New Window", #selector(openInNewWindow(_:))))
        }
        if !openWithURLs.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu.makeMenu()
            items.append(openWith)
        }
        if selectionIsSinglePackage { items.append(item("Show Package Contents", #selector(showPackageContents(_:)))) }
        items.append(item("Quick Look", #selector(toggleQuickLook(_:)), "y"))
        items.append(.separator())
        items.append(item("Cut", #selector(cut(_:)), "x"))
        items.append(item("Copy", #selector(copy(_:)), "c"))
        items.append(item("Paste", #selector(paste(_:)), "v"))
        items.append(item("Duplicate", #selector(duplicate(_:)), "d"))
        items.append(.separator())
        if selectedItems.count == 1 { items.append(item("Rename", #selector(renameSelection(_:)), "\u{F705}", [])) }
        items.append(item("Move to Trash", #selector(moveToTrash(_:)), "\u{8}"))
        items.append(.separator())
        items.append(item("Copy Path", #selector(copyPath(_:))))
        items.append(item("Show in Finder", #selector(showInFinder(_:))))
        items.append(item("Get Info", #selector(getInfo(_:)), "i"))
        if !pinTargets.isEmpty { items.append(item(pinTitle, #selector(togglePinned(_:)), "t", [.command, .control])) }
        items.append(.separator())
        items.append(item("New Folder", #selector(newFolder(_:)), "n", [.command, .shift]))
        items.append(item("New Text Document", #selector(newTextDocument(_:))))
        return items
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        menu.removeAllItems()
        contextMenuItems(forRow: tableView.clickedRow).forEach(menu.addItem)
    }
}

/// The "Open With" submenu: the default app first, then other apps that can open the selection,
/// then "Other…". Finding apps queries LaunchServices, so it runs off the main thread, is cached
/// per file type, and is prefetched when the selection changes — the menu normally has the
/// answer before it opens, and shows "Loading…" (filled in live) if not.
@MainActor
final class OpenWithMenu: NSObject, NSMenuDelegate {
    struct App: Sendable {
        let url: URL
        let name: String
        let isDefault: Bool
        let icon: SendableReps
    }

    /// Which list the menu acts on (the context menu's own list, or the main window's).
    var list: () -> FileListViewController?
    private static var cache: [String: [App]] = [:]
    private static var inflight: [String: Task<[App], Never>] = [:]
    private var openMenus: [ObjectIdentifier: NSMenu] = [:]

    init(list: @escaping () -> FileListViewController?) {
        self.list = list
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        menu.delegate = self
        return menu
    }

    /// Cache key: what LaunchServices decides by — the set of types (extensions) selected.
    private static func key(for urls: [URL]) -> String {
        Set(urls.map { $0.pathExtension.lowercased() + ($0.hasDirectoryPath ? "/" : "") }).sorted().joined(separator: "|")
    }

    /// Starts computing the app list for `urls` if it isn't cached yet.
    @discardableResult
    static func prefetch(_ urls: [URL]) -> Task<[App], Never>? {
        guard !urls.isEmpty else { return nil }
        let key = key(for: urls)
        if cache[key] != nil { return nil }
        if let running = inflight[key] { return running }
        // LaunchServices decides by type: one representative file per distinct type is enough.
        var seen = Set<String>()
        let representatives = urls.filter { seen.insert($0.pathExtension.lowercased() + ($0.hasDirectoryPath ? "/" : "")).inserted }
        let task = Task.detached(priority: .utility) { Self.computeApps(for: representatives) }
        inflight[key] = task
        Task { @MainActor in
            let apps = await task.value
            cache[key] = apps
            inflight[key] = nil
        }
        return task
    }

    static func cachedApps(for urls: [URL]) -> [App]? { cache[key(for: urls)] }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let urls = list()?.openWithURLs, !urls.isEmpty else {
            menu.removeAllItems()
            menu.addItem(withTitle: "No files selected", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        if let apps = Self.cachedApps(for: urls) {
            fill(menu, apps: apps)
            return
        }
        menu.removeAllItems()
        menu.addItem(withTitle: "Loading…", action: nil, keyEquivalent: "").isEnabled = false
        let task = Self.prefetch(urls)
        Task { [weak self, weak menu] in
            let apps = await task?.value ?? Self.cachedApps(for: urls) ?? []
            guard let self, let menu else { return }
            self.fill(menu, apps: apps) // updates the menu even while it's open
        }
    }

    func fill(_ menu: NSMenu, apps: [App]) {
        menu.removeAllItems()
        if apps.isEmpty {
            menu.addItem(withTitle: "No Compatible Apps", action: nil, keyEquivalent: "").isEnabled = false
        }
        for (i, app) in apps.enumerated() {
            let item = menu.addItem(withTitle: app.isDefault ? "\(app.name) (default)" : app.name,
                                    action: #selector(openWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.url
            let image = NSImage(size: IconCache.pointSize)
            app.icon.reps.forEach { image.addRepresentation($0) }
            item.image = image
            if app.isDefault && i < apps.count - 1 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let other = menu.addItem(withTitle: "Other…", action: #selector(chooseOther(_:)), keyEquivalent: "")
        other.target = self
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let list = list() else { return }
        list.openWithApps(list.openWithURLs, app: app)
    }

    /// Lets the user pick any app (the system chooser, as a sheet on the window).
    @objc func chooseOther(_ sender: Any?) {
        guard let list = list(), let window = list.view.window else { return }
        let urls = list.openWithURLs
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an app to open \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items")."
        panel.beginSheetModal(for: window) { [weak list] response in
            guard response == .OK, let app = panel.url else { return }
            MainActor.assumeIsolated { list?.openWithApps(urls, app: app) }
        }
    }

    /// Off-main: apps that can open *all* of `urls`; the default (of the first) first, then by name.
    nonisolated static func computeApps(for urls: [URL]) -> [App] {
        let workspace = NSWorkspace.shared
        var common: Set<URL>?
        for url in urls {
            let apps = Set(workspace.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
            common = common.map { $0.intersection(apps) } ?? apps
        }
        let defaultApp = workspace.urlForApplication(toOpen: urls[0])?.standardizedFileURL
        let candidates = Array(common ?? [])
        // Several copies of one app (e.g. two versions): show the version to tell them apart.
        let baseNames = candidates.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "") }
        let duplicates = Set(baseNames.filter { name in baseNames.filter { $0 == name }.count > 1 })
        var apps = zip(candidates, baseNames).map { url, name -> App in
            var title = name
            if duplicates.contains(name), let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                title += " (\(version))"
            }
            return App(url: url, name: title, isDefault: url == defaultApp,
                       icon: SendableReps(reps: IconCache.rasterizedReps(workspace.icon(forFile: url.path(percentEncoded: false)))))
        }
        apps.sort { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return NameCollation.compare(a.name, b.name) == .orderedAscending
        }
        return apps
    }
}
