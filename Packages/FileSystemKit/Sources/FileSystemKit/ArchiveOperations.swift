import Darwin
import Foundation

/// Compress and Extract as file operations (P2-3): progress, cancel, nothing half-made, never overwriting.
///
/// - Compress writes to a hidden temporary name (".kansio-partial-…") in the destination and renames it into place
///   only when complete ("Photos.7z", or "Photos (2).7z" if taken). "Compress into" also re-reads the finished
///   archive and checks it holds every file and folder with the right sizes; only then may the caller trash the originals.
/// - Extract unpacks into a hidden temporary folder in the destination, then moves the result into place: the items
///   themselves (Extract here; clashes go to the conflict resolver, Replace = Trash), or the temporary folder renamed
///   ("Extract as": "Photos", "Photos (2)"…). Cancel or failure removes the temporary folder — only ever ours.
public struct ArchiveOperations: Sendable {
    /// Tried in order: when the first can't open an archive (unsupported or damaged), the next one tries.
    public var engines: [any ArchiveEngine]
    public var trasher: any Trasher
    public var resolver: CopyEngine.Resolver

    public init(engines: [any ArchiveEngine], trasher: any Trasher = SystemTrasher(),
                resolver: @escaping CopyEngine.Resolver = CopyEngine.skipConflicts) {
        self.engines = engines
        self.trasher = trasher
        self.resolver = resolver
    }

    // MARK: Compress

    public struct CompressResult: Sendable {
        /// The finished archive (nil: nothing was made).
        public var archive: URL?
        public var error: FileSystemError?
        public var cancelled = false
    }

    /// Compresses `items` (all in one folder) into `folder/name` (".7z"/".zip" included in `name`; a free name is
    /// chosen if it's taken by then). `verify`: list the result and check it against the originals.
    public func compress(_ items: [URL], name: String, format: ArchiveFormat, level: ArchiveLevel, verify: Bool,
                         progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }) async -> CompressResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                FileOperationQueue.queue.async {
                    continuation.resume(returning: self.compressBlocking(items, name: name, format: format, level: level,
                                                                        verify: verify, cancel: flag, progress: progress))
                }
            }
        } onCancel: { flag.cancel() }
    }

    func compressBlocking(_ items: [URL], name: String, format: ArchiveFormat, level: ArchiveLevel, verify: Bool,
                          cancel: CancellationFlag, progress report: @escaping @Sendable (OperationProgress) -> Void) -> CompressResult {
        var result = CompressResult()
        guard let first = items.first, let engine = engines.first else {
            result.error = FileSystemError(.other("Nothing to compress"), path: "")
            return result
        }
        let signpost = Signposts.fileOps.beginInterval("Compress", "\(items.count) items")
        defer { Signposts.fileOps.endInterval("Compress", signpost) }
        let folder = first.deletingLastPathComponent()
        let folderPath = CopyEngine.trimmed(folder.path(percentEncoded: false))
        let names = items.map(\.lastPathComponent)
        var progress = OperationProgress()
        progress.currentName = name
        report(progress)
        let tree = ArchiveSource.scan(base: folder, items: names, cancel: cancel)
        progress.totalItems = tree.items
        progress.totalBytes = tree.bytes
        progress.isPreparing = false
        report(progress)

        let temporary = (folderPath as NSString).appendingPathComponent(".kansio-partial-\(UUID().uuidString)-\(name)")
        let reporter = ProgressReporter(report, interval: .milliseconds(50))
        let total = progress
        do throws(FileSystemError) {
            try engine.create(URL(filePath: temporary), base: folder, items: names, format: format, level: level, cancel: cancel) { fraction in
                var p = total
                p.completedBytes = Int64(Double(total.totalBytes) * fraction)
                p.completedItems = Int(Double(total.totalItems) * fraction)
                reporter.update(p)
            }
            if cancel.isCancelled { throw archiveCancelled }
            if verify {
                let entries = try engine.list(URL(filePath: temporary), cancel: cancel)
                if let problem = ArchiveSource.mismatch(tree, entries) {
                    throw ArchiveError.verifyFailed(first.path(percentEncoded: false), problem)
                }
            }
        } catch {
            _ = CopyEngine.removeTree(temporary) // our partial archive only
            if cancel.isCancelled || error == archiveCancelled { result.cancelled = true } else { result.error = error }
            return result
        }
        // Place it under a name that's free (RENAME_EXCL: never replaces).
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for attempt in 0..<100 {
            let candidate = attempt == 0 && !CopyEngine.exists((folderPath as NSString).appendingPathComponent(name))
                ? name : ArchiveNames.freeName(base, extension: ext.isEmpty ? nil : ext, in: folderPath)
            let target = (folderPath as NSString).appendingPathComponent(candidate)
            let err = ExclusiveRename.rename(temporary, target)
            if err == 0 {
                result.archive = URL(filePath: target)
                break
            }
            if err != EEXIST && err != ENOTEMPTY {
                result.error = FileSystemError(errno: err, path: target)
                break
            }
        }
        if result.archive == nil {
            _ = CopyEngine.removeTree(temporary)
            if result.error == nil { result.error = FileSystemError(.other("Couldn’t find a free name"), path: folderPath) }
        }
        progress.completedBytes = progress.totalBytes
        progress.completedItems = progress.totalItems
        reporter.update(progress, force: true)
        return result
    }

    // MARK: Extract

    public enum ExtractMode: Sendable, Equatable {
        /// The archive's items go straight into the destination.
        case here
        /// Each archive into a new folder named after it — unless the archive is a single top-level folder, which
        /// then goes straight into the destination (no folder in a folder).
        case asFolder
        /// Several archives: every file into one new folder `name`, their folders left out. Checked first: each
        /// archive must keep all its files in one folder.
        case flat(name: String)
    }

    public struct ExtractResult: Sendable {
        /// What appeared (top-level items, and items a merge placed inside existing folders): undo trashes these.
        public var created: [URL] = []
        /// Existing items moved to the Trash by Replace.
        public var replaced: [(existing: URL, inTrash: URL)] = []
        public var errors: [(url: URL, error: FileSystemError)] = []
        public var skipped: [URL] = []
        public var cancelled = false
        public init() {}
    }

    public func extract(_ archives: [URL], mode: ExtractMode, into destination: URL,
                        progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }) async -> ExtractResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                FileOperationQueue.queue.async {
                    continuation.resume(returning: self.extractBlocking(archives, mode: mode, into: destination, cancel: flag, progress: progress))
                }
            }
        } onCancel: { flag.cancel() }
    }

    func extractBlocking(_ archives: [URL], mode: ExtractMode, into destination: URL, cancel: CancellationFlag,
                         progress report: @escaping @Sendable (OperationProgress) -> Void) -> ExtractResult {
        let signpost = Signposts.fileOps.beginInterval("Extract", "\(archives.count) archives")
        defer { Signposts.fileOps.endInterval("Extract", signpost) }
        var result = ExtractResult()
        let destPath = CopyEngine.trimmed(destination.path(percentEncoded: false))
        let reporter = ProgressReporter(report, interval: .milliseconds(50))
        var progress = OperationProgress()
        let sizes = archives.map { url -> Int64 in
            var st = stat()
            return stat(url.path(percentEncoded: false), &st) == 0 ? Int64(st.st_size) : 0
        }
        progress.totalBytes = sizes.reduce(0, +)
        progress.totalItems = archives.count

        // Flat: check every archive's layout before anything is written.
        var flatFolders: [URL: String] = [:]
        if case .flat = mode {
            for archive in archives {
                if cancel.isCancelled { result.cancelled = true; return result }
                progress.currentName = archive.lastPathComponent
                reporter.update(progress, force: true)
                do throws(FileSystemError) {
                    let layout = ArchiveLayout(try listWithFallback(archive, cancel: cancel))
                    if layout.isEncrypted { throw ArchiveError.encrypted(archive.path(percentEncoded: false)) }
                    guard let folder = layout.filesFolder else { throw ArchiveError.notFlat(archive.path(percentEncoded: false)) }
                    flatFolders[archive] = folder
                } catch {
                    if error == archiveCancelled { result.cancelled = true } else { result.errors.append((archive, error)) }
                    return result
                }
            }
        }
        progress.isPreparing = false
        reporter.update(progress, force: true)

        // Flat: everything gathers in one temporary folder, renamed into place at the end.
        var flatTemp: String?
        if case .flat = mode {
            let temp = (destPath as NSString).appendingPathComponent(".kansio-partial-\(UUID().uuidString)")
            if mkdir(temp, 0o755) != 0 {
                result.errors.append((destination, FileSystemError(errno: errno, path: temp)))
                return result
            }
            flatTemp = temp
        }

        var doneBytes: Int64 = 0
        for (index, archive) in archives.enumerated() {
            if cancel.isCancelled { result.cancelled = true; break }
            progress.currentName = archive.lastPathComponent
            reporter.update(progress, force: true)
            let temp = (destPath as NSString).appendingPathComponent(".kansio-partial-\(UUID().uuidString)")
            defer { if CopyEngine.exists(temp) { _ = CopyEngine.removeTree(temp) } } // only our temporary folder
            if mkdir(temp, 0o755) != 0 {
                result.errors.append((archive, FileSystemError(errno: errno, path: temp)))
                continue
            }
            let base = progress, size = sizes[index], before = doneBytes
            do throws(FileSystemError) {
                try extractWithFallback(archive, into: URL(filePath: temp), cancel: cancel) { fraction in
                    var p = base
                    p.completedBytes = before + Int64(Double(size) * fraction)
                    reporter.update(p)
                }
            } catch {
                if error == archiveCancelled || cancel.isCancelled { result.cancelled = true; break }
                result.errors.append((archive, error))
                continue
            }
            doneBytes += size
            progress.completedBytes = doneBytes
            reporter.update(progress, force: true)

            let children = ((try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []).sorted()
            if children.isEmpty { continue } // an empty archive: nothing to place
            switch mode {
            case .here:
                place(children.map { (temp as NSString).appendingPathComponent($0) }, into: destPath, result: &result, cancel: cancel)
            case .asFolder:
                var isDir: ObjCBool = false
                let single = children.count == 1
                    && FileManager.default.fileExists(atPath: (temp as NSString).appendingPathComponent(children[0]), isDirectory: &isDir)
                    && isDir.boolValue && !isSymlink((temp as NSString).appendingPathComponent(children[0]))
                if single {
                    place([(temp as NSString).appendingPathComponent(children[0])], into: destPath, result: &result, cancel: cancel)
                } else if let folder = rename(temp, toFreeName: ArchiveNames.baseName(archive.lastPathComponent), in: destPath, result: &result, for: archive) {
                    result.created.append(URL(filePath: folder))
                }
            case .flat:
                guard let flatTemp else { break }
                let inner = flatFolders[archive] ?? ""
                let filesDir = inner.isEmpty ? temp : (temp as NSString).appendingPathComponent(inner)
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: filesDir)) ?? []).sorted()
                    .map { (filesDir as NSString).appendingPathComponent($0) }
                    .filter { !isFolder($0) } // the archive's (empty) folders are left out
                var inside = ExtractResult()
                place(files, into: flatTemp, result: &inside, cancel: cancel)
                result.errors += inside.errors
                result.skipped += inside.skipped
                result.replaced += inside.replaced // earlier files of this same extract
                if inside.cancelled { result.cancelled = true }
            }
            progress.completedItems = index + 1
            reporter.update(progress, force: true)
            if result.cancelled { break }
        }

        if let flatTemp, case .flat(let name) = mode {
            if result.cancelled {
                _ = CopyEngine.removeTree(flatTemp)
            } else if let folder = rename(flatTemp, toFreeName: name, in: destPath, result: &result, for: destination) {
                result.created.append(URL(filePath: folder))
            } else {
                _ = CopyEngine.removeTree(flatTemp)
            }
            // A flat folder's Replace only ever trashed items of this extract: nothing to restore on undo.
            result.replaced = []
        }
        reporter.update(progress, force: true)
        return result
    }

    /// Moves extracted items into `dir` (same volume: renames), asking the resolver about clashes.
    func place(_ paths: [String], into dir: String, result: inout ExtractResult, cancel: CancellationFlag) {
        guard !paths.isEmpty else { return }
        let engine = CopyEngine(kind: .move, sources: paths.map { URL(filePath: $0) }, destination: URL(filePath: dir),
                                trasher: trasher, resolver: resolver)
        let moved = engine.runBlocking(cancel: cancel) { _ in }
        if moved.cancelled { result.cancelled = true }
        for transfer in moved.transfers {
            switch transfer {
            case .placed(_, let destination, _):
                // Includes what a merge placed inside an existing folder (undo trashes exactly those).
                result.created.append(destination)
            case .replaced(let existing, let inTrash):
                result.replaced.append((existing, inTrash))
            }
        }
        result.errors += moved.errors
        result.skipped += moved.skipped
    }

    /// Renames `path` to a free name based on `name` in `dir`. Nil (and an error recorded) if that fails.
    private func rename(_ path: String, toFreeName name: String, in dir: String, result: inout ExtractResult, for source: URL) -> String? {
        for _ in 0..<100 {
            let target = (dir as NSString).appendingPathComponent(ArchiveNames.freeName(name, extension: nil, in: dir))
            let err = ExclusiveRename.rename(path, target)
            if err == 0 { return target }
            if err != EEXIST && err != ENOTEMPTY {
                result.errors.append((source, FileSystemError(errno: err, path: target)))
                return nil
            }
        }
        result.errors.append((source, FileSystemError(.other("Couldn’t find a free name"), path: dir)))
        return nil
    }

    // MARK: Engines

    /// Lists with the first engine that can open the archive.
    public func listWithFallback(_ archive: URL, cancel: CancellationFlag) throws(FileSystemError) -> [ArchiveEntry] {
        var firstError: FileSystemError?
        for engine in engines {
            do throws(FileSystemError) {
                return try engine.list(archive, cancel: cancel)
            } catch {
                if !Self.isUnreadable(error) { throw error }
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? ArchiveError.unreadable(archive.path(percentEncoded: false), "")
    }

    /// Extracts the entries at `paths` with the first engine that can.
    func extractWithFallback(_ archive: URL, only paths: [String], into folder: URL, cancel: CancellationFlag,
                             progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        var firstError: FileSystemError?
        for engine in engines {
            do throws(FileSystemError) {
                try engine.extract(archive, only: paths, into: folder, cancel: cancel, progress: progress)
                return
            } catch {
                if !Self.isUnreadable(error) { throw error }
                if firstError == nil { firstError = error }
                for child in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
                    _ = CopyEngine.removeTree(folder.appending(path: child).path(percentEncoded: false))
                }
            }
        }
        throw firstError ?? ArchiveError.unreadable(archive.path(percentEncoded: false), "")
    }

    private func extractWithFallback(_ archive: URL, into folder: URL, cancel: CancellationFlag,
                                     progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        var firstError: FileSystemError?
        for engine in engines {
            do throws(FileSystemError) {
                try engine.extract(archive, into: folder, cancel: cancel, progress: progress)
                return
            } catch {
                if !Self.isUnreadable(error) { throw error }
                if firstError == nil { firstError = error }
                // Start the next engine on an empty folder.
                for child in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
                    _ = CopyEngine.removeTree(folder.appending(path: child).path(percentEncoded: false))
                }
            }
        }
        throw firstError ?? ArchiveError.unreadable(archive.path(percentEncoded: false), "")
    }

    /// "Can't open this archive" — another engine may do better. (Not: cancelled, password, disk full, permissions.)
    static func isUnreadable(_ error: FileSystemError) -> Bool {
        error.description.hasPrefix("Can’t open this archive")
    }

    private func isFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
    }
}
