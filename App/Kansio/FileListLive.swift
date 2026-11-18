import AppKit
import FileSystemKit

/// M13: live updates for the folder on screen (changes by other apps, Terminal, sync clients…).
///
/// FSEvents reports the names that changed; just those are re-read (off-main, one getattrlist
/// each) and applied as a small model change — the list is never re-listed per event, selection
/// and scroll position stay. Huge batches or "events were dropped" → one re-list and a diff.
extension FileListViewController {

    /// `since`: replay what changed after that FSEvents id first (a background tab coming back).
    func startWatching(_ url: URL, generation gen: Int, since: UInt64? = nil) {
        watcher?.stop()
        guard !ArchiveBrowser.isInsideArchive(url) else { watcher = nil; return } // a browsed archive isn't a folder on disk
        if since == nil {
            pendingLiveNames = []
            pendingRescan = false
        }
        let watcher = FolderWatcher(folder: url) { [weak self] event in
            Task { @MainActor in self?.liveEvent(event, generation: gen) }
        }
        watcher.start(since: since)
        self.watcher = watcher
    }

    private func liveEvent(_ event: FolderWatcher.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .changed(let names):
            pendingLiveNames.formUnion(names)
        case .rescan:
            pendingRescan = true
        case .folderGone:
            folderWentAway()
            return
        }
        processLiveChanges()
    }

    /// Applies pending changes, one batch at a time (more events meanwhile → another batch).
    func processLiveChanges() {
        guard !liveInFlight, !isLoading, hasLoadedOnce, !pendingLiveNames.isEmpty || pendingRescan else { return }
        let names = pendingLiveNames
        let relist = pendingRescan || names.count > LiveChanges.relistThreshold
        pendingLiveNames = []
        pendingRescan = false
        liveInFlight = true
        let directory = folder
        let previous = contents
        let gen = generation
        let sort = ViewSettings.shared.sort, hidden = ViewSettings.shared.showHidden
        let sizes = folderSizes
        Task.detached(priority: .userInitiated) { [weak self] in
            let changes: (removed: Set<String>, updated: [FileItem])
            var replacement: FolderContents?
            if relist, let items = try? BulkDirectoryLister().listAll(directory) {
                changes = LiveChanges.diff(old: previous.items, new: items)
                // Most of the folder changed: ranking from scratch beats many inserts.
                if changes.removed.count + changes.updated.count > previous.items.count / 4 {
                    replacement = FolderContents(items: SymlinkResolver.resolved(items, in: directory))
                }
            } else {
                changes = LiveChanges.readChanges(names, in: directory)
            }
            let renames = LiveChanges.renames(removed: changes.removed, updated: changes.updated, previous: previous)
            let updated = replacement ?? previous.applying(removing: changes.removed, adding: changes.updated)
            let ordered = updated.ordered(by: sort, includeHidden: hidden, folderSizes: sizes)
            FileKind.prewarm(changes.updated)
            await self?.finishLive(updated, ordered: ordered, renames: renames, relisted: relist, generation: gen)
        }
    }

    private func finishLive(_ updated: FolderContents, ordered: [FileItem], renames: [String: String], relisted: Bool, generation gen: Int) {
        liveInFlight = false
        guard gen == generation else { return }
        // Keep the selection — following items that were renamed by someone else.
        let keep = selectedNames.map { renames[$0] ?? $0 }
        releaseOffMain(contents)
        contents = updated
        contentsVersion += 1
        pendingSelection = keep
        setRows(ordered, scrollToTop: false, isComplete: !isLoading)
        applyPendingSelection(final: true)
        liveBatchesApplied += 1
        if relisted { liveRelists += 1 }
        folderSizesModelChanged()
        processLiveChanges() // anything that arrived meanwhile
    }

    /// The folder on screen was moved or deleted: go to the nearest folder that still exists
    /// (Explorer) and say why, inline.
    private func folderWentAway() {
        let gone = folder
        Task { [weak self] in
            let target = await Task.detached { () -> URL in
                var candidate = gone
                while let up = parentLocation(of: candidate)?.parent {
                    if access(up.path(percentEncoded: false), F_OK) == 0 { return up }
                    candidate = up
                }
                return URL(filePath: "/", directoryHint: .isDirectory)
            }.value
            guard let self, self.folder == gone else { return }
            // Maybe it was only touched, not removed (e.g. replaced atomically): reload in place.
            if access(gone.path(percentEncoded: false), F_OK) == 0 {
                self.pendingRescan = true
                self.processLiveChanges()
                return
            }
            self.navigate(to: target)
            self.showMessage("“\(gone.lastPathComponent)” was moved or deleted.")
        }
    }
}
