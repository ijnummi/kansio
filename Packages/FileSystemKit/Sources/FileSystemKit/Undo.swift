import Darwin
import Foundation
import Synchronization

/// Where an item went in the Trash — filled in when it's trashed, read when it's put back.
/// A box because Undo/Redo registration is synchronous while the file work happens later.
public final class TrashSlot: Sendable {
    private let url = Mutex<URL?>(nil)
    public init(_ initial: URL? = nil) { url.withLock { $0 = initial } }
    public var location: URL? {
        get { url.withLock { $0 } }
        set { url.withLock { $0 = newValue } }
    }
}

/// One change on disk, described so it can be done again (redo) or reversed (undo).
public enum FileChange: Sendable {
    /// Same folder, new name.
    case renamed(from: URL, to: URL)
    /// The item came into existence at `url` (new folder/file, a copy). Performing it again
    /// takes it back out of the Trash slot; reversing it moves it *to the Trash* (never deletes).
    case created(URL, slot: TrashSlot)
    /// The item at `original` went to the Trash (location in `slot`).
    case trashed(original: URL, slot: TrashSlot)
    case moved(from: URL, to: URL)

    /// The change that undoes this one.
    public var inverse: FileChange {
        switch self {
        case .renamed(let from, let to): .renamed(from: to, to: from)
        case .created(let url, let slot): .trashed(original: url, slot: slot)
        case .trashed(let original, let slot): .created(original, slot: slot)
        case .moved(let from, let to): .moved(from: to, to: from)
        }
    }

    /// Paths this change touches (to refresh the views showing them).
    public var affectedURLs: [URL] {
        switch self {
        case .renamed(let a, let b), .moved(let a, let b): [a, b]
        case .created(let url, _): [url]
        case .trashed(let original, _): [original]
        }
    }
}

/// A user-level action ("Rename", "Move to Trash", "Copy"…) made of file changes in order.
public struct UndoStep: Sendable {
    public var changes: [FileChange]
    public var actionName: String

    public init(_ actionName: String, _ changes: [FileChange]) {
        self.actionName = actionName
        self.changes = changes
    }

    /// Reversed order, each change inverted.
    public var inverse: UndoStep { UndoStep(actionName, changes.reversed().map(\.inverse)) }
    public var affectedURLs: [URL] { changes.flatMap(\.affectedURLs) }

    /// The step for a finished copy/move (copies are "created", moves "moved", Replace "trashed").
    public init(_ actionName: String, result: OperationResult) {
        self.actionName = actionName
        changes = result.transfers.map { transfer in
            switch transfer {
            case .placed(let source, let destination, let moved):
                moved ? .moved(from: source, to: destination) : .created(destination, slot: TrashSlot())
            case .replaced(let existing, let inTrash):
                .trashed(original: existing, slot: TrashSlot(inTrash))
            }
        }
    }
}

/// Performs steps (forward = redo, `step.inverse` = undo) one at a time, in order, off the main
/// thread. Every change is applied best-effort; problems are returned, never thrown away.
public actor UndoPerformer {
    public init() {}

    public func perform(_ step: UndoStep, trasher: any Trasher) async -> [(url: URL, error: FileSystemError)] {
        var errors: [(URL, FileSystemError)] = []
        for change in step.changes {
            if let error = await apply(change, trasher: trasher) { errors.append(error) }
        }
        return errors
    }

    private func apply(_ change: FileChange, trasher: any Trasher) async -> (URL, FileSystemError)? {
        switch change {
        case .renamed(let from, let to):
            let result = await FileOperations.rename(from, to: to.lastPathComponent)
            if case .failure(let e) = result { return (from, Self.fileError(e, path: from)) }
            return nil

        case .trashed(let original, let slot):
            let outcome = await FileOperations.trash([original], using: trasher)
            if let failure = outcome.failed.first { return (original, failure.error) }
            slot.location = outcome.trashed.first?.inTrash
            return nil

        case .created(let url, let slot):
            // Put back from the Trash.
            guard let inTrash = slot.location else {
                return (url, FileSystemError(.other("Its place in the Trash isn’t known"), path: url.path(percentEncoded: false)))
            }
            return await Self.place(inTrash, at: url, missingMessage: "It’s no longer in the Trash")

        case .moved(let from, let to):
            return await Self.place(from, at: to, missingMessage: "It no longer exists")
        }
    }

    /// Moves `source` to exactly `target` (recreating the target's folder if a merge removed it),
    /// never replacing anything; across volumes via the copy engine (copy + verify + remove).
    static func place(_ source: URL, at target: URL, missingMessage: String) async -> (URL, FileSystemError)? {
        enum Local: Sendable { case done, failed(URL, FileSystemError), otherVolume }
        let from = source.path(percentEncoded: false), to = target.path(percentEncoded: false)
        let local: Local = await runOnListingQueue {
            var st = stat()
            guard lstat(from, &st) == 0 else { return .failed(target, FileSystemError(.other(missingMessage), path: from)) }
            if lstat(to, &st) == 0 {
                return .failed(target, FileSystemError(.other("An item named “\(target.lastPathComponent)” is in the way"), path: to))
            }
            try? FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let err = ExclusiveRename.rename(from, to)
            if err == 0 { return .done }
            return err == EXDEV ? .otherVolume : .failed(target, FileSystemError(errno: err, path: from))
        }
        switch local {
        case .done: return nil
        case .failed(let url, let error): return (url, error)
        case .otherVolume: return await crossVolumePlace(source, at: target)
        }
    }

    private static func crossVolumePlace(_ source: URL, at target: URL) async -> (URL, FileSystemError)? {
        // Only reached for EXDEV: move across volumes, then fix the name if it differs.
        let parent = target.deletingLastPathComponent()
        let result = await CopyEngine(kind: .move, sources: [source], destination: parent).run()
        guard let placed = result.completed.first?.destination else {
            return result.errors.first.map { ($0.url, $0.error) } ?? (target, FileSystemError(.other("Couldn’t move it back"), path: target.path(percentEncoded: false)))
        }
        if placed.lastPathComponent != target.lastPathComponent,
           case .failure(let e) = await FileOperations.rename(placed, to: target.lastPathComponent) {
            return (target, fileError(e, path: placed))
        }
        return result.errors.first.map { ($0.url, $0.error) }
    }

    static func fileError(_ e: FileOperations.RenameError, path: URL) -> FileSystemError {
        switch e {
        case .failed(let f): f
        default: FileSystemError(.other(e.description), path: path.path(percentEncoded: false))
        }
    }
}
