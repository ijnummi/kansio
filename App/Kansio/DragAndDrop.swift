import AppKit
import FileSystemKit
import UniformTypeIdentifiers

/// Drag and drop of files (P1-4): onto the list (its folder, or a folder row), onto folders in
/// the navigation pane, from Finder (file URLs) and from Mail/Photos (file promises).
///
/// Move or copy follows Finder: ⌥ copies, ⌘ moves; otherwise moving within a volume, copying
/// across volumes. Every drop runs through the copy engine like a paste — progress panel,
/// conflict sheets, Retry/Skip/Stop, undo. Nothing here touches the disk while dragging:
/// "same volume" is decided from the mounted-volume list, and the dragged URLs are read once
/// per drag (validation runs on every mouse move).
@MainActor
enum FileDrop {
    /// Types a drop target registers.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// One drag's sources as the checks need them, prepared once (validation runs on every mouse move).
    private struct DragSources {
        let sequence: Int
        /// Normalized source paths — all of them, or (another app's drag of thousands) the first 100.
        let paths: [String]
        let parents: Set<String>
        /// `paths` covers every source (otherwise the drop re-checks with the full list).
        let complete: Bool
        var decisions: [String: NSDragOperation] = [:]
    }

    private static var current: DragSources?
    /// A drag from Kansio's list: its folder and item names (no pasteboard reads, no URL work per item).
    private static var local: (sequence: Int, folder: URL, names: [String])?
    private static var fullURLs: (sequence: Int, urls: [URL])?
    static let sampleSize = 100

    static func beginLocalDrag(folder: URL, names: [String], sequence: Int) { local = (sequence, folder, names) }
    static func endLocalDrag() { local = nil }

    private static func sources(_ info: any NSDraggingInfo) -> DragSources {
        let sequence = info.draggingSequenceNumber
        if let current, current.sequence == sequence { return current }
        let prepared: DragSources
        if let local, local.sequence == sequence {
            let base = normalized(local.folder.path(percentEncoded: false))
            let prefix = base == "/" ? "/" : base + "/"
            prepared = DragSources(sequence: sequence, paths: local.names.map { prefix + $0 }, parents: [base], complete: true)
        } else {
            let items = info.draggingPasteboard.pasteboardItems ?? []
            let sample = items.prefix(sampleSize).compactMap(fileURL(of:))
            let paths = sample.map { normalized($0.path(percentEncoded: false)) }
            prepared = DragSources(sequence: sequence, paths: paths,
                                   parents: Set(paths.map { normalized(($0 as NSString).deletingLastPathComponent) }),
                                   complete: items.count <= sampleSize)
        }
        current = prepared
        return prepared
    }

    private static func fileURL(of item: NSPasteboardItem) -> URL? {
        item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
    }

    /// Every dragged file URL (read once per drag, when dropping).
    static func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let sequence = info.draggingSequenceNumber
        if let fullURLs, fullURLs.sequence == sequence { return fullURLs.urls }
        let urls: [URL]
        if let local, local.sequence == sequence {
            urls = local.names.map { local.folder.appending(path: $0) }
        } else {
            // `pasteboardItems` + strings is ~4× faster than readObjects(NSURL) for thousands of items.
            urls = (info.draggingPasteboard.pasteboardItems ?? []).compactMap(fileURL(of:))
        }
        fullURLs = (sequence, urls)
        return urls
    }

    private static func hasFileURLs(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(.fileURL) == true || local?.sequence == info.draggingSequenceNumber
    }

    nonisolated static func normalized(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }

    /// File promises (Mail attachments, Photos) when there are no plain file URLs.
    static func promises(_ info: any NSDraggingInfo) -> [NSFilePromiseReceiver] {
        guard !hasFileURLs(info) else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// What dropping `info` on `destination` would do: .move, .copy, or [] (refused).
    static func operation(for info: any NSDraggingInfo, destination: URL, volumes: [Volume]) -> NSDragOperation {
        var drag = sources(info)
        if drag.paths.isEmpty { return promises(info).isEmpty ? [] : .copy }
        let mask = info.draggingSourceOperationMask
        let key = "\(mask.rawValue) \(destination.path(percentEncoded: false))"
        if let decided = drag.decisions[key] { return decided }
        let decided = decide(drag, mask: mask, destination: destination, volumes: volumes)
        drag.decisions[key] = decided
        current = drag
        return decided
    }

    private static func decide(_ drag: DragSources, mask: NSDragOperation, destination: URL, volumes: [Volume]) -> NSDragOperation {
        let operation: NSDragOperation
        if mask == .copy || (mask.contains(.copy) && !mask.contains(.move) && !mask.contains(.generic)) {
            operation = .copy // ⌥, or a source that only allows copying
        } else if !mask.contains(.copy) && (mask.contains(.move) || mask.contains(.generic)) {
            operation = .move // ⌘
        } else {
            operation = sameVolume(drag.parents, destination, volumes) ? .move : .copy
        }
        return refuses(drag.paths, parents: drag.parents, destination: destination, operation: operation) ? [] : operation
    }

    /// No drop into an item itself or a folder inside it; moving into the folder the items are in does nothing.
    /// Cheap for thousands of items: a destination can only be inside a source whose path is a prefix of it.
    private static func refuses(_ paths: [String], parents: Set<String>, destination: URL, operation: NSDragOperation) -> Bool {
        refusesOffMain(paths, parents: parents, destination: destination, move: operation == .move)
    }

    nonisolated private static func refusesOffMain(_ paths: [String], parents: Set<String>, destination: URL, move: Bool) -> Bool {
        let target = normalized(destination.path(percentEncoded: false))
        var ancestors: Set<String> = [target]
        var path = target
        while path != "/" && !path.isEmpty {
            path = normalized((path as NSString).deletingLastPathComponent)
            ancestors.insert(path)
        }
        if paths.contains(where: ancestors.contains) { return true }
        return move && parents == [target]
    }

    /// The right-button drag menu's checks (P3-2): copying is refused into an item itself or a folder inside it;
    /// moving too, and into the folder the items are in; `sameVolume`: a left drag would move.
    static func dropChecks(paths: [String], parents: Set<String>, destination: URL, volumes: [Volume]) -> (copy: Bool, move: Bool, sameVolume: Bool) {
        let copy = !refusesOffMain(paths, parents: parents, destination: destination, move: false)
        let move = copy && !refusesOffMain(paths, parents: parents, destination: destination, move: true)
        return (copy, move, sameVolume(parents, destination, volumes))
    }

    private static func sameVolume(_ parents: Set<String>, _ destination: URL, _ volumes: [Volume]) -> Bool {
        func volume(_ path: String) -> URL? {
            volumes.filter { $0.contains(path: path) }.max { $0.url.path.count < $1.url.path.count }?.url
        }
        let target = volume(destination.path(percentEncoded: false))
        return parents.allSatisfy { volume($0) == target } // items dragged together share a few parents
    }

    static func standardized(_ url: URL) -> String { FileListViewController.standardized(url) }

    /// Performs a validated drop through `list`'s copy engine (its window gets the sheets).
    @discardableResult
    static func perform(_ info: any NSDraggingInfo, destination: URL, operation: NSDragOperation, list: FileListViewController) -> Bool {
        let move = operation == .move
        if hasFileURLs(info), !sources(info).complete {
            // A big drag from another app: validation saw the first 100. Read the strings here (pasteboard: main
            // thread), parse and check them all off-main, then hand them to the copy engine.
            let strings = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
            Task {
                let checked: [URL]? = await Task.detached(priority: .userInitiated) {
                    let urls = strings.compactMap(URL.init(string:)).filter(\.isFileURL)
                    let paths = urls.map { normalized($0.path(percentEncoded: false)) }
                    let parents = Set(paths.map { normalized(($0 as NSString).deletingLastPathComponent) })
                    return refusesOffMain(paths, parents: parents, destination: destination, move: move) ? nil : urls
                }.value
                guard let urls = checked, !urls.isEmpty else {
                    list.showMessage("Can’t put a folder inside itself.")
                    return
                }
                list.runCopyEngine(move ? .move : .copy, sources: urls, into: destination, actionName: move ? "Move" : "Copy")
            }
            return true
        }
        let urls = hasFileURLs(info) ? fileURLs(info) : []
        if !urls.isEmpty {
            list.runCopyEngine(move ? .move : .copy, sources: urls, into: destination, actionName: move ? "Move" : "Copy")
            return true
        }
        let receivers = promises(info)
        // Promises can only be received from a real drag (AppKit asserts otherwise).
        guard !receivers.isEmpty, info.draggingPasteboard.name == .drag else { return false }
        receivePromises(receivers, into: destination, list: list)
        return true
    }

    /// File promises are written by the other app into a temporary folder on the destination's volume,
    /// then moved into place by the copy engine (conflicts asked, never overwritten); undo trashes them.
    private static func receivePromises(_ receivers: [NSFilePromiseReceiver], into destination: URL, list: FileListViewController) {
        guard let staging = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: destination, create: true) else {
            list.showMessage("Couldn’t receive the dropped items here.")
            return
        }
        let expected = receivers.reduce(0) { $0 + $1.fileNames.count }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let collector = PromiseCollector(expected: max(expected, receivers.count))
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) { url, error in
                guard let files = collector.add(error == nil ? url : nil) else { return }
                Task { @MainActor in
                    guard !files.isEmpty else {
                        list.showMessage("The dropped items couldn’t be received.")
                        try? FileManager.default.removeItem(at: staging) // empty staging folder of ours
                        return
                    }
                    list.runCopyEngine(.move, sources: files, into: destination, actionName: "Drop", undoAsCreated: true) { _ in
                        // Only ever our own staging folder, and only if it's empty now.
                        rmdir(staging.path(percentEncoded: false))
                    }
                }
            }
        }
    }
}

/// Gathers promised files from the receiver callbacks (any queue); the last one returns the list.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private var remaining: Int

    init(expected: Int) { remaining = expected }

    func add(_ url: URL?) -> [URL]? {
        lock.withLock {
            if let url { files.append(url) }
            remaining -= 1
            return remaining == 0 ? files : nil
        }
    }
}

// MARK: The list as a drop target

extension FileListViewController {
    /// The mounted volumes (for "same volume = move"), from this window's navigation pane.
    var mountedVolumes: [Volume] {
        (view.window?.windowController as? MainWindowController)?.sidebar.volumes ?? []
    }

    /// Where a drop on `row` goes: a folder row → into it; anything else → this folder.
    func dropDestination(row: Int, operation: NSTableView.DropOperation) -> (url: URL, row: Int) {
        if operation == .on, let folder = folderURL(atRow: row) { return (folder, row) }
        return (folder, -1)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isShowingTrash else { return [] } // nothing is added to the Trash view (Move to Trash does that)
        var target = dropDestination(row: row, operation: dropOperation)
        var operation = FileDrop.operation(for: info, destination: target.url, volumes: mountedVolumes)
        if operation.isEmpty, target.row >= 0 { // e.g. a folder dragged onto itself: try this folder instead
            target = (folder, -1)
            operation = FileDrop.operation(for: info, destination: folder, volumes: mountedVolumes)
        }
        guard !operation.isEmpty else { return [] }
        tableView.setDropRow(target.row, dropOperation: .on) // -1: the whole list highlights
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let destination = row >= 0 ? (folderURL(atRow: row) ?? folder) : folder
        let operation = FileDrop.operation(for: info, destination: destination, volumes: mountedVolumes)
        guard !operation.isEmpty else { return false }
        return FileDrop.perform(info, destination: destination, operation: operation, list: self)
    }
}
