import AppKit
import FileSystemKit

extension Notification.Name {
    /// Favorites were pinned, unpinned, reordered or re-resolved.
    static let favoritesDidChange = Notification.Name("dev.kansio.favoritesDidChange")
}

/// Pinned folders (P1-2), shared by every window. Stored in the app's defaults (the same domain
/// as `ViewSettings`) as bookmark data, so a pinned folder that was renamed or moved is found
/// again. A folder that's gone (deleted, in the Trash, volume not mounted) stays pinned, dimmed.
///
/// All file-system work — making and resolving bookmarks, reading display names — happens off
/// the main thread; the list shows last-known paths immediately.
@MainActor
final class FavoritesStore {
    static let shared = FavoritesStore()

    private let defaults = ViewSettings.shared.defaults
    private static let key = "favorites.v1"
    private(set) var list: FavoriteList
    /// Entries whose folder couldn't be found at the last check.
    private(set) var missing: Set<UUID> = []
    private var resolveTask: Task<Void, Never>?
    private var resolveAgain = false
    /// Number of finished resolve passes (self-test waits on it).
    private(set) var resolvePasses = 0
    private var requested = 0
    private var covered = 0

    private init() {
        if let data = defaults.data(forKey: Self.key), let list = try? JSONDecoder().decode(FavoriteList.self, from: data) {
            self.list = list
        } else {
            list = Self.defaultList
        }
        // Moves and renames made by Kansio itself: check right away (others are found on activation).
        NotificationCenter.default.addObserver(forName: .kansioFilesChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveAll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveAll() }
        }
        resolveAll()
    }

    /// Desktop, Documents, Downloads, Applications (bookmarks are made in the background).
    static var defaultList: FavoriteList {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> String {
            (fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser).path(percentEncoded: false)
        }
        return FavoriteList([
            FavoriteEntry(path: dir(.desktopDirectory), title: "Desktop"),
            FavoriteEntry(path: dir(.documentDirectory), title: "Documents"),
            FavoriteEntry(path: dir(.downloadsDirectory), title: "Downloads"),
            FavoriteEntry(path: "/Applications", title: "Applications"),
        ])
    }

    var entries: [FavoriteEntry] { list.entries }

    func isPinned(_ url: URL) -> Bool { list.contains(path: url.path(percentEncoded: false)) }

    func entry(for url: URL) -> FavoriteEntry? {
        list.index(ofPath: url.path(percentEncoded: false)).map { list.entries[$0] }
    }

    // MARK: Changes

    /// Pins folders (non-folders are skipped) at `index` (end when nil). Calls back with how many
    /// were pinned and how many weren't folders.
    func pin(_ urls: [URL], at index: Int? = nil, completion: ((_ pinned: Int, _ notFolders: Int) -> Void)? = nil) {
        Task {
            let prepared: [(URL, Data?, String)?] = await Self.offMain {
                urls.map { url in
                    var isDirectory: ObjCBool = false
                    let path = url.path(percentEncoded: false)
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                    return (url, Bookmarks.make(url), FileManager.default.displayName(atPath: path))
                }
            }
            var position = index
            var pinned = 0
            for case let (url, bookmark, title)? in prepared {
                if list.pin(FavoriteEntry(path: url.path(percentEncoded: false), bookmark: bookmark, title: title), at: position) {
                    pinned += 1
                    position = position.map { $0 + 1 }
                }
            }
            if pinned > 0 { save() }
            completion?(pinned, prepared.filter { $0 == nil }.count)
        }
    }

    func unpin(_ id: UUID) {
        list.unpin(id)
        missing.remove(id)
        save()
    }

    /// `to`: the drop index (before the entry currently there; `count` = last).
    func move(from: Int, to: Int) {
        let before = list
        list.move(from: from, to: to)
        if list != before { save() }
    }

    func restoreDefaults() {
        list = Self.defaultList
        missing = []
        save()
        resolveAll()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
        NotificationCenter.default.post(name: .favoritesDidChange, object: self)
    }

    // MARK: Resolving (off-main)

    /// Re-checks where every pinned folder is now (renamed/moved/missing). Coalesced: a request while
    /// one is running starts one more pass afterwards.
    func resolveAll() {
        requested += 1
        guard resolveTask == nil else { resolveAgain = true; return }
        let entries = list.entries
        let request = requested
        resolveTask = Task {
            let results: [(UUID, Result)] = await Self.offMain {
                entries.map { ($0.id, Self.resolve($0)) }
            }
            if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
                print("favorites resolved: \(results.map { r in "\(entries.first { $0.id == r.0 }?.title ?? "?") → \(r.1)" })")
            }
            apply(results)
            resolveTask = nil
            resolvePasses += 1
            covered = request
            if resolveAgain {
                resolveAgain = false
                resolveAll()
            }
        }
    }

    /// Resolves everything and returns once a pass that started after this call has finished.
    func resolveNow() async {
        resolveAll()
        let target = requested
        while covered < target { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private enum Result: Sendable {
        case found(path: String, title: String, bookmark: Data?)
        case missing
    }

    /// One entry (blocking). Without a bookmark yet (defaults, older data): check the path and make one.
    nonisolated private static func resolve(_ entry: FavoriteEntry) -> Result {
        if let bookmark = entry.bookmark {
            switch Bookmarks.resolve(bookmark) {
            case .found(let url, let refreshed):
                // Not moved (same folder through a symlink such as /var → /private/var): keep the path it was
                // pinned under, so it still matches the folder the list shows.
                let resolved = url.path(percentEncoded: false)
                let path = FolderTreeIO.realPath(entry.path) == FolderTreeIO.realPath(resolved) ? entry.path : resolved
                return .found(path: path, title: FileManager.default.displayName(atPath: path), bookmark: refreshed)
            case .missing:
                return .missing
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        return .found(path: entry.path, title: FileManager.default.displayName(atPath: entry.path), bookmark: Bookmarks.make(entry.url))
    }

    private func apply(_ results: [(UUID, Result)]) {
        let before = (list, missing)
        for (id, result) in results {
            switch result {
            case .found(let path, let title, let bookmark):
                list.update(id, path: path, title: title, bookmark: bookmark)
                missing.remove(id)
            case .missing:
                missing.insert(id)
            }
        }
        if before.0 != list {
            save()
        } else if before.1 != missing {
            NotificationCenter.default.post(name: .favoritesDidChange, object: self)
        }
    }

    /// Blocking work on a utility queue (bookmark resolution can stall on a network volume; never
    /// mounts one). Not the listing queue: favorites must never delay a folder listing.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
