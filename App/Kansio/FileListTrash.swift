import AppKit
import FileSystemKit

/// P2-1: the Trash view (Explorer's Recycle Bin). Navigating to the Trash location (`TrashService.trashURL`) shows
/// every Trash folder together — `~/.Trash` and each volume's `.Trashes/<uid>` — with Original Location and Date
/// Deleted columns, Put Back, Delete Immediately and Empty Trash.
///
/// Rows are ordinary `FileItem`s named by their absolute path without the leading "/" (the view's folder prefix is
/// "/"), so opening, Quick Look, Get Info, copying and dragging work unchanged. Adding to the Trash view (paste, new
/// folder, drops, rename) is off. Trash folders are small and change as a whole (Empty Trash), so a change re-lists
/// them (coalesced) instead of diffing names.
extension FileListViewController {
    @MainActor
    final class TrashState {
        var folders: [TrashFolder] = []
        var entries: [TrashEntry] = []
        var byName: [String: TrashEntry] = [:]
        /// Sorting by one of the Trash columns (nil: the global sort, like any folder).
        var sortKey: TrashSortKey?
        var ascending = false
        /// The search field filters the Trash by name.
        var filter = ""
        var watchers: [FolderWatcher] = []
        var relistTask: Task<Void, Never>?
        /// Lists applied (self-test).
        var version = 0
    }

    static let trashOriginalColumn = NSUserInterfaceItemIdentifier(TrashSortKey.originalLocation.rawValue)
    static let trashDeletedColumn = NSUserInterfaceItemIdentifier(TrashSortKey.dateDeleted.rawValue)

    var isShowingTrash: Bool { trash != nil }
    var trashVersion: Int { trash?.version ?? 0 }
    func trashEntry(_ item: FileItem) -> TrashEntry? { trash?.byName[item.name] }

    /// `load` reached the Trash location: list all Trash folders (`load` already reset the view for a navigation).
    func loadTrash(generation gen: Int) -> Task<Void, Never> {
        let state: TrashState
        if let trash { state = trash } else {
            state = TrashState()
            trash = state
            addTrashColumns()
        }
        folderPrefix = "/"
        return listTrash(state, generation: gen, scrollToTop: true)
    }

    /// Lists every Trash folder off the main thread and shows the result (also after changes: `scrollToTop` false
    /// keeps the selection and scroll position).
    @discardableResult
    func listTrash(_ state: TrashState, generation gen: Int, scrollToTop: Bool) -> Task<Void, Never> {
        state.relistTask?.cancel()
        let service = TrashService.shared
        let history = service.history
        let task = Task { [weak self] in
            let folders = await service.folders()
            let (entries, errors) = await Task.detached(priority: .userInitiated) {
                TrashListing.listBlocking(folders, history: history)
            }.value
            guard let self, !Task.isCancelled, gen == self.generation, self.trash === state else { return }
            state.folders = folders
            state.entries = entries
            state.byName = Dictionary(entries.map { ($0.item.name, $0) }, uniquingKeysWith: { a, _ in a })
            state.version += 1
            if self.isActive { self.watchTrash(state, generation: gen) }
            if entries.isEmpty, let error = errors.first {
                self.applyError(error, generation: gen) // e.g. ~/.Trash refused without Full Disk Access: Grant Access…
                return
            }
            let ordered = await Self.orderTrash(state, sort: self.settings.sort, hidden: self.settings.showHidden)
            guard gen == self.generation, self.trash === state else { return }
            let contents = await Task.detached(priority: .userInitiated) { FolderContents(items: entries.map(\.item)) }.value
            guard gen == self.generation, self.trash === state else { return }
            self.applyLoaded(ListingUpdate(contents: contents, isComplete: true), ordered: ordered,
                             sort: self.settings.sort, hidden: self.settings.showHidden, generation: gen, scrollToTop: scrollToTop)
            if let error = errors.first { self.showMessage("Some of the Trash couldn’t be read: \(error.description)") }
        }
        state.relistTask = task
        return task
    }

    /// The rows in display order (off the main thread).
    static func orderTrash(_ state: TrashState, sort: FileSort, hidden: Bool) async -> [FileItem] {
        let entries = state.entries, key = state.sortKey, ascending = state.ascending, filter = state.filter
        return await Task.detached(priority: .userInitiated) {
            let shown = filter.isEmpty ? entries : entries.filter { $0.displayName.localizedStandardContains(filter) }
            return TrashListing.ordered(shown, sort: sort, key: key, ascending: ascending, includeHidden: hidden).map(\.item)
        }.value
    }

    /// Re-orders (sort or filter changed) without re-listing.
    func resortTrash(_ state: TrashState) {
        let gen = generation, version = state.version
        Task { [weak self] in
            guard let self else { return }
            let ordered = await Self.orderTrash(state, sort: self.settings.sort, hidden: self.settings.showHidden)
            guard gen == self.generation, self.trash === state, version == state.version else { return }
            self.setRows(ordered, scrollToTop: false, isComplete: true)
        }
    }

    /// Re-lists soon (several changes in a row → one listing).
    func scheduleTrashRelist() {
        guard let state = trash else { return }
        let gen = generation
        state.relistTask?.cancel()
        state.relistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, gen == self.generation, self.trash === state else { return }
            self.listTrash(state, generation: gen, scrollToTop: false)
        }
    }

    private func watchTrash(_ state: TrashState, generation gen: Int) {
        let urls = state.folders.map(\.url)
        guard state.watchers.map(\.folder) != urls else { return }
        state.watchers.forEach { $0.stop() }
        state.watchers = urls.map { url in
            let watcher = FolderWatcher(folder: url) { [weak self] _ in
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.scheduleTrashRelist()
                }
            }
            watcher.start()
            return watcher
        }
    }

    func stopWatchingTrash() {
        trash?.watchers.forEach { $0.stop() }
        trash?.watchers = []
    }

    /// Left the Trash location (or the view closed).
    func endTrash() {
        guard let state = trash else { return }
        state.relistTask?.cancel()
        state.watchers.forEach { $0.stop() }
        trash = nil
        removeTrashColumns()
        let descriptor = NSSortDescriptor(key: settings.sort.field.rawValue, ascending: settings.sort.ascending)
        if tableView.sortDescriptors.first?.key != descriptor.key { tableView.sortDescriptors = [descriptor] }
    }

    /// The search field in the Trash: filter by name.
    func filterTrash(_ query: String) {
        guard let state = trash, state.filter != query else { return }
        state.filter = query
        resortTrash(state)
    }

    // MARK: Columns

    /// Original Location and Date Deleted, right after Name (only while the Trash is shown; not part of the global layout).
    func addTrashColumns() {
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        for (id, title, width, ascending) in [(Self.trashOriginalColumn, "Original Location", 260.0, true),
                                              (Self.trashDeletedColumn, "Date Deleted", 150.0, false)]
        where tableView.column(withIdentifier: id) < 0 {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = 80
            column.maxWidth = 4000
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascending)
            tableView.addTableColumn(column)
        }
        placeTrashColumns()
    }

    /// Keeps the Trash columns right after Name (after the global layout was applied).
    func placeTrashColumns() {
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        let name = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileSort.Field.name.rawValue))
        for (offset, id) in [Self.trashOriginalColumn, Self.trashDeletedColumn].enumerated() {
            let index = tableView.column(withIdentifier: id)
            if index >= 0, index != name + 1 + offset { tableView.moveColumn(index, toColumn: name + 1 + offset) }
        }
    }

    func removeTrashColumns() {
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        for id in [Self.trashOriginalColumn, Self.trashDeletedColumn] {
            if let column = tableView.tableColumns.first(where: { $0.identifier == id }) { tableView.removeTableColumn(column) }
        }
    }

    /// The Trash columns' text.
    func trashColumnText(_ column: NSUserInterfaceItemIdentifier, item: FileItem) -> String? {
        switch column {
        case Self.trashOriginalColumn:
            guard let folder = trashEntry(item)?.originalFolder else { return "" }
            return (folder as NSString).abbreviatingWithTildeInPath
        case Self.trashDeletedColumn:
            return trashEntry(item)?.dateDeleted.map { Formatters.date.string(from: $0) } ?? ""
        default:
            return nil
        }
    }

    /// A Trash column header was clicked (true) — or a regular one, which goes back to the global sort.
    func trashSortChanged(_ descriptor: NSSortDescriptor) -> Bool {
        guard let state = trash else { return false }
        guard let key = descriptor.key.flatMap(TrashSortKey.init(rawValue:)) else {
            if state.sortKey != nil {
                state.sortKey = nil
                resortTrash(state)
            }
            return false
        }
        state.sortKey = key
        state.ascending = descriptor.ascending
        resortTrash(state)
        return true
    }

    // MARK: Put Back

    /// Moves the selected items back where they came from (recreating the folder if needed). An item already there is
    /// asked about (Replace — the existing one goes to the Trash — / Keep Both / Skip); undoable.
    @objc func putBack(_ sender: Any?) {
        guard let state = trash else { return }
        let entries = selectedItems.compactMap { state.byName[$0.name] }
        guard !entries.isEmpty else { NSSound.beep(); return }
        let trasher = self.trasher
        let gen = generation
        Task { [weak self] in
            var changes: [FileChange] = []
            var problems: [String] = []
            var placed: [URL] = []
            items: for entry in entries {
                guard let original = entry.original else {
                    problems.append("Kansio doesn’t know where “\(entry.displayName)” came from")
                    continue
                }
                let source = URL(filePath: entry.path)
                var target = URL(filePath: original)
                if await Self.exists(target) {
                    guard let self else { return }
                    switch await self.askPutBackConflict(target) {
                    case .skip: continue
                    case .stop: break items
                    case .keepBoth:
                        target = await Self.freeName(for: target)
                    case .replace:
                        let outcome = await FileOperations.trash([target], using: trasher)
                        guard let moved = outcome.trashed.first else {
                            problems.append("“\(target.lastPathComponent)” couldn’t be moved to the Trash: \(outcome.failed.first?.error.description ?? "")")
                            continue
                        }
                        changes.append(.trashed(original: moved.original, slot: TrashSlot(moved.inTrash)))
                    }
                }
                if let error = await TrashActions.putBack(source, to: target) {
                    problems.append("“\(entry.displayName)” couldn’t be put back: \(error.description)")
                } else {
                    changes.append(.moved(from: source, to: target))
                    placed.append(target)
                }
            }
            guard let self else { return }
            FileUndo.shared.register(UndoStep("Put Back", changes), trasher: trasher)
            self.announce(placed + entries.map { URL(filePath: $0.path) })
            if gen == self.generation { self.scheduleTrashRelist() }
            if let first = problems.first {
                self.showMessage(first + (problems.count > 1 ? " (and \(problems.count - 1) more)." : "."))
            }
        }
    }

    enum PutBackAnswer { case replace, keepBoth, skip, stop }

    /// Self-test: answers Put Back's "already exists" question instead of showing it.
    static var putBackAnswerForTesting: PutBackAnswer?

    private func askPutBackConflict(_ target: URL) async -> PutBackAnswer {
        if let answer = Self.putBackAnswerForTesting { return answer }
        guard let window = view.window else { return .skip }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(target.lastPathComponent)” already exists in “\(target.deletingLastPathComponent().lastPathComponent)”."
        alert.informativeText = "Replace moves the existing item to the Trash. Keep Both puts this one back under a new name."
        let answers: [(String, PutBackAnswer)] = [("Keep Both", .keepBoth), ("Replace", .replace), ("Skip", .skip), ("Stop", .stop)]
        for (title, _) in answers { alert.addButton(withTitle: title) }
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let response = await alert.beginSheetModal(for: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) ? answers[index].1 : .stop
    }

    nonisolated private static func exists(_ url: URL) async -> Bool {
        let path = url.path(percentEncoded: false)
        return await Task.detached { var st = stat(); return lstat(path, &st) == 0 }.value
    }

    /// "name (2).ext", "name (3).ext"… — the first that isn't taken.
    nonisolated private static func freeName(for url: URL) async -> URL {
        await Task.detached {
            let folder = url.deletingLastPathComponent(), name = url.lastPathComponent
            for n in 2...10_000 {
                let candidate = folder.appending(path: FileNames.numbered(name, n))
                var st = stat()
                if lstat(candidate.path(percentEncoded: false), &st) != 0 { return candidate }
            }
            return url
        }.value
    }

    // MARK: Delete Immediately, Empty Trash

    /// Del / ⌘⌫ in the Trash: deletes the selection for good, after asking.
    @objc func deleteImmediately(_ sender: Any?) {
        guard isShowingTrash else { return }
        let urls = selectedItems.map(url(of:))
        guard !urls.isEmpty else { NSSound.beep(); return }
        Task { [weak self] in
            guard let outcome = await TrashService.shared.deleteImmediately(urls, window: self?.view.window), let self else { return }
            self.scheduleTrashRelist()
            if let first = outcome.failed.first {
                let more = outcome.failed.count > 1 ? " (and \(outcome.failed.count - 1) more)" : ""
                self.showMessage("Couldn’t delete “\(first.url.lastPathComponent)”\(more): \(first.error.description)")
            }
        }
    }

    /// File ▸ Empty Trash… (⇧⌘⌫), and the Trash view's context menu.
    @objc func emptyTrash(_ sender: Any?) {
        Task { [weak self] in
            guard let outcome = await TrashService.shared.emptyTrash(window: self?.view.window), let self else { return }
            if self.isShowingTrash { self.scheduleTrashRelist() }
            if let first = outcome.failed.first {
                let more = outcome.failed.count > 1 ? " (and \(outcome.failed.count - 1) more)" : ""
                self.showMessage("Couldn’t delete “\(first.url.lastPathComponent)”\(more): \(first.error.description)")
            }
        }
    }

    /// The Trash view's right-click menu.
    func trashContextMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mods
            menuItem.target = self
            return menuItem
        }
        let empty = item("Empty Trash…", #selector(emptyTrash(_:)), "\u{8}", [.command, .shift])
        guard !selectedItems.isEmpty else { return [empty] }
        return [item("Open", #selector(openSelectionAction(_:)), "o"), item("Quick Look", #selector(toggleQuickLook(_:)), "y"), .separator(),
                item("Put Back", #selector(putBack(_:))), item("Delete Immediately…", #selector(deleteImmediately(_:)), "\u{8}"), .separator(),
                item("Copy", #selector(copy(_:)), "c"), .separator(),
                item("Copy Path", #selector(copyPath(_:))), item("Show in Finder", #selector(showInFinder(_:))),
                item("Get Info", #selector(getInfo(_:)), "i"), .separator(), empty]
    }
}
