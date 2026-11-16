import Darwin
import Foundation
import Synchronization

/// Progress of a copy/move, delivered throttled (≈ every 50 ms) and once at the end.
public struct OperationProgress: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var totalItems: Int = 0
    public var completedItems: Int = 0
    /// Name of the top-level item being processed.
    public var currentName: String = ""
    /// Still counting what to do (before any data moves).
    public var isPreparing = true

    public init() {}

    public var fraction: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes)
            : totalItems > 0 ? Double(completedItems) / Double(totalItems) : 0
    }
}

/// An item that already exists at the destination.
public struct Conflict: Sendable {
    public let source: URL
    public let existing: URL
    public let sourceIsFolder: Bool
    public let existingIsFolder: Bool
}

public enum ConflictResolution: Sendable, Equatable {
    /// Move the existing item to the Trash, then put the new one in its place.
    case replace
    case skip
    /// "name (2).ext", Explorer style.
    case keepBoth
    /// Folder onto folder: put the contents into the existing folder; clashes inside are resolved
    /// one by one (Explorer's default for folders). Treated as `skip` for anything but two folders.
    case merge
    /// Stop the whole operation.
    case stop
}

/// An item that couldn't be copied/moved (the error handler decides what happens next).
public struct ItemFailure: Sendable {
    public let url: URL
    public let error: FileSystemError
}

public enum FailureDecision: Sendable, Equatable {
    /// Try this item again (e.g. after fixing permissions or freeing space).
    case retry
    /// Leave it and carry on (it's reported at the end).
    case skip
    /// Stop the whole operation.
    case stop
}

public struct OperationResult: Sendable {
    public enum Kind: Sendable { case copy, move }
    public var kind: Kind
    /// Top-level items done: where each one ended up.
    public var completed: [(source: URL, destination: URL)] = []
    public var skipped: [URL] = []
    /// Everything that went wrong, per item (the operation carries on where it safely can).
    public var errors: [(url: URL, error: FileSystemError)] = []
    public var cancelled = false
    public var progress = OperationProgress()
    /// Everything that changed on disk, in order (for Undo): each placed item (at any depth —
    /// merges list their children) and each existing item trashed by Replace.
    public var transfers: [Transfer] = []

    public enum Transfer: Sendable {
        /// `source` now (also) exists at `destination`. `moved`: the source is gone (it was moved).
        case placed(source: URL, destination: URL, moved: Bool)
        /// An existing item was moved to the Trash to make room (Replace).
        case replaced(existing: URL, inTrash: URL)
    }
}

/// Copy and move, with progress, cancellation (also inside large files), per-item errors and
/// conflict handling. Never overwrites, never leaves a partial item under its real name.
///
/// - Copy on the same APFS volume: `clonefile(2)` — the whole tree at once, instant, no extra space.
///   Otherwise `copyfile(3)` (COPYFILE_ALL: data, metadata, xattrs, ACLs, tags), recursive.
/// - Each item is copied to a hidden temporary name next to its destination and only renamed
///   into place (`RENAME_EXCL`) once complete; cancel/failure removes just that temporary copy.
/// - Move on the same volume: `renamex_np(RENAME_EXCL)`. Across volumes: copy, verify (item count
///   and bytes), place, then remove the source — and only if the item copied without any error.
/// - Symlinks are copied as symlinks, never followed.
public struct CopyEngine: Sendable {
    public typealias Resolver = @Sendable (Conflict) async -> ConflictResolution
    public typealias ErrorHandler = @Sendable (ItemFailure) async -> FailureDecision

    public let kind: OperationResult.Kind
    public let sources: [URL]
    public let destination: URL
    public var trasher: any Trasher
    public var resolver: Resolver
    /// Asked when an item fails: retry / skip / stop. Default: skip (and report at the end).
    public var errorHandler: ErrorHandler = { _ in .skip }
    /// Use `clonefile` where possible. Off only for measurements/tests of the real copy path.
    public var allowClone = true
    /// Minimum time between progress reports (cancellation is checked on every chunk regardless).
    var progressInterval: Duration = .milliseconds(50)

    /// Default conflict policy until the conflict dialog exists: skip (and report), never overwrite.
    public static let skipConflicts: Resolver = { _ in .skip }

    public init(kind: OperationResult.Kind, sources: [URL], destination: URL,
                trasher: any Trasher = SystemTrasher(), resolver: @escaping Resolver = CopyEngine.skipConflicts) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.trasher = trasher
        self.resolver = resolver
    }

    /// Runs the operation on the file-operations queue. Cancelling the calling task cancels it.
    public func run(progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }) async -> OperationResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                FileOperationQueue.queue.async {
                    continuation.resume(returning: self.runBlocking(cancel: flag, progress: progress))
                }
            }
        } onCancel: { flag.cancel() }
    }

    // MARK: Implementation (blocking)

    func runBlocking(cancel: CancellationFlag, progress report: @escaping @Sendable (OperationProgress) -> Void) -> OperationResult {
        let signpost = Signposts.fileOps.beginInterval(kind == .copy ? "Copy" : "Move", "\(sources.count) items")
        defer { Signposts.fileOps.endInterval(kind == .copy ? "Copy" : "Move", signpost) }
        var result = OperationResult(kind: kind)
        let reporter = ProgressReporter(report, interval: progressInterval)

        // 1. Plan: count items and bytes (no symlink following), so progress means something.
        var plans: [(source: URL, items: Int, bytes: Int64)] = []
        for source in sources {
            if cancel.isCancelled { break }
            switch Self.measure(source, cancel: cancel) {
            case .success(let m):
                plans.append((source, m.items, m.bytes))
                result.progress.totalItems += m.items
                result.progress.totalBytes += m.bytes
            case .failure(let e):
                result.errors.append((source, e))
            }
            reporter.update(result.progress)
        }
        result.progress.isPreparing = false
        reporter.update(result.progress, force: true)

        // 2. Do it, item by item.
        let destinationPath = Self.trimmed(destination.path(percentEncoded: false))
        for plan in plans {
            if cancel.isCancelled { result.cancelled = true; break }
            let source = plan.source
            let sourcePath = Self.trimmed(source.path(percentEncoded: false))
            let name = (sourcePath as NSString).lastPathComponent
            result.progress.currentName = name
            reporter.update(result.progress, force: true)
            let sameFolder = destinationPath == (sourcePath as NSString).deletingLastPathComponent

            if kind == .move, sameFolder { result.skipped.append(source); continue } // moving onto itself: nothing to do
            if kind == .move || isFolder(sourcePath), destinationPath.hasPrefix(sourcePath + "/") || destinationPath == sourcePath {
                result.errors.append((source, FileSystemError(.other("A folder can’t be \(kind == .move ? "moved" : "copied") into itself"), path: sourcePath)))
                continue
            }
            // Same-folder copy gets "name - Copy" (Explorer); otherwise clashes go to the resolver.
            let targetName = sameFolder && kind == .copy ? Self.copyName(name, in: destinationPath) : name
            switch transfer(sourcePath, into: destinationPath, name: targetName, plan: (plan.items, plan.bytes),
                            result: &result, cancel: cancel, reporter: reporter) {
            case .done(let target): result.completed.append((source, URL(filePath: target)))
            case .stopped: result.cancelled = true
            case .skipped, .failed: break
            }
            if result.cancelled { break }
        }
        reporter.update(result.progress, force: true)
        return result
    }

    enum TransferStatus: Equatable {
        case done(String)
        case skipped
        case failed
        case stopped
    }

    /// `transferOnce`, asking the error handler when the item fails: retry discards the failed
    /// attempt (its errors and progress) and tries again; skip/stop as the names say.
    func transfer(_ sourcePath: String, into dir: String, name: String, plan: (items: Int, bytes: Int64),
                  result: inout OperationResult, cancel: CancellationFlag, reporter: ProgressReporter) -> TransferStatus {
        while true {
            let progressBefore = result.progress, errorsBefore = result.errors.count, skippedBefore = result.skipped.count
            let status = transferOnce(sourcePath, into: dir, name: name, plan: plan, result: &result, cancel: cancel, reporter: reporter)
            guard status == .failed, result.errors.count > errorsBefore, !cancel.isCancelled else { return status }
            let first = result.errors[errorsBefore]
            let handler = errorHandler
            let failure = ItemFailure(url: first.url, error: first.error)
            switch Self.wait({ await handler(failure) }, default: .skip) {
            case .retry:
                result.errors.removeSubrange(errorsBefore...)
                result.skipped.removeSubrange(skippedBefore...)
                result.progress = progressBefore
                reporter.update(result.progress, force: true)
            case .skip:
                return .failed
            case .stop:
                return .stopped
            }
        }
    }

    /// Copies or moves one item into `dir` under `name`, resolving a clash with the resolver
    /// (and merging folders recursively). Records progress, skips and errors in `result`.
    func transferOnce(_ sourcePath: String, into dir: String, name: String, plan: (items: Int, bytes: Int64),
                      result: inout OperationResult, cancel: CancellationFlag, reporter: ProgressReporter) -> TransferStatus {
        let source = URL(filePath: sourcePath)
        var targetPath = (dir as NSString).appendingPathComponent(name)
        func countAsDone() {
            result.progress.completedItems += plan.items
            result.progress.completedBytes += plan.bytes
            reporter.update(result.progress)
        }

        if Self.exists(targetPath) {
            let sourceIsFolder = isFolder(sourcePath), existingIsFolder = isFolder(targetPath)
            let conflict = Conflict(source: source, existing: URL(filePath: targetPath),
                                    sourceIsFolder: sourceIsFolder, existingIsFolder: existingIsFolder)
            let resolver = self.resolver
            var decision = Self.wait({ await resolver(conflict) }, default: .skip)
            if decision == .merge && !(sourceIsFolder && existingIsFolder) { decision = .skip }
            switch decision {
            case .skip:
                result.skipped.append(source)
                result.errors.append((source, FileSystemError(.other("An item with this name already exists in the destination"), path: targetPath)))
                countAsDone()
                return .skipped
            case .stop:
                return .stopped
            case .keepBoth:
                targetPath = (dir as NSString).appendingPathComponent(Self.numberedName(name, in: dir))
            case .replace:
                // Never trash a folder that contains what we're about to put there.
                if sourcePath.hasPrefix(Self.trimmed(targetPath) + "/") {
                    result.errors.append((source, FileSystemError(.other("Can’t replace a folder that contains the item being \(kind == .move ? "moved" : "copied")"), path: targetPath)))
                    countAsDone()
                    return .failed
                }
                do {
                    let inTrash = try trasher.trash(URL(filePath: targetPath)) // never a permanent delete
                    result.transfers.append(.replaced(existing: URL(filePath: targetPath), inTrash: inTrash))
                } catch {
                    result.errors.append((source, FileSystemError(foundation: error, path: targetPath)))
                    countAsDone()
                    return .failed
                }
            case .merge:
                return mergeFolder(sourcePath, into: targetPath, result: &result, cancel: cancel, reporter: reporter)
            }
        }

        // Same-volume move: a single atomic rename.
        if kind == .move {
            if renamex_np(sourcePath, targetPath, UInt32(RENAME_EXCL)) == 0 {
                result.transfers.append(.placed(source: source, destination: URL(filePath: targetPath), moved: true))
                countAsDone()
                return .done(targetPath)
            }
            guard errno == EXDEV else {
                result.errors.append((source, FileSystemError(errno: errno, path: sourcePath)))
                countAsDone()
                return .failed
            }
            // Different volume: copy + verify + remove below.
        }

        let outcome = copyItem(sourcePath, to: targetPath, plan: plan, cancel: cancel, progress: &result.progress, reporter: reporter)
        result.errors.append(contentsOf: outcome.errors)
        if outcome.cancelled { return .stopped }
        guard outcome.placed else { return .failed }

        var sourceRemoved = false
        if kind == .move {
            // Cross-volume move: the source goes only if everything copied and the copy checks out.
            guard outcome.errors.isEmpty else {
                result.errors.append((source, FileSystemError(.other("Some files couldn’t be copied, so the original was kept"), path: sourcePath)))
                result.transfers.append(.placed(source: source, destination: URL(filePath: targetPath), moved: false))
                return .done(targetPath)
            }
            switch Self.measure(URL(filePath: targetPath), cancel: CancellationFlag()) {
            case .success(let copied) where copied.items == plan.items && copied.bytes == plan.bytes:
                if let removeError = Self.removeTree(sourcePath) {
                    result.errors.append((source, removeError)) // both copies exist: nothing lost
                } else {
                    sourceRemoved = true
                }
            default:
                result.errors.append((source, FileSystemError(.other("The copy didn’t match the original, so the original was kept"), path: sourcePath)))
            }
        }
        // Undo treats a move whose original was kept as a copy (undo = trash the copy).
        result.transfers.append(.placed(source: source, destination: URL(filePath: targetPath), moved: sourceRemoved))
        return .done(targetPath)
    }

    /// Folder onto folder: transfers each child into the existing folder (clashes go to the
    /// resolver again, so nested folders merge too). After a move, the source folder is removed
    /// only if it ended up empty (`rmdir` refuses otherwise) — skipped items stay where they were.
    private func mergeFolder(_ sourcePath: String, into existing: String, result: inout OperationResult,
                             cancel: CancellationFlag, reporter: ProgressReporter) -> TransferStatus {
        let children: [String]
        do {
            children = try FileManager.default.contentsOfDirectory(atPath: sourcePath).sorted()
        } catch {
            result.errors.append((URL(filePath: sourcePath), FileSystemError(foundation: error, path: sourcePath)))
            return .failed
        }
        var everythingMoved = true
        for child in children {
            if cancel.isCancelled { return .stopped }
            let childPath = (sourcePath as NSString).appendingPathComponent(child)
            let childPlan = (try? Self.measure(URL(filePath: childPath), cancel: cancel).get()) ?? (1, 0)
            switch transfer(childPath, into: existing, name: child, plan: childPlan, result: &result, cancel: cancel, reporter: reporter) {
            case .stopped: return .stopped
            case .done: break
            case .skipped, .failed: everythingMoved = false
            }
        }
        if kind == .move && everythingMoved && rmdir(sourcePath) != 0 && errno != ENOTEMPTY {
            result.errors.append((URL(filePath: sourcePath), FileSystemError(errno: errno, path: sourcePath)))
        }
        result.progress.completedItems += 1 // the folder itself
        reporter.update(result.progress)
        return .done(existing)
    }

    private struct CopyOutcome {
        var placed = false
        var cancelled = false
        var errors: [(url: URL, error: FileSystemError)] = []
    }

    /// Copies one top-level item to a temporary name, then renames it into place.
    private func copyItem(_ source: String, to target: String, plan: (items: Int, bytes: Int64), cancel: CancellationFlag,
                          progress: inout OperationProgress, reporter: ProgressReporter) -> CopyOutcome {
        var outcome = CopyOutcome()
        let parent = (target as NSString).deletingLastPathComponent
        let temporary = (parent as NSString).appendingPathComponent(".kansio-partial-\(UUID().uuidString)-\((target as NSString).lastPathComponent)")
        let startBytes = progress.completedBytes
        let startItems = progress.completedItems

        // Same APFS volume: clone the whole item at once. Any failure (other volume, not APFS…)
        // falls back to copyfile, which reports the precise error if there is one.
        var copied = allowClone && clonefile(source, temporary, UInt32(CLONE_NOFOLLOW)) == 0
        if !copied {
            let context = CopyContext(cancel: cancel, reporter: reporter, base: progress)
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            let unmanaged = Unmanaged.passRetained(context)
            defer { unmanaged.release() }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
            let rc = copyfile(source, temporary, state, flags)
            let err = errno
            progress = context.progress
            if rc != 0 {
                // A hard failure (or cancel): never place a partial copy.
                _ = Self.removeTree(temporary)
                if cancel.isCancelled || err == ECANCELED {
                    outcome.cancelled = true
                    return outcome
                }
                outcome.errors = context.errors.isEmpty ? [(URL(filePath: source), FileSystemError(errno: err, path: source))] : context.errors
                progress.completedItems = startItems + plan.items
                return outcome
            }
            // Finished, possibly with individual files skipped (listed in errors).
            outcome.errors = context.errors
            // A single file whose only file was skipped produces nothing: report just the real
            // error, don't try to place a copy that doesn't exist.
            guard Self.exists(temporary) else {
                if outcome.errors.isEmpty { outcome.errors = [(URL(filePath: source), FileSystemError(.other("Nothing could be copied"), path: source))] }
                progress.completedItems = startItems + plan.items
                return outcome
            }
            copied = true
        }
        // Place it. RENAME_EXCL: if something appeared at the target meanwhile, don't replace it.
        if renamex_np(temporary, target, UInt32(RENAME_EXCL)) == 0 {
            outcome.placed = true
        } else {
            outcome.errors.append((URL(filePath: source), FileSystemError(errno: errno, path: target)))
            _ = Self.removeTree(temporary)
        }
        progress.completedItems = startItems + plan.items
        progress.completedBytes = max(progress.completedBytes, startBytes + plan.bytes)
        reporter.update(progress)
        return outcome
    }

    // MARK: Helpers

    private func isFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Items and bytes in a tree (lstat; symlinks counted, never followed).
    static func measure(_ url: URL, cancel: CancellationFlag) -> Result<(items: Int, bytes: Int64), FileSystemError> {
        let path = trimmed(url.path(percentEncoded: false))
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(FileSystemError(errno: errno, path: path)) }
        guard st.st_mode & S_IFMT == S_IFDIR else { return .success((1, st.st_mode & S_IFMT == S_IFREG ? Int64(st.st_size) : 0)) }
        var items = 1
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: URL(filePath: path, directoryHint: .isDirectory),
                                                        includingPropertiesForKeys: [.isRegularFileKey, .totalFileSizeKey], options: [])
        while let child = enumerator?.nextObject() as? URL {
            if cancel.isCancelled { break }
            items += 1
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .totalFileSizeKey])
            if values?.isRegularFile == true { bytes += Int64(values?.totalFileSize ?? 0) }
        }
        return .success((items, bytes))
    }

    /// "Report - Copy.txt", "Report - Copy (2).txt" — Explorer's names for a copy in the same folder.
    static func copyName(_ name: String, in folder: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty || name.hasPrefix(".") && ns.deletingPathExtension.isEmpty ? name : ns.deletingPathExtension
        let suffix = ext.isEmpty || base == name ? "" : "." + ext
        for n in 1...10_000 {
            let candidate = "\(base) - Copy\(n > 1 ? " (\(n))" : "")\(suffix)"
            if !exists((folder as NSString).appendingPathComponent(candidate)) { return candidate }
        }
        return "\(base) - Copy \(UUID().uuidString)\(suffix)"
    }

    /// "name (2).ext", "name (3).ext"… — the first that's free.
    static func numberedName(_ name: String, in folder: String) -> String {
        for n in 2...10_000 {
            let candidate = FileNames.numbered(name, n)
            if !exists((folder as NSString).appendingPathComponent(candidate)) { return candidate }
        }
        return FileNames.numbered(name, Int.random(in: 10_001...99_999))
    }

    /// Removes a tree we created (a partial copy) or a moved-away source. Only ever called on
    /// paths this engine produced, or on a move's source after its copy was verified.
    static func removeTree(_ path: String) -> FileSystemError? {
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            return FileSystemError(foundation: error, path: path)
        }
    }

    /// Bridges an async question (conflict resolver, error handler) into this blocking thread
    /// (a GCD thread, not the cooperative pool).
    static func wait<T: Sendable>(_ ask: @escaping @Sendable () async -> T, default fallback: T) -> T {
        let box = Mutex<T>(fallback)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let answer = await ask()
            box.withLock { $0 = answer }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0 }
    }
}


enum FileOperationQueue {
    /// Separate from listing so a long copy never delays showing a folder.
    static let queue = DispatchQueue(label: "kansio.fileops", qos: .userInitiated, attributes: .concurrent)
}

/// Throttles progress callbacks to ~20 per second.
final class ProgressReporter: @unchecked Sendable {
    private let callback: @Sendable (OperationProgress) -> Void
    private let interval: Duration
    private let lock = NSLock()
    private var lastTime = ContinuousClock.now - .seconds(1)
    private(set) var last = OperationProgress()

    init(_ callback: @escaping @Sendable (OperationProgress) -> Void, interval: Duration = .milliseconds(50)) {
        self.callback = callback
        self.interval = interval
    }

    func update(_ progress: OperationProgress, force: Bool = false) {
        lock.lock()
        last = progress
        let now = ContinuousClock.now
        let due = force || now - lastTime >= interval
        if due { lastTime = now }
        lock.unlock()
        if due { callback(progress) }
    }
}

/// State shared with the C copyfile callback (one per copyfile call, single thread).
final class CopyContext {
    let cancel: CancellationFlag
    let reporter: ProgressReporter
    var progress: OperationProgress
    let baseBytes: Int64
    var finishedFileBytes: Int64 = 0
    var errors: [(url: URL, error: FileSystemError)] = []

    init(cancel: CancellationFlag, reporter: ProgressReporter, base: OperationProgress) {
        self.cancel = cancel
        self.reporter = reporter
        self.progress = base
        self.baseBytes = base.completedBytes
    }
}

/// copyfile(3) status callback: progress, per-file errors (skip and continue), cancellation.
private let copyCallback: @convention(c) (Int32, Int32, copyfile_state_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = {
    what, stage, state, src, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if context.cancel.isCancelled { return COPYFILE_QUIT }
    switch (what, stage) {
    case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.progress.completedBytes = context.baseBytes + context.finishedFileBytes + Int64(copied)
        context.reporter.update(context.progress)
    case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
        if let src {
            var st = stat()
            if lstat(src, &st) == 0, st.st_mode & S_IFMT == S_IFREG { context.finishedFileBytes += Int64(st.st_size) }
        }
        context.progress.completedBytes = context.baseBytes + context.finishedFileBytes
        context.progress.completedItems += 1
        context.reporter.update(context.progress)
    case (COPYFILE_RECURSE_DIR, COPYFILE_FINISH):
        context.progress.completedItems += 1
    case (_, COPYFILE_ERR):
        let path = src.map { String(cString: $0) } ?? "?"
        // copyfile can report one file from two stages (open, data): count it once.
        if context.errors.last?.url.path(percentEncoded: false) != path {
            context.errors.append((URL(filePath: path), FileSystemError(errno: errno, path: path)))
        }
        return COPYFILE_SKIP // carry on with the rest; reported at the end
    default:
        break
    }
    return COPYFILE_CONTINUE
}
