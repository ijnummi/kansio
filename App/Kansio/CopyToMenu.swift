import AppKit
import FileSystemKit

/// Copy To ▸ / Move To ▸ (P3-3, Explorer's "Copy to" / "Move to"): the selected items go to a folder picked from
/// the destinations used last, the most used folders, or **Choose Folder…** (an open panel). Built when the menu
/// opens; a destination the items can't go to (into themselves, or moving into the folder they're in) is disabled.
/// Runs through the copy engine like a paste (progress, conflicts, undo).
@MainActor
final class CopyToMenu: NSObject, NSMenuDelegate {
    enum Kind {
        case copy, move
        var title: String { self == .copy ? "Copy To" : "Move To" }
        var verb: String { self == .copy ? "Copy" : "Move" }
    }

    let kind: Kind
    /// Which list the menu acts on (the context menu's own list, or the frontmost window's).
    let list: () -> FileListViewController?

    init(kind: Kind, list: @escaping () -> FileListViewController?) {
        self.kind = kind
        self.list = list
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: kind.title)
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    /// Recent destinations, then the most used folders not among them, then Choose Folder….
    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = list()
        let sources = list.map { $0.selectedItems.map($0.url(of:)) } ?? []
        let prepared = RightDrag.Sources(sources)
        let volumes = list?.mountedVolumes ?? []
        func allowed(_ url: URL) -> Bool {
            guard !sources.isEmpty else { return false }
            let checks = FileDrop.dropChecks(paths: prepared.paths, parents: prepared.parents, destination: url, volumes: volumes)
            return kind == .copy ? checks.copy : checks.move
        }
        func add(_ urls: [URL]) {
            let names = urls.map(FolderUsageStore.displayName)
            for (url, name) in zip(urls, names) {
                let item = menu.addItem(withTitle: name, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = IconCache.shared.folderIcon
                item.isEnabled = allowed(url)
                let location = FolderUsageStore.abbreviated(url.deletingLastPathComponent())
                if names.filter({ $0 == name }).count > 1 { item.subtitle = location }
                item.toolTip = url.path(percentEncoded: false)
                item.setAccessibilityLabel("\(name), in \(location)")
            }
        }
        let recent = CopyToDestinations.shared.recent
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Recent"))
            add(recent)
        }
        let recentKeys = Set(recent.map(FolderUsageStore.path))
        let mostUsed = FolderUsageStore.shared.top().filter { !recentKeys.contains(FolderUsageStore.path($0)) }
        if !mostUsed.isEmpty {
            menu.addItem(.sectionHeader(title: "Most Used"))
            add(mostUsed)
        }
        if !recent.isEmpty || !mostUsed.isEmpty { menu.addItem(.separator()) }
        let choose = menu.addItem(withTitle: "Choose Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "")
        choose.target = self
        choose.isEnabled = !sources.isEmpty
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let list = list() else { return }
        CopyToDestinations.perform(kind, sources: list.selectedItems.map(list.url(of:)), to: url, list: list)
    }

    @objc func chooseFolder(_ sender: Any?) {
        guard let list = list() else { return }
        let sources = list.selectedItems.map(list.url(of:))
        guard !sources.isEmpty else { NSSound.beep(); return }
        let kind = kind
        CopyToDestinations.chooseFolder(kind, count: sources.count, list: list) { url in
            guard let url else { return }
            CopyToDestinations.perform(kind, sources: sources, to: url, list: list)
        }
    }
}

/// The destinations used last (UserDefaults, the app's domain — the self-test has its own) and carrying out a choice.
@MainActor
final class CopyToDestinations {
    static let shared = CopyToDestinations()
    private static let key = "copyTo.recent"
    private let defaults = ViewSettings.shared.defaults
    private var stored: RecentDestinations

    private init() {
        stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(RecentDestinations.self, from: $0) } ?? RecentDestinations()
    }

    var recent: [URL] { stored.paths.map { URL(filePath: $0, directoryHint: .isDirectory) } }

    func record(_ url: URL) {
        stored.add(url.standardizedFileURL.path(percentEncoded: false))
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }

    func removeAll() {
        stored.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    /// Self-test: answers Choose Folder… instead of the open panel.
    static var chooserOverride: ((CopyToMenu.Kind) -> URL?)?

    /// The open panel, as a sheet on the list's window (it can make a new folder too).
    static func chooseFolder(_ kind: CopyToMenu.Kind, count: Int, list: FileListViewController, completion: @escaping (URL?) -> Void) {
        if let chooserOverride { completion(chooserOverride(kind)); return }
        guard let window = list.view.window else { completion(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = kind.verb
        panel.message = "\(kind.verb) \(count == 1 ? "1 item" : "\(count.formatted()) items") to:"
        panel.directoryURL = shared.recent.first ?? list.folder
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Copies or moves `sources` into `destination` through `list`'s copy engine and remembers the destination.
    static func perform(_ kind: CopyToMenu.Kind, sources: [URL], to destination: URL, list: FileListViewController) {
        guard !sources.isEmpty else { return }
        let prepared = RightDrag.Sources(sources)
        let checks = FileDrop.dropChecks(paths: prepared.paths, parents: prepared.parents, destination: destination, volumes: list.mountedVolumes)
        guard checks.copy else { list.showMessage("Can’t put a folder inside itself."); return }
        guard kind == .copy || checks.move else {
            list.showMessage("The items are already in “\(FolderUsageStore.displayName(destination))”.")
            return
        }
        shared.record(destination)
        list.runCopyEngine(kind == .copy ? .copy : .move, sources: sources, into: destination, actionName: kind.verb)
    }
}
