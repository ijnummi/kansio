import AppKit
import FileSystemKit

/// P1-5: search in the folder on screen and its subfolders (no Spotlight).
///
/// Each keystroke filters this folder's items at once (off-main, on names folded once per folder
/// — `FolderSearch.Index`); after a short pause the subfolders are searched too and their matches
/// stream in, shown with where they are. Live updates pause while searching (results come from
/// many folders) and catch up from FSEvents when the search ends. Esc or navigating ends it.
extension FileListViewController {
    @MainActor
    final class SearchState {
        var query = ""
        var words: [[UInt8]] = []
        /// This folder's matches and the subfolder matches so far.
        var topMatches: [FileItem] = []
        var deepMatches: [FileItem] = []
        var walkCancel: CancellationFlag?
        var walkDone = false
        var task: Task<Void, Never>?
        var index: SearchIndex?
        /// FSEvents id when live updates paused.
        var pausedSince: UInt64?
        /// Results applied (self-test / measurement).
        var version = 0
        var folders = 0
    }

    /// Folded names of this folder's rows in display order (so matches need no sorting), built once per
    /// folder version + sort + hidden setting.
    struct SearchIndex: Sendable {
        let key: String
        let index: FolderSearch.Index
        let ordered: [FileItem]
    }

    private var searchIndexKey: String { "\(contentsVersion) \(settings.sort.field.rawValue) \(settings.sort.ascending) \(settings.showHidden)" }

    /// Builds the index ahead of the first keystroke (the search field got focus).
    func prepareSearchIndex() {
        let key = searchIndexKey
        guard preparedSearchIndex?.key != key, !isLoading else { return }
        let contents = self.contents, sort = settings.sort, hidden = settings.showHidden
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { Self.buildIndex(contents, sort: sort, hidden: hidden, key: key) }.value
            self?.preparedSearchIndex = built
        }
    }

    nonisolated private static func buildIndex(_ contents: FolderContents, sort: FileSort, hidden: Bool, key: String) -> SearchIndex {
        let ordered = contents.ordered(by: sort, includeHidden: hidden)
        return SearchIndex(key: key, index: FolderSearch.Index(names: ordered.map(\.name)), ordered: ordered)
    }

    var isSearching: Bool { search != nil }
    var searchQuery: String { search?.query ?? "" }
    var searchIsComplete: Bool { search?.walkDone ?? true }
    var searchResultsVersion: Int { search?.version ?? 0 }

    /// The text in the search field changed (empty ends the search).
    func setSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        if isShowingTrash { filterTrash(query); return } // the Trash: filter its items by name
        guard !query.isEmpty else { endSearch(); return }
        let state: SearchState
        if let search {
            state = search
        } else {
            state = SearchState()
            search = state
            stopFolderSizes() // results come from many folders
            // Results come from many folders: live updates of this one pause, then catch up (P1-3 replay).
            state.pausedSince = FolderWatcher.currentEventID
            watcher?.stop()
            watcher = nil
            endRename(commit: false)
        }
        guard query != state.query else { return }
        state.query = query
        state.words = FolderSearch.words(query)
        state.walkCancel?.cancel()
        state.task?.cancel()
        state.walkDone = false
        state.deepMatches = []
        let words = state.words
        let contents = self.contents
        let key = searchIndexKey
        let cached = [state.index, preparedSearchIndex].compactMap { $0 }.first { $0.key == key }
        let sort = settings.sort
        let hidden = settings.showHidden
        let root = folder
        state.task = Task { [weak self] in
            // 1. This folder, at once.
            let (index, matches) = await Task.detached(priority: .userInitiated) { () -> (SearchIndex, [FileItem]) in
                let built = cached ?? Self.buildIndex(contents, sort: sort, hidden: hidden, key: key)
                return (built, built.index.matching(words).map { built.ordered[$0] }) // already in display order
            }.value
            guard let self, !Task.isCancelled, self.search === state else { return }
            state.index = index
            state.topMatches = matches
            self.showSearchResults(state)
            // 2. Subfolders, after a pause (typing on cancels this).
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.search === state else { return }
            let cancel = CancellationFlag()
            state.walkCancel = cancel
            let walkQuery = query
            let stream = AsyncStream<[FileItem]> { continuation in
                FolderSearchQueue.queue.async {
                    let result = FolderSearch.searchSubfolders(of: root, query: walkQuery, includeHidden: hidden, cancel: cancel) { batch in
                        continuation.yield(batch)
                    }
                    Task { @MainActor in state.folders = result.folders }
                    continuation.finish()
                }
            }
            for await batch in stream {
                guard !Task.isCancelled, self.search === state else { break }
                state.deepMatches += batch
                self.showSearchResults(state)
            }
            guard !Task.isCancelled, self.search === state else { return }
            state.walkDone = true
            self.showSearchResults(state)
        }
        updateStatusBar()
    }

    /// Orders this folder's and the subfolders' matches (off-main) and shows them.
    private func showSearchResults(_ state: SearchState) {
        if state.deepMatches.isEmpty { // this folder's matches are in display order already
            state.version += 1
            setRows(state.topMatches, scrollToTop: state.version == 1, isComplete: true)
            updateStatusBar()
            return
        }
        let items = state.topMatches + state.deepMatches
        let sort = settings.sort
        Task { [weak self] in
            let ordered = await Task.detached(priority: .userInitiated) {
                FolderContents(items: items).ordered(by: sort, includeHidden: true)
            }.value
            guard let self, self.search === state, state.topMatches.count + state.deepMatches.count == items.count else { return }
            state.version += 1
            self.setRows(ordered, scrollToTop: state.version == 1, isComplete: true)
            self.updateStatusBar()
        }
    }

    /// Esc, an empty field, or navigating: back to the folder (and its live updates).
    func endSearch() {
        if isShowingTrash { filterTrash("") }
        guard let state = search else { return }
        state.walkCancel?.cancel()
        state.task?.cancel()
        search = nil
        onSearchEnded?()
        guard isViewLoaded else { return }
        resort() // the folder's own rows again
        if isActive { startWatching(folder, generation: generation, since: state.pausedSince) }
        startFolderSizes()
        updateStatusBar()
    }

    /// A local change (rename, trash, paste…) while searching: search again so the results match.
    func refreshSearchAfterChange() {
        guard let state = search else { return }
        let query = state.query
        state.query = ""
        setSearch(query)
    }
}

/// Subfolder walks run here, not on the listing queue (a search must never delay opening a folder).
enum FolderSearchQueue {
    static let queue = DispatchQueue(label: "kansio.search", qos: .userInitiated)
}
