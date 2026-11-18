import AppKit
import FileSystemKit

extension Notification.Name {
    /// The most used folders changed (a use was counted, or they were reset).
    static let folderUsageDidChange = Notification.Name("dev.kansio.folderUsageDidChange")
}

/// The most used folders (the ⌄ button after the tab strip's "+", and Go ▸ Most Used Folders).
///
/// A folder counts once it has stayed on screen for `ViewSettings.usageDwell` seconds (3 by default), so passing
/// through folders — arrow keys in the tree, Back several times — doesn't. Opening a folder (navigating, a new tab or
/// window) and switching to a tab are weighted by their importance settings. Scores fade by half every 30 days
/// (`FolderUsage`). Stored in the app's UserDefaults (the same domain as `ViewSettings`; the self-test has its own).
@MainActor
final class FolderUsageStore {
    static let shared = FolderUsageStore()

    enum Event { case opened, tabSwitch }

    private static let key = "usage.folders"
    private let settings = ViewSettings.shared
    private(set) var usage: FolderUsage
    /// Self-test: a shorter wait than the setting's whole seconds.
    var dwellOverride: Duration?
    /// Uses counted (self-test).
    private(set) var recorded = 0

    private init() {
        usage = settings.defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FolderUsage.self, from: $0) } ?? FolderUsage()
    }

    var dwell: Duration { dwellOverride ?? .seconds(settings.usageDwell) }

    func weight(_ event: Event) -> Double {
        switch event {
        case .opened: settings.usageOpenWeight.weight
        case .tabSwitch: settings.usageTabWeight.weight
        }
    }

    /// Whether `url` can be counted: a real folder (not the Trash view).
    static func isCountable(_ url: URL) -> Bool { url.isFileURL && !TrashService.shared.isTrash(url) }

    func record(_ url: URL, _ event: Event, at date: Date = .now) {
        let weight = weight(event)
        guard weight > 0, Self.isCountable(url) else { return }
        usage.record(Self.path(url), weight: weight, at: date)
        recorded += 1
        save()
    }

    /// The folders for the menu, best first (`ViewSettings.usageTopCount` of them).
    func top(at date: Date = .now) -> [URL] {
        usage.top(settings.usageTopCount, at: date).map { URL(filePath: $0.path, directoryHint: .isDirectory) }
    }

    func reset() {
        usage.removeAll()
        save()
    }

    static func path(_ url: URL) -> String { FolderUsage.key(url.standardizedFileURL.path(percentEncoded: false)) }

    private func save() {
        settings.defaults.set(try? JSONEncoder().encode(usage), forKey: Self.key)
        NotificationCenter.default.post(name: .folderUsageDidChange, object: self)
    }

    // MARK: Menu

    /// Fills `menu` with the most used folders; choosing one calls `action` on `target` (nil: the responder chain)
    /// with the folder's URL as `representedObject`.
    func fill(_ menu: NSMenu, target: AnyObject?, action: Selector) {
        menu.removeAllItems()
        let folders = top()
        if folders.isEmpty {
            let empty = menu.addItem(withTitle: "No Folders Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.toolTip = "Folders you keep open for a few seconds, or switch to in tabs, appear here."
        }
        let names = folders.map(Self.displayName)
        let icon = IconCache.shared.folderIcon
        for (url, name) in zip(folders, names) {
            let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = url
            item.image = icon
            // Where it is: always for a name that appears twice, otherwise as the tooltip.
            let location = Self.abbreviated(url.deletingLastPathComponent())
            if names.filter({ $0 == name }).count > 1 { item.subtitle = location }
            item.toolTip = url.path(percentEncoded: false)
            item.setAccessibilityLabel("\(name), in \(location)")
        }
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "Most Used Folders Settings…", action: #selector(AppDelegate.showMostUsedSettings(_:)), keyEquivalent: "")
        settingsItem.target = NSApp.delegate
    }

    static func displayName(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        if path == "/" { return "/" }
        if FolderUsage.key(path) == FolderUsage.key(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)) { return "Home" }
        return url.lastPathComponent
    }

    /// "~/Documents/Work" for paths in Home.
    static func abbreviated(_ url: URL) -> String {
        let path = FolderUsage.key(url.standardizedFileURL.path(percentEncoded: false))
        let home = FolderUsage.key(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Go ▸ Most Used Folders: built when it opens.
@MainActor
final class MostUsedMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        FolderUsageStore.shared.fill(menu, target: nil, action: #selector(MainWindowController.openMostUsed(_:)))
    }
}

/// One window's dwell timer: the folder shown in the selected tab counts once it has stayed there long enough.
@MainActor
final class FolderUsageTracker {
    private var watched: (list: ObjectIdentifier, path: String)?
    private var task: Task<Void, Never>?

    /// The selected tab (or its folder) may have changed. `current`: the list shown when the timer fires.
    func shown(_ list: FileListViewController, _ event: FolderUsageStore.Event,
               current: @escaping @MainActor () -> FileListViewController?) {
        let path = FolderUsageStore.path(list.folder)
        if let watched, watched.list == ObjectIdentifier(list), watched.path == path { return } // same tab, same folder
        watched = (ObjectIdentifier(list), path)
        task?.cancel()
        let store = FolderUsageStore.shared
        guard store.weight(event) > 0, FolderUsageStore.isCountable(list.folder) else { task = nil; return }
        let dwell = store.dwell
        task = Task { [weak list] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, let list, current() === list, FolderUsageStore.path(list.folder) == path,
                  list.state.error == nil else { return }
            store.record(list.folder, event)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        watched = nil
    }
}
