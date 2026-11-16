import AppKit
import FileSystemKit
import Quartz

extension NSPasteboard.PasteboardType {
    /// Marks a clipboard written by ⌘X: paste moves instead of copies (Explorer's real cut).
    static let kansioCut = NSPasteboard.PasteboardType("dev.kansio.cut")
}

/// An inline rename in progress (F2, or right after New Folder).
@MainActor
final class RenameSession {
    let originalName: String
    let editor: NSTextField
    init(originalName: String, editor: NSTextField) {
        self.originalName = originalName
        self.editor = editor
    }
}

/// M7 operations on the list: rename, new folder, move to trash, copy/cut, Quick Look.
/// Operations run off the main thread (FileOperations); the result is applied as a small
/// change to the folder model (`FolderContents.applying`) — never a re-list.
extension FileListViewController: NSTextFieldDelegate, NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    // MARK: Applying our own changes

    /// Removes/adds items in the model off-main, then shows the result and selects `select`.
    func applyLocalChange(removing: Set<String> = [], adding: [FileItem] = [], select: [String] = [],
                          then: (@MainActor () -> Void)? = nil) {
        applyLocalChange(removing: removing, adding: adding, select: select, attempt: 0, then: then)
    }

    private func applyLocalChange(removing: Set<String>, adding: [FileItem], select: [String], attempt: Int,
                                  then: (@MainActor () -> Void)?) {
        let contents = self.contents
        let sort = ViewSettings.shared.sort, hidden = ViewSettings.shared.showHidden
        let version = contentsVersion, gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let updated = contents.applying(removing: removing, adding: adding)
            let ordered = updated.ordered(by: sort, includeHidden: hidden)
            FileKind.prewarm(adding)
            await self?.finishLocalChange(updated, ordered: ordered, version: version, generation: gen, select: select,
                                          change: (removing, adding, attempt), then: then)
        }
    }

    private func finishLocalChange(_ updated: FolderContents, ordered: [FileItem], version: Int, generation gen: Int,
                                   select: [String], change: (removing: Set<String>, adding: [FileItem], attempt: Int),
                                   then: (@MainActor () -> Void)?) {
        guard gen == generation else { return }
        // The model changed meanwhile (e.g. a live update reported the same files first): apply this
        // change again on top of the current model — it's idempotent (items are replaced by name) —
        // so its selection ("select what was pasted") isn't lost.
        guard version == contentsVersion else {
            if change.attempt < 3 {
                applyLocalChange(removing: change.removing, adding: change.adding, select: select, attempt: change.attempt + 1, then: then)
            }
            return
        }
        releaseOffMain(contents)
        contents = updated
        contentsVersion += 1
        pendingSelection = select
        if isSearching { // the results, not the folder's rows
            refreshSearchAfterChange()
            then?()
            return
        }
        Trace.time("local change setRows \(ordered.count)") { setRows(ordered, scrollToTop: false, isComplete: !isLoading) }
        Trace.time("local change select \(select.count)") { applyPendingSelection(final: true) }
        then?()
    }

    /// Reads one item's fresh metadata off-main (after a rename / new folder).
    nonisolated static func readItem(_ url: URL, keepingLinkFlagsOf old: FileItem? = nil) async -> FileItem? {
        await Task.detached(priority: .userInitiated) {
            guard var item = try? BulkDirectoryLister.readItem(at: url) else { return nil }
            if item.kind == .symlink, let old {
                item.flags.formUnion(old.flags.intersection(.linkTarget))
            }
            return item
        }.value
    }

    func url(of item: FileItem) -> URL {
        folder.appending(path: item.name, directoryHint: item.kind == .directory ? .isDirectory : .notDirectory)
    }

    var selectedItems: [FileItem] { tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil } }

    // MARK: Rename (F2)

    @objc func renameSelection(_ sender: Any?) {
        guard tableView.selectedRowIndexes.count == 1, let row = tableView.selectedRowIndexes.first else { NSSound.beep(); return }
        beginRename(row: row)
    }

    /// Opens an inline editor over the name cell, with the name (minus extension) selected.
    func beginRename(row: Int, initialText: String? = nil) {
        endRename(commit: false)
        guard row < rows.count, let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileSort.Field.name.rawValue })
        else { return }
        tableView.scrollRowToVisible(row)
        let item = rows[row]
        let cell = tableView.frameOfCell(atColumn: nameColumn, row: row)
        let editor = NSTextField(string: initialText ?? item.name)
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.isBordered = true
        editor.isBezeled = true
        editor.bezelStyle = .squareBezel
        editor.focusRingType = .exterior
        editor.lineBreakMode = .byClipping
        editor.cell?.isScrollable = true
        editor.cell?.usesSingleLineMode = true
        editor.delegate = self
        editor.setAccessibilityLabel("Rename “\(item.name)”")
        editor.frame = NSRect(x: cell.minX + 21, y: cell.minY + 1, width: max(120, cell.width - 23), height: cell.height - 2)
        tableView.addSubview(editor)
        renameSession = RenameSession(originalName: item.name, editor: editor)
        view.window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectedRange = initialText == nil
            ? FileNames.editableRange(of: item.name, isFolder: item.isFolder)
            : NSRange(location: 0, length: (editor.stringValue as NSString).length)
    }

    /// Ends inline rename; with `commit`, renames on disk (off-main) if the name changed.
    func endRename(commit: Bool) {
        guard let session = renameSession else { return }
        renameSession = nil
        let newName = session.editor.stringValue
        session.editor.delegate = nil
        session.editor.removeFromSuperview()
        view.window?.makeFirstResponder(tableView)
        guard commit, newName != session.originalName, let old = contents.item(named: session.originalName) else { return }
        let oldURL = url(of: old)
        let gen = generation
        Task { [weak self] in
            let result = await FileOperations.rename(oldURL, to: newName)
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let newURL):
                let fresh = await Self.readItem(newURL, keepingLinkFlagsOf: old)
                    ?? FileItem(name: newName, kind: old.kind, flags: old.flags, size: old.size,
                                modificationDate: old.modificationDate, creationDate: old.creationDate, fileID: old.fileID)
                self.applyLocalChange(removing: [old.name], adding: [fresh], select: [fresh.name])
                FileUndo.shared.register(UndoStep("Rename", [.renamed(from: oldURL, to: newURL)]), trasher: self.trasher)
                self.announce([oldURL, newURL])
            case .failure(let error):
                // Explorer: say why, then let the user fix the name.
                self.showMessage(error.description)
                if let row = self.rows.firstIndex(where: { $0.name == old.name }) {
                    self.beginRename(row: row, initialText: newName)
                }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let session = renameSession, control === session.editor else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere commits (Explorer), unless Enter/Esc already ended it.
        guard let session = renameSession, (obj.object as? NSTextField) === session.editor else { return }
        endRename(commit: true)
    }

    // MARK: New folder (⇧⌘N)

    @objc func newFolder(_ sender: Any?) {
        let parent = folder
        let gen = generation
        Task { [weak self] in
            let result = await FileOperations.createFolder(in: parent)
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let name):
                let created = parent.appending(path: name, directoryHint: .isDirectory)
                FileUndo.shared.register(UndoStep("New Folder", [.created(created, slot: TrashSlot())]), trasher: self.trasher)
                self.announce([created])
                guard let item = await Self.readItem(created) else { return }
                self.applyLocalChange(adding: [item], select: [name]) { [weak self] in
                    guard let self, let row = self.rows.firstIndex(where: { $0.name == name }) else { return }
                    self.beginRename(row: row) // Explorer: name the new folder right away
                }
            case .failure(let error):
                self.showMessage("Couldn’t create a folder here. \(error.description)")
            }
        }
    }

    // MARK: Move to Trash (⌘⌫, Delete)

    @objc func moveToTrash(_ sender: Any?) {
        let items = selectedItems
        guard !items.isEmpty, let firstRow = tableView.selectedRowIndexes.first else { NSSound.beep(); return }
        let urls = items.map(url(of:))
        let trasher = self.trasher
        let gen = generation
        Task { [weak self] in
            let outcome = await FileOperations.trash(urls, using: trasher)
            guard let self, gen == self.generation else { return }
            let removed = Set(outcome.trashed.map { $0.original.lastPathComponent })
            FileUndo.shared.register(UndoStep("Move to Trash", outcome.trashed.map { .trashed(original: $0.original, slot: TrashSlot($0.inTrash)) }),
                                     trasher: trasher)
            self.announce(outcome.trashed.map(\.original))
            self.applyLocalChange(removing: removed) { [weak self] in
                guard let self, !self.rows.isEmpty, !removed.isEmpty else { return }
                // Explorer keeps the cursor where the items were.
                let row = min(firstRow, self.rows.count - 1)
                self.tableView.selectRowIndexes([row], byExtendingSelection: false)
                self.tableView.scrollRowToVisible(row)
            }
            if let first = outcome.failed.first {
                let more = outcome.failed.count > 1 ? " (and \(outcome.failed.count - 1) more)" : ""
                self.showMessage("Couldn’t move “\(first.url.lastPathComponent)” to the Trash\(more): \(first.error.description)")
            }
        }
    }

    // MARK: Clipboard (⌘C / ⌘X / ⌘V)

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard(cut: false) }
    @objc func cut(_ sender: Any?) { writeSelectionToPasteboard(cut: true) }

    /// File URLs on the clipboard (from Kansio or Finder).
    var pasteboardFileURLs: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// ⌘V: copies (or, after ⌘X, moves) the clipboard's files into the current folder.
    @objc func paste(_ sender: Any?) {
        let urls = pasteboardFileURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        let isMove = pasteboard.data(forType: .kansioCut) != nil
        runCopyEngine(isMove ? .move : .copy, sources: urls, into: folder, actionName: isMove ? "Move" : "Copy") { [weak self] result in
            guard let self, isMove, !result.completed.isEmpty else { return }
            // Explorer: after a cut-paste the clipboard is spent.
            self.pasteboard.clearContents()
            self.cut = nil
        }
    }

    /// ⌘D (Finder): copies the selection next to itself ("name - Copy").
    @objc func duplicate(_ sender: Any?) {
        let urls = selectedItems.map(url(of:))
        guard !urls.isEmpty else { NSSound.beep(); return }
        runCopyEngine(.copy, sources: urls, into: folder, actionName: "Duplicate")
    }

    /// ⌘.: stops this window's copy/move operations (what's done stays; partial items are removed).
    @objc func stopOperations(_ sender: Any?) {
        runningOperations.forEach(OperationCenter.shared.cancel)
    }

    /// Runs a copy/move through the app-wide OperationCenter (progress panel, Retry/Skip/Stop on
    /// errors, conflict sheets on this window), then shows the result here and reports problems.
    /// `undoAsCreated`: undo trashes what arrived (files received from another app have no source to go back to).
    func runCopyEngine(_ kind: OperationResult.Kind, sources: [URL], into destination: URL, actionName: String,
                       undoAsCreated: Bool = false, completion: (@MainActor (OperationResult) -> Void)? = nil) {
        conflictPrompter.window = view.window
        var started: UUID?
        let id = OperationCenter.shared.start(kind, sources: sources, destination: destination, trasher: trasher,
                                              prompter: conflictPrompter) { [weak self] result in
            guard let self else { return }
            if let started { self.runningOperations.remove(started) }
            Trace.time("undo register \(result.completed.count)") {
                if undoAsCreated {
                    FileUndo.shared.register(UndoStep(actionName, result.completed.map { .created($0.destination, slot: TrashSlot()) }), trasher: self.trasher)
                } else {
                    FileUndo.shared.register(UndoStep(actionName, result: result), trasher: self.trasher)
                }
            }
            Trace.time("announce") { self.announce(UndoStep(actionName, result: result).affectedURLs) }
            Task {
                await self.applyOperationResult(result, destination: destination)
                completion?(result)
            }
        }
        started = id
        runningOperations.insert(id)
    }

    private func applyOperationResult(_ result: OperationResult, destination: URL) async {
        Trace.note?("applyOperationResult \(result.completed.count)")
        let here = Self.standardized(folder)
        // New items that landed in the folder we're showing.
        var added: [FileItem] = []
        for (_, target) in result.completed where Self.standardized(target.deletingLastPathComponent()) == here {
            if let item = await Self.readItem(target) { added.append(item) }
        }
        // Items that moved away from the folder we're showing.
        let removed = result.kind == .move
            ? Set(result.completed.filter { Self.standardized($0.source.deletingLastPathComponent()) == here }.map { $0.source.lastPathComponent })
            : []
        if !added.isEmpty || !removed.isEmpty {
            applyLocalChange(removing: removed, adding: added, select: added.map(\.name))
        }
        showMessage(Self.summary(of: result))
    }

    static func standardized(_ url: URL) -> String {
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    static func summary(of result: OperationResult) -> String {
        let verb = result.kind == .copy ? "Copied" : "Moved"
        let done = result.completed.count
        var parts: [String] = []
        if result.cancelled { parts.append("Stopped. \(verb) \(done) of \(done + result.skipped.count + max(0, result.errors.count - result.skipped.count)) items.") }
        else if result.errors.isEmpty { parts.append("\(verb) \(done == 1 ? "1 item" : "\(done) items").") }
        let conflicts = result.errors.filter { $0.error.description.contains("already exists") }
        if !conflicts.isEmpty {
            parts.append(conflicts.count == 1 ? "“\(conflicts[0].url.lastPathComponent)” already exists here — skipped."
                                              : "\(conflicts.count) items already exist here — skipped.")
        }
        let others = result.errors.filter { !$0.error.description.contains("already exists") }
        if let first = others.first {
            parts.append("Problem with “\(first.url.lastPathComponent)”: \(first.error.reason)\(others.count > 1 ? " (+\(others.count - 1) more)" : "").")
        }
        return parts.joined(separator: " ")
    }

    // MARK: New text document

    @objc func newTextDocument(_ sender: Any?) {
        let parent = folder
        let gen = generation
        Task { [weak self] in
            let result = await FileOperations.createTextFile(in: parent)
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let name):
                let created = parent.appending(path: name)
                FileUndo.shared.register(UndoStep("New Text Document", [.created(created, slot: TrashSlot())]), trasher: self.trasher)
                self.announce([created])
                guard let item = await Self.readItem(created) else { return }
                self.applyLocalChange(adding: [item], select: [name]) { [weak self] in
                    guard let self, let row = self.rows.firstIndex(where: { $0.name == name }) else { return }
                    self.beginRename(row: row)
                }
            case .failure(let error):
                self.showMessage("Couldn’t create a file here. \(error.description)")
            }
        }
    }

    private func writeSelectionToPasteboard(cut isCut: Bool) {
        let items = selectedItems
        guard !items.isEmpty else { NSSound.beep(); return }
        let urls = items.map { url(of: $0) as NSURL }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        if isCut { pasteboard.setData(Data(), forType: .kansioCut) }
        let previous = cut
        cut = isCut ? (folder, Set(items.map(\.name)), pasteboard.changeCount) : nil
        if previous != nil || isCut { refreshRows(oldCount: rows.count) } // update dimming
    }

    /// A cut made elsewhere (the navigation pane): dim those items if they're in this folder.
    func markCut(_ urls: [URL]) {
        let here = Self.standardized(folder)
        let names = Set(urls.filter { Self.standardized($0.deletingLastPathComponent()) == here }.map(\.lastPathComponent))
        let previous = cut
        cut = names.isEmpty ? nil : (folder, names, pasteboard.changeCount)
        if previous != nil || cut != nil { refreshRows(oldCount: rows.count) }
    }

    /// True while `item` is cut and the clipboard still holds that cut.
    func isCut(_ item: FileItem) -> Bool {
        guard let cut, cut.folder == folder, cut.names.contains(item.name) else { return false }
        return cut.changeCount == pasteboard.changeCount
    }

    /// Paths currently on the clipboard (self-test).
    var pasteboardPaths: [String] {
        (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).map { $0.path(percentEncoded: false) }
    }

    // MARK: Keeping every window current

    /// Tells other windows that Kansio changed these items (this window already shows the change).
    func announce(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .kansioFilesChanged, object: self, userInfo: ["urls": urls])
    }

    /// Re-reads just the given items if they're in the folder on screen: present ones are added or
    /// updated, vanished ones removed. Never a full re-list.
    func refreshAffected(_ urls: [URL], select: Bool = false) {
        let here = Self.standardized(folder)
        let names = Set(urls.filter { Self.standardized($0.deletingLastPathComponent()) == here }.map(\.lastPathComponent))
        guard !names.isEmpty else { return }
        let directory = folder
        let gen = generation
        Task { [weak self] in
            var present: [FileItem] = []
            var gone: Set<String> = []
            for name in names {
                if let item = await Self.readItem(directory.appending(path: name)) { present.append(item) } else { gone.insert(name) }
            }
            guard let self, gen == self.generation else { return }
            self.applyLocalChange(removing: gone, adding: present, select: select ? present.map(\.name) : self.selectedNames)
        }
    }

    // MARK: Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let count = tableView.selectedRowIndexes.count
        switch menuItem.action {
        case #selector(renameSelection(_:)): return count == 1 && selectedItems.first?.name.contains("/") == false
        case #selector(moveToTrash(_:)), #selector(copy(_:)), #selector(cut(_:)): return count > 0
        case #selector(paste(_:)): return !pasteboardFileURLs.isEmpty
        case #selector(duplicate(_:)): return count > 0
        case #selector(stopOperations(_:)): return !runningOperations.isEmpty
        case #selector(toggleQuickLook(_:)): return count > 0
        case #selector(openSelectionAction(_:)): return count > 0
        case #selector(showPackageContents(_:)): return selectionIsSinglePackage
        case #selector(toggleColumn(_:)): return validateColumnItem(menuItem)
        case #selector(togglePinned(_:)):
            menuItem.title = pinTitle
            return !pinTargets.isEmpty
        default: return true
        }
    }

    // MARK: Quick Look (Space)

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Keeps the panel in sync with the selection while it's open.
    func quickLookSelectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        panel.reloadData()
    }

    // QLPreviewPanelController (informal protocol). The SDK declares these nonisolated, but
    // Quick Look always calls them on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selectedItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            let items = selectedItems
            return index < items.count ? self.url(of: items[index]) : nil
        }
        return url.map { $0 as NSURL }
    }

    /// Arrow keys in the panel move the selection in the list (Finder behaviour).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Delivered on the main thread; NSEvent just isn't marked Sendable.
        nonisolated(unsafe) let event = event
        return MainActor.assumeIsolated {
            guard let event, event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
            tableView.keyDown(with: event)
            return true
        }
    }
}
