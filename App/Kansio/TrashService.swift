import AppKit
import FileSystemKit

/// P2-1: the one place that moves things to the Trash, deletes them for good, and knows where the Trash folders are.
///
/// Every Move to Trash goes through `trasher`: it records each item in Kansio's trash history (so the Trash view
/// can show and restore where it came from) and handles network volumes, which have no Trash — by default the
/// user is asked and those items are deleted immediately (like Finder); with Settings ▸ Trash ▸ "Keep a Trash
/// folder on network volumes" they go to the volume's own `.Trashes/<uid>` instead.
@MainActor
final class TrashService {
    static let shared = TrashService()

    let history: TrashHistory
    let trasher: any Trasher
    private let volumeAware: VolumeAwareTrasher
    /// KANSIO_TEST_TRASH: the self-test's Trash folder (never the user's Trash).
    let testTrash: URL?
    /// KANSIO_TEST_NETWORK: the self-test's "network volume" (a folder in the fixtures).
    let testNetworkRoot: URL?
    /// Self-test: answers the "delete immediately?" confirmations instead of showing them (and records the question).
    var confirmForTesting: ((String) -> Bool)?
    private let settings = ViewSettings.shared

    private init() {
        let env = ProcessInfo.processInfo.environment
        testTrash = env["KANSIO_TEST_TRASH"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let networkRoot = env["KANSIO_TEST_NETWORK"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        testNetworkRoot = networkRoot
        let base: any Trasher = testTrash.map { DirectoryTrasher(directory: $0) } ?? SystemTrasher()
        let detect: @Sendable (URL) -> URL? = if let networkRoot {
            { url in
                let root = networkRoot.path(percentEncoded: false)
                return url.path(percentEncoded: false).hasPrefix(root.hasSuffix("/") ? root : root + "/") ? networkRoot : nil
            }
        } else {
            VolumeAwareTrasher.systemNetworkRoot
        }
        volumeAware = VolumeAwareTrasher(base, useVolumeFolders: settings.networkTrashFolders, networkRoot: detect)
        history = TrashHistory(file: Self.historyFile(suite: env["KANSIO_DEFAULTS_SUITE"]))
        trasher = RecordingTrasher(volumeAware, history: history)
        NotificationCenter.default.addObserver(forName: .viewSettingsDidChange, object: nil, queue: nil) { [weak self] note in
            guard note.userInfo?["key"] as? String == ViewSettings.Key.networkTrashFolders.rawValue else { return }
            MainActor.assumeIsolated { self?.volumeAware.usesVolumeFolders = ViewSettings.shared.networkTrashFolders }
        }
    }

    // MARK: The Trash location

    /// What the Trash view shows at: `~/.Trash` (the self-test: its test Trash folder). Navigating there — the sidebar's
    /// Trash row, history, typing the path — shows every Trash folder together.
    var trashURL: URL { testTrash ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: ".Trash", directoryHint: .isDirectory) }

    private lazy var trashPaths: Set<String> = {
        let path = trashURL.path(percentEncoded: false)
        var paths: Set<String> = [FolderTreeIO.normalizedPath(path)]
        if let real = realpath(path, nil) { paths.insert(FolderTreeIO.normalizedPath(String(cString: real))); free(real) }
        return paths
    }()

    /// True for the Trash location (string comparison only: called on every navigation).
    func isTrash(_ url: URL) -> Bool { trashPaths.contains(FolderTreeIO.normalizedPath(url.path(percentEncoded: false))) }

    /// "Trash" for the Trash location, else the folder's name ("/" for the root).
    static func title(for url: URL) -> String {
        if shared.isTrash(url) { return "Trash" }
        let path = url.path(percentEncoded: false)
        return path == "/" ? "/" : url.lastPathComponent
    }

    /// The Trash folders the Trash view shows: `~/.Trash` and every mounted volume's `.Trashes/<uid>` (network
    /// volumes' only with the setting on). The self-test: its test Trash folder and its "network volume"'s.
    func folders() async -> [TrashFolder] {
        let includeNetwork = settings.networkTrashFolders
        if let testTrash {
            let root = testTrash.deletingLastPathComponent()
            var folders = [TrashFolder(url: testTrash, volumeRoot: root)]
            if let share = testNetworkRoot {
                let trash = TrashFolders.volumeTrash(root: share)
                if FileManager.default.fileExists(atPath: trash.path(percentEncoded: false)) {
                    folders.append(TrashFolder(url: trash, volumeRoot: share, isNetwork: true))
                }
            }
            return folders
        }
        let volumes = await VolumeList.mountedVolumes()
        return await Task.detached(priority: .userInitiated) {
            TrashFolders.discoverBlocking(volumes: volumes, includeNetwork: includeNetwork)
        }.value
    }

    // MARK: Empty Trash, Delete Immediately

    /// Empty Trash (⇧⌘⌫): asks, then permanently deletes everything in every Trash folder. Nil: cancelled.
    func emptyTrash(window: NSWindow?) async -> TrashActions.DeleteOutcome? {
        let folders = await folders()
        guard await confirmDelete([], volume: nil, window: window, emptying: true) else { return nil }
        let outcome = await TrashActions.empty(folders)
        await forgetDeleted()
        NotificationCenter.default.post(name: .kansioFilesChanged, object: nil, userInfo: ["urls": outcome.deleted])
        return outcome
    }

    /// Delete Immediately in the Trash view: asks, then permanently deletes `urls` (which must be in a Trash folder).
    func deleteImmediately(_ urls: [URL], window: NSWindow?) async -> TrashActions.DeleteOutcome? {
        guard !urls.isEmpty, await confirmDelete(urls, volume: nil, window: window) else { return nil }
        let outcome = await TrashActions.deletePermanently(urls, within: await folders().map(\.url))
        await forgetDeleted()
        NotificationCenter.default.post(name: .kansioFilesChanged, object: nil, userInfo: ["urls": outcome.deleted])
        return outcome
    }

    /// Drops history records of items that are gone now.
    private func forgetDeleted() async {
        let history = self.history
        await Task.detached(priority: .utility) {
            history.prune(olderThan: -1) { FileManager.default.fileExists(atPath: $0) }
        }.value
    }

    /// `~/Library/Application Support/Kansio/TrashHistory.json` (another name per test settings domain).
    static func historyFile(suite: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "Kansio", directoryHint: .isDirectory)
            .appending(path: suite.map { "TrashHistory-\($0).json" } ?? "TrashHistory.json")
    }

    // MARK: Move to Trash

    struct Outcome {
        var trashed: [(original: URL, inTrash: URL)] = []
        /// Deleted immediately (network volume, confirmed).
        var deleted: [URL] = []
        var failed: [(url: URL, error: FileSystemError)] = []
        /// Of `failed`: the ones that were being deleted immediately (not moved to the Trash).
        var deleteFailed: Set<URL> = []
        /// The user cancelled the "delete immediately?" question: nothing was done.
        var cancelled = false
    }

    /// Moves `urls` to the Trash. Items on a network volume without a Trash folder are deleted immediately after the
    /// user confirms (a sheet on `window`); cancelling leaves everything as it was.
    func moveToTrash(_ urls: [URL], window: NSWindow?) async -> Outcome {
        let volumeAware = self.volumeAware
        let useFolders = volumeAware.usesVolumeFolders
        // Which items are on a network volume (blocking resource lookups: off the main thread).
        let network: [(url: URL, root: URL)] = useFolders ? [] : await Task.detached(priority: .userInitiated) {
            urls.compactMap { url in volumeAware.networkRoot(url).map { (url, $0) } }
        }.value
        var outcome = Outcome()
        if !network.isEmpty {
            guard await confirmDelete(network.map(\.url), volume: network[0].root, window: window) else {
                outcome.cancelled = true
                return outcome
            }
            let roots = Array(Set(network.map(\.root)))
            let result = await TrashActions.deletePermanently(network.map(\.url), within: roots)
            outcome.deleted = result.deleted
            outcome.failed = result.failed
            outcome.deleteFailed = Set(result.failed.map(\.url))
        }
        let networkURLs = Set(network.map(\.url))
        let toTrash = urls.filter { !networkURLs.contains($0) }
        if !toTrash.isEmpty {
            let trashed = await FileOperations.trash(toTrash, using: trasher)
            outcome.trashed = trashed.trashed
            outcome.failed += trashed.failed
        }
        return outcome
    }

    /// "Delete “x” immediately?" — the only question before anything is deleted for good. Cancel is the default button.
    func confirmDelete(_ urls: [URL], volume: URL?, window: NSWindow?, emptying: Bool = false) async -> Bool {
        let message: String
        if emptying {
            message = "Are you sure you want to permanently erase the items in the Trash?"
        } else if urls.count == 1, let url = urls.first {
            message = "Delete “\(url.lastPathComponent)” immediately?"
        } else {
            message = "Delete \(urls.count) items immediately?"
        }
        if let confirmForTesting { return confirmForTesting(message) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if emptying {
            alert.informativeText = "You can’t undo this action."
        } else if let volume {
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volume.lastPathComponent
            alert.informativeText = "“\(name)” is a network volume and has no Trash. You can’t undo this action.\n\n"
                + "Settings ▸ Trash can keep a Trash folder on network volumes instead."
        } else {
            alert.informativeText = "You can’t undo this action."
        }
        let delete = alert.addButton(withTitle: emptying ? "Empty Trash" : "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}
