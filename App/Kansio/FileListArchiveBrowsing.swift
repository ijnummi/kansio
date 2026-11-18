import AppKit
import FileSystemKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// An archive was opened for browsing (object: its URL): the navigation pane shows it under its folder now.
    static let kansioArchiveOpened = Notification.Name("dev.kansio.archiveOpened")
}

extension NSPasteboard.PasteboardType {
    /// Items copied (⌘C) inside a browsed archive: `{"archive": path, "paths": [inner paths]}` — pasting extracts them.
    static let kansioArchiveItems = NSPasteboard.PasteboardType("dev.kansio.archive-items")
}

/// Browsing archives as read-only folders (P3-5). Opening an archive (double-click / Enter, with the setting on)
/// reads its listing off the main thread, registers it in `OpenedArchives` and navigates into it; the folders inside
/// are paths through the archive file (`…/photos.zip/2024/June`), so history, Up, the address bar, tabs and the tree
/// treat them like folders. Nothing in an archive is written: rename, Move to Trash, New Folder, paste and drops are
/// refused inline. Opening a file inside (or Quick Look) extracts just that file into a temporary folder; ⌘C then ⌘V
/// elsewhere, Copy To, and dragging out (file promises — Finder too) extract the items through the operations panel.
@MainActor
final class ArchiveBrowser {
    static let shared = ArchiveBrowser()

    /// Files extracted for opening and Quick Look (Kansio's own folder in the temporary directory, cleared at launch).
    let viewRoot = FileManager.default.temporaryDirectory.appending(path: "kansio-archive-view", directoryHint: .isDirectory)
    /// (archive, its date, inner path) → the extracted copy.
    private var viewed: [String: URL] = [:]

    private init() {
        let root = viewRoot
        Task.detached(priority: .background) {
            // Only ever our own folder in the temporary directory.
            if root.lastPathComponent == "kansio-archive-view" { try? FileManager.default.removeItem(at: root) }
        }
    }

    /// Reads `archive` (off the main thread) and registers it for browsing.
    func open(_ archive: URL) async -> Result<ArchiveIndex, FileSystemError> {
        let engines = ArchiveService.shared.engines
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ArchiveIndex, FileSystemError> in
            do throws(FileSystemError) { return .success(try ArchiveIndex.readBlocking(archive, engines: engines, cancel: CancellationFlag())) }
            catch { return .failure(error) }
        }.value
        if case .success(let index) = result {
            OpenedArchives.shared.register(index)
            NotificationCenter.default.post(name: .kansioArchiveOpened, object: archive)
        }
        return result
    }

    /// `index`, or a fresh one when the archive changed on disk since it was read (nil error: it's gone).
    func current(_ index: ArchiveIndex) async -> Result<ArchiveIndex, FileSystemError> {
        let path = index.archivePath
        let unchanged = await Task.detached(priority: .userInitiated) { () -> Bool? in
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            return Int64(st.st_size) == index.size && abs(modified.timeIntervalSince(index.modified)) < 0.001
        }.value
        switch unchanged {
        case true?: return .success(index)
        case false?: return await open(URL(filePath: path))
        case nil:
            OpenedArchives.shared.forget(path)
            return .failure(FileSystemError(.notFound, path: path))
        }
    }

    /// The items at `paths` (inner paths) extracted into a temporary folder, for opening or Quick Look; extracted
    /// once per archive version. The copies are read-only: changes wouldn't go back into the archive.
    func extractForViewing(_ index: ArchiveIndex, paths: [String]) async -> Result<[URL], FileSystemError> {
        func key(_ path: String) -> String { "\(index.archivePath)\u{0}\(index.modified.timeIntervalSinceReferenceDate)\u{0}\(path)" }
        let fm = FileManager.default
        let missing = paths.filter { viewed[key($0)].map { !fm.fileExists(atPath: $0.path(percentEncoded: false)) } ?? true }
        if !missing.isEmpty {
            let folder = viewRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                return .failure(FileSystemError(.other(error.localizedDescription), path: folder.path(percentEncoded: false)))
            }
            let operations = ArchiveService.shared.operations(trasher: TrashService.shared.trasher)
            let archive = URL(filePath: index.archivePath)
            // One folder per item: two items with the same name (from different folders) don't clash.
            for path in missing {
                let into = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try? fm.createDirectory(at: into, withIntermediateDirectories: true)
                let result = await operations.extractItems(from: archive, paths: [path], into: into)
                if let error = result.errors.first?.error { return .failure(error) }
                guard let extracted = result.created.first else {
                    return .failure(FileSystemError(.other("It isn’t in the archive"), path: path))
                }
                Self.makeReadOnly(extracted)
                viewed[key(path)] = extracted
            }
        }
        return .success(paths.compactMap { viewed[key($0)] })
    }

    private static func makeReadOnly(_ url: URL) {
        var st = stat()
        let path = url.path(percentEncoded: false)
        if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG { chmod(path, st.st_mode & ~mode_t(0o222)) }
    }

    /// The archive `url` is in, if any, and the folder inside it.
    static func location(of url: URL) -> (index: ArchiveIndex, inner: String)? {
        OpenedArchives.shared.location(of: url.path(percentEncoded: false))
    }

    static func isInsideArchive(_ url: URL) -> Bool { location(of: url) != nil }
}

extension FileListViewController {
    var isShowingArchive: Bool { archiveIndex != nil }

    /// "“photos.zip” is read-only…" — for anything that would write into a browsed archive. True if refused.
    @discardableResult
    func refuseInArchive() -> Bool {
        guard let index = archiveIndex else { return false }
        NSSound.beep()
        showMessage("“\((index.archivePath as NSString).lastPathComponent)” is read-only here. Extract it to change what’s inside.")
        return true
    }

    /// `load` reached a folder inside an opened archive.
    func loadArchive(_ location: (index: ArchiveIndex, inner: String), generation gen: Int) -> Task<Void, Never> {
        archiveIndex = location.index
        archiveInner = location.inner
        return Task { [weak self] in
            let fresh = await ArchiveBrowser.shared.current(location.index)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            let index: ArchiveIndex
            switch fresh {
            case .success(let current): index = current
            case .failure(let error):
                self.archiveIndex = nil
                self.applyError(error, generation: gen)
                return
            }
            self.archiveIndex = index
            guard let items = index.items(in: location.inner) else {
                self.applyError(FileSystemError(.notFound, path: self.folder.path(percentEncoded: false)), generation: gen)
                return
            }
            let sort = self.settings.sort, hidden = self.settings.showHidden
            let (contents, ordered) = await Task.detached(priority: .userInitiated) { () -> (FolderContents, [FileItem]) in
                let contents = FolderContents(items: items)
                return (contents, contents.ordered(by: sort, includeHidden: hidden))
            }.value
            guard gen == self.generation else { return }
            FileKind.prewarm(ordered.prefix(300))
            self.applyLoaded(ListingUpdate(contents: contents, isComplete: true), ordered: ordered, sort: sort, hidden: hidden,
                             generation: gen, scrollToTop: true)
            if index.isEncrypted { self.showMessage("This archive is password-protected: its files can be listed but not opened yet.") }
        }
    }

    func endArchive() {
        archiveIndex = nil
        archiveInner = ""
    }

    /// The selected items' paths inside the archive.
    func archivePaths(of items: [FileItem]) -> [String] {
        guard let index = archiveIndex else { return [] }
        return items.map { index.storedPath(of: $0.name, in: archiveInner) }
    }

    /// Double-click / Enter on an archive file (setting on): browse it.
    func browseArchive(_ url: URL) {
        let gen = generation
        // A big archive takes a moment to list: say so (the list stays usable meanwhile).
        let notice = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.showMessage("Reading “\(url.lastPathComponent)”…", persistent: true)
        }
        Task { [weak self] in
            let result = await ArchiveBrowser.shared.open(url)
            notice.cancel()
            guard let self, gen == self.generation else { return }
            if self.bannerText.hasPrefix("Reading “") { self.hideMessage() }
            switch result {
            case .success: self.navigate(to: URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory))
            case .failure(let error): self.showMessage("Couldn’t open “\(url.lastPathComponent)” as a folder: \(error.reason)")
            }
        }
    }

    /// Opening files inside an archive: extracted to a temporary folder first (an archive inside is browsed in turn).
    func openFromArchive(_ items: [FileItem]) {
        guard let index = archiveIndex else { return }
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else { NSSound.beep(); return }
        let gen = generation, paths = archivePaths(of: files)
        Task { [weak self] in
            let result = await ArchiveBrowser.shared.extractForViewing(index, paths: paths)
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let urls):
                if urls.count == 1, let url = urls.first, self.settings.openArchivesAsFolders, ArchiveNames.isArchive(url.lastPathComponent) {
                    self.browseArchive(url)
                } else {
                    self.openWithApps(urls, app: nil)
                }
            case .failure(let error):
                self.showMessage("Couldn’t open “\(files[0].name)”: \(error.reason)")
            }
        }
    }

    /// Quick Look inside an archive: the extracted copies (extracted when first asked; the panel reloads then).
    func archivePreviewURL(_ item: FileItem) -> URL? {
        guard let index = archiveIndex, !item.isFolder else { return nil }
        let path = index.storedPath(of: item.name, in: archiveInner)
        if let ready = archivePreviewCache[path] { return ready }
        if !archivePreviewPending.contains(path) {
            archivePreviewPending.insert(path)
            let gen = generation
            Task { [weak self] in
                let result = await ArchiveBrowser.shared.extractForViewing(index, paths: [path])
                guard let self, gen == self.generation else { return }
                self.archivePreviewPending.remove(path)
                if case .success(let urls) = result, let url = urls.first {
                    self.archivePreviewCache[path] = url
                    self.quickLookSelectionChanged()
                }
            }
        }
        return nil
    }

    // MARK: Copying out

    /// ⌘C inside an archive: Kansio's own clipboard type (and the paths as text); ⌘V in a folder extracts them.
    func copyArchiveSelection() {
        guard let index = archiveIndex, !selectedItems.isEmpty else { NSSound.beep(); return }
        let paths = archivePaths(of: selectedItems)
        let payload: [String: Any] = ["archive": index.archivePath, "paths": paths]
        pasteboard.clearContents()
        if let data = try? JSONSerialization.data(withJSONObject: payload) { pasteboard.setData(data, forType: .kansioArchiveItems) }
        pasteboard.setString(selectedItems.map { url(of: $0).path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
    }

    /// What ⌘C copied inside an archive, if that's what's on the clipboard.
    var pasteboardArchiveItems: (archive: URL, paths: [String])? {
        guard let data = pasteboard.data(forType: .kansioArchiveItems),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let archive = payload["archive"] as? String, let paths = payload["paths"] as? [String], !paths.isEmpty else { return nil }
        return (URL(filePath: archive), paths)
    }

    /// Extracts items of `archive` into `destination` as a row in the operations panel (conflicts asked; undo trashes
    /// what arrived).
    func extractFromArchive(_ archive: URL, paths: [String], into destination: URL) {
        guard !ArchiveBrowser.isInsideArchive(destination) else { refuseInArchive(); return }
        conflictPrompter.window = view.window
        let prompter = conflictPrompter
        let policy = ConflictPolicy { conflict in await prompter.ask(conflict) }
        let operations = ArchiveService.shared.operations(trasher: trasher, resolver: policy.resolver)
        let trasher = self.trasher
        let what = paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : "\(paths.count) items"
        OperationCenter.shared.start(title: "Extracting \(what) from “\(archive.lastPathComponent)”") { progress in
            await operations.extractItems(from: archive, paths: paths, into: destination, progress: progress)
        } completion: { [weak self] (result: ArchiveOperations.ExtractResult) in
            let changes: [FileChange] = result.replaced.map { .trashed(original: $0.existing, slot: TrashSlot($0.inTrash)) }
                + result.created.map { .created($0, slot: TrashSlot()) }
            FileUndo.shared.register(UndoStep("Extract", changes), trasher: trasher)
            guard let self else { return }
            self.announce(result.created + result.replaced.map(\.existing))
            self.refreshAffected(result.created, select: true)
            if let message = Self.extractSummary(result) { self.showMessage(message) }
        }
    }

    // MARK: Dragging out: file promises (Finder, Kansio, any app that takes files)

    func archivePromise(for item: FileItem) -> NSFilePromiseProvider? {
        guard let index = archiveIndex else { return nil }
        let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        let writer = ArchivePromiseWriter(archive: URL(filePath: index.archivePath), path: index.storedPath(of: item.name, in: archiveInner),
                                          name: item.name, engines: ArchiveService.shared.engines)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
        provider.userInfo = writer // the provider doesn't keep its delegate
        return provider
    }

    // MARK: Context menu

    func archiveContextMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mods
            menuItem.target = self
            return menuItem
        }
        var items: [NSMenuItem] = []
        if !selectedItems.isEmpty {
            items.append(item("Open", #selector(openSelectionAction(_:)), "o"))
            if selectedItems.allSatisfy(\.isFolder) {
                items.append(item("Open in New Tab", #selector(openInNewTab(_:))))
                items.append(item("Open in New Window", #selector(openInNewWindow(_:))))
            }
            items.append(item("Quick Look", #selector(toggleQuickLook(_:)), "y"))
            items.append(.separator())
            items.append(item("Copy", #selector(copy(_:)), "c"))
            let copyTo = NSMenuItem(title: copyToMenu.kind.title, action: nil, keyEquivalent: "")
            copyTo.submenu = copyToMenu.makeMenu()
            items.append(copyTo)
            items.append(.separator())
        }
        items.append(item("Copy Path", #selector(copyPath(_:))))
        items.append(item("Show Archive in Finder", #selector(showInFinder(_:))))
        return items
    }
}

/// Writes one dragged-out archive item where the receiving app asks (extracted into a temporary folder there, then
/// renamed into place: nothing half-written appears under the name).
final class ArchivePromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let archive: URL
    let path: String
    let name: String
    let engines: [any ArchiveEngine]
    private let queue = OperationQueue()

    init(archive: URL, path: String, name: String, engines: [any ArchiveEngine]) {
        self.archive = archive
        self.path = path
        self.name = name
        self.engines = engines
        queue.qualityOfService = .userInitiated
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appending(path: ".kansio-partial-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false) } catch { completionHandler(error); return }
        let result = ArchiveOperations(engines: engines).extractItemsBlocking(from: archive, paths: [path], into: temp,
                                                                              cancel: CancellationFlag(), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: temp) } // only our own temporary folder (emptied below)
        guard let extracted = result.created.first else {
            completionHandler(result.errors.first?.error ?? FileSystemError(.other("It isn’t in the archive"), path: path))
            return
        }
        let err = ExclusiveRename.rename(extracted.path(percentEncoded: false), url.path(percentEncoded: false))
        completionHandler(err == 0 ? nil : FileSystemError(errno: err, path: url.path(percentEncoded: false)))
    }
}
