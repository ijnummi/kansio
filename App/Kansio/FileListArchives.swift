import AppKit
import FileSystemKit

/// P2-3: Compress and Extract from the list's context menu.
///
/// - "Compress as “Holiday.7z”" keeps the originals; "Compress into “Holiday.7z”" also moves them to the Trash once the
///   finished archive has been checked against them. Name: one item's name, or the folder's name for several.
/// - One archive: "Extract Here", plus "Extract as “Photos”" unless the archive's only top-level item is a folder.
///   Several archives: "Extract Here", "Extract as *" (each into its own folder) and "Extract as flat “X”" (every file
///   into one folder named after the right-clicked archive; refused if an archive keeps files in more than one folder).
/// - All run in the File Operations panel (progress, Stop) and are undoable.
extension FileListViewController {
    /// What a Compress/Extract menu item does (its `representedObject`).
    final class ArchiveAction: NSObject {
        enum Kind { case compress(moveInto: Bool), extract(ArchiveOperations.ExtractMode) }
        let kind: Kind
        let urls: [URL]
        let name: String
        init(_ kind: Kind, urls: [URL], name: String) {
            self.kind = kind
            self.urls = urls
            self.name = name
        }
    }

    /// The Compress/Extract items for the current selection (`clicked`: the right-clicked row's item).
    func archiveMenuItems(clicked: FileItem?) -> [NSMenuItem] {
        let items = selectedItems
        guard !items.isEmpty, !isShowingTrash else { return [] }
        let urls = items.map(url(of:))
        var menuItems: [NSMenuItem] = []
        func add(_ title: String, _ action: ArchiveAction, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menuItems.append(item)
        }

        // Compress: every selected item in one folder (search results can come from several).
        let parents = Set(urls.map { Self.standardized($0.deletingLastPathComponent()) })
        if parents.count == 1 {
            let name = suggestedArchiveName(items, urls: urls)
            add("Compress as “\(name)”", ArchiveAction(.compress(moveInto: false), urls: urls, name: name), #selector(archiveAction(_:)))
            add("Compress into “\(name)”", ArchiveAction(.compress(moveInto: true), urls: urls, name: name), #selector(archiveAction(_:)))
        }

        // Extract: only when every selected item is an archive.
        if items.allSatisfy({ !$0.isFolder && ArchiveNames.isArchive($0.name) }) {
            if !menuItems.isEmpty { menuItems.append(.separator()) }
            add("Extract Here", ArchiveAction(.extract(.here), urls: urls, name: ""), #selector(archiveAction(_:)))
            if items.count == 1, let item = items.first, let url = urls.first {
                let single = ArchiveService.shared.isSingleFolder(url, size: item.size, modified: item.modificationDate)
                if single != true {
                    let base = ArchiveNames.baseName(url.lastPathComponent)
                    add("Extract as “\(base)”", ArchiveAction(.extract(.asFolder), urls: urls, name: base), #selector(archiveAction(_:)))
                }
            } else {
                add("Extract as *", ArchiveAction(.extract(.asFolder), urls: urls, name: ""), #selector(archiveAction(_:)))
                let target = clicked.flatMap { c in items.contains { $0.name == c.name } ? c : nil } ?? items[0]
                let base = ArchiveNames.baseName((target.name as NSString).lastPathComponent)
                add("Extract as flat “\(base)”", ArchiveAction(.extract(.flat(name: base)), urls: urls, name: base),
                    #selector(archiveAction(_:)))
            }
        }
        return menuItems
    }

    /// "Holiday.7z": the item's name (a file without its extension), or the folder's name for several; numbered
    /// ("Holiday (2).7z") if the folder on screen already has one — checked against the listing, no disk access.
    func suggestedArchiveName(_ items: [FileItem], urls: [URL]) -> String {
        let folders = Set(zip(items, urls).filter { $0.0.isFolder }.map(\.1))
        let base = ArchiveNames.suggestedBase(for: urls) { folders.contains($0) }
        let ext = ViewSettings.shared.archiveFormat.fileExtension
        let here = Set(contents.items.map(\.name))
        for n in 1...10_000 {
            let candidate = n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)"
            if !here.contains(candidate) { return candidate }
        }
        return "\(base).\(ext)"
    }

    @objc func archiveAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ArchiveAction else { return }
        switch action.kind {
        case .compress(let moveInto): compress(action.urls, name: action.name, moveInto: moveInto)
        case .extract(let mode): extract(action.urls, mode: mode)
        }
    }

    // MARK: Compress

    func compress(_ urls: [URL], name: String, moveInto: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let first = urls.first else { return }
        let settings = ViewSettings.shared
        let format = settings.archiveFormat, level = settings.archiveLevel
        let operations = ArchiveService.shared.operations(trasher: trasher)
        let trasher = self.trasher
        let what = urls.count == 1 ? "“\(first.lastPathComponent)”" : "\(urls.count) items"
        OperationCenter.shared.start(title: "Compressing \(what) into “\(name)”") { progress in
            await operations.compress(urls, name: name, format: format, level: level, verify: moveInto, progress: progress)
        } completion: { [weak self] result in
            guard let self else { return }
            guard let archive = result.archive else {
                if let error = result.error { self.showMessage("Couldn’t compress \(what): \(error.reason)") }
                completion?()
                return
            }
            guard moveInto else {
                FileUndo.shared.register(UndoStep("Compress", [.created(archive, slot: TrashSlot())]), trasher: trasher)
                self.announce([archive])
                self.refreshAffected([archive], select: true)
                completion?()
                return
            }
            // The archive checked out: the originals go to the Trash (a network volume asks first, as always).
            Task { [weak self] in
                let outcome = await TrashService.shared.moveToTrash(urls, window: self?.view.window)
                let changes: [FileChange] = [.created(archive, slot: TrashSlot())]
                    + outcome.trashed.map { .trashed(original: $0.original, slot: TrashSlot($0.inTrash)) }
                FileUndo.shared.register(UndoStep("Compress", changes), trasher: trasher)
                guard let self else { return }
                let gone = outcome.trashed.map(\.original) + outcome.deleted
                self.announce([archive] + gone)
                self.refreshAffected([archive] + gone, select: false)
                self.refreshAffected([archive], select: true)
                if outcome.cancelled {
                    self.showMessage("Compressed into “\(archive.lastPathComponent)”; the originals were kept.")
                } else if let failure = outcome.failed.first {
                    self.showMessage("Compressed, but “\(failure.url.lastPathComponent)” couldn’t be moved to the Trash: \(failure.error.reason)")
                }
                completion?()
            }
        }
    }

    // MARK: Extract

    func extract(_ urls: [URL], mode: ArchiveOperations.ExtractMode, completion: (@MainActor () -> Void)? = nil) {
        guard let first = urls.first else { return }
        conflictPrompter.window = view.window
        let prompter = conflictPrompter
        let policy = ConflictPolicy { conflict in await prompter.ask(conflict) }
        let operations = ArchiveService.shared.operations(trasher: trasher, resolver: policy.resolver)
        let trasher = self.trasher
        let what = urls.count == 1 ? "“\(first.lastPathComponent)”" : "\(urls.count) archives"
        // Into each archive's own folder (search results can come from several); flat: the right-clicked one's.
        var groups: [(destination: URL, archives: [URL])] = []
        if case .flat = mode {
            groups = [(first.deletingLastPathComponent(), urls)]
        } else {
            for url in urls {
                let parent = url.deletingLastPathComponent()
                if let i = groups.firstIndex(where: { Self.standardized($0.destination) == Self.standardized(parent) }) {
                    groups[i].archives.append(url)
                } else {
                    groups.append((parent, [url]))
                }
            }
        }
        let jobs = groups
        OperationCenter.shared.start(title: "Extracting \(what)") { progress in
            var total = ArchiveOperations.ExtractResult()
            for job in jobs {
                if Task.isCancelled { total.cancelled = true; break }
                let result = await operations.extract(job.archives, mode: mode, into: job.destination, progress: progress)
                total.created += result.created
                total.replaced += result.replaced
                total.errors += result.errors
                total.skipped += result.skipped
                if result.cancelled { total.cancelled = true; break }
            }
            return total
        } completion: { [weak self] (result: ArchiveOperations.ExtractResult) in
            let changes: [FileChange] = result.replaced.map { .trashed(original: $0.existing, slot: TrashSlot($0.inTrash)) }
                + result.created.map { .created($0, slot: TrashSlot()) }
            FileUndo.shared.register(UndoStep("Extract", changes), trasher: trasher)
            guard let self else { return }
            self.announce(result.created + result.replaced.map(\.existing))
            self.refreshAffected(result.created, select: true)
            if let message = Self.extractSummary(result) { self.showMessage(message) }
            completion?()
        }
    }

    static func extractSummary(_ result: ArchiveOperations.ExtractResult) -> String? {
        let conflicts = result.errors.filter { $0.error.description.contains("already exists") }
        let others = result.errors.filter { !$0.error.description.contains("already exists") }
        var parts: [String] = []
        if result.cancelled { parts.append("Extraction stopped.") }
        if let first = others.first {
            parts.append("Couldn’t extract “\(first.url.lastPathComponent)”: \(first.error.reason)\(others.count > 1 ? " (+\(others.count - 1) more)" : "").")
        }
        if !conflicts.isEmpty {
            parts.append(conflicts.count == 1 ? "“\(conflicts[0].url.lastPathComponent)” already exists here — skipped."
                                              : "\(conflicts.count) items already exist here — skipped.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
