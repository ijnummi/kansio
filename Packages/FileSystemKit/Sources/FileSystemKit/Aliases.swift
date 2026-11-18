import Darwin
import Foundation

/// Making Finder aliases (P3-2: "Create Alias Here" in the right-button drag menu; resolving them: SymlinkResolver.swift).
///
/// An alias is a small file holding bookmark data (`URL.bookmarkData(options: .suitableForBookmarkFile)`) with the
/// Finder "is alias" flag; Finder and Kansio resolve it to the original even after the original moved. Each one is
/// written under a hidden temporary name in the destination and renamed into place with `RENAME_EXCL`, so nothing is
/// ever overwritten and a half-written alias never appears under its real name.
extension Aliases {
    /// The alias's name in `folder` (Finder): the original's own name in another folder, "Name alias" when that is
    /// taken or the folder is the original's own, then "Name alias 2", "Name alias 3"…
    public static func name(for original: String, sameFolder: Bool, isTaken: (String) -> Bool) -> String {
        if !sameFolder, !isTaken(original) { return original }
        let base = "\(original) alias"
        if !isTaken(base) { return base }
        for n in 2...10_000 where !isTaken("\(base) \(n)") { return "\(base) \(n)" }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }

    public struct Outcome: Sendable {
        /// Original → the alias made for it.
        public var made: [(original: URL, alias: URL)] = []
        public var failed: [(url: URL, error: FileSystemError)] = []
    }

    /// Makes an alias in `folder` for each of `originals`; failures don't stop the rest. Blocking (listing queue).
    public static func makeBlocking(to originals: [URL], in folder: URL) -> Outcome {
        var outcome = Outcome()
        let base = folder.path(percentEncoded: false)
        func taken(_ name: String) -> Bool {
            var st = stat()
            return lstat((base as NSString).appendingPathComponent(name), &st) == 0
        }
        for original in originals {
            do {
                let data = try original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                let temporary = folder.appending(path: ".kansio-alias-\(UUID().uuidString)", directoryHint: .notDirectory)
                try URL.writeBookmarkData(data, to: temporary)
                let sameFolder = FileOperations.isSameFile(original.deletingLastPathComponent().path(percentEncoded: false), base)
                var placed: URL?
                // A name taken between the check and the rename (another app) just moves on to the next one.
                for _ in 0..<20 where placed == nil {
                    let name = Self.name(for: original.lastPathComponent, sameFolder: sameFolder, isTaken: taken)
                    let target = folder.appending(path: name, directoryHint: .notDirectory)
                    let err = ExclusiveRename.rename(temporary.path(percentEncoded: false), target.path(percentEncoded: false))
                    if err == 0 { placed = target } else if err != EEXIST {
                        unlink(temporary.path(percentEncoded: false)) // our own temporary file
                        throw FileSystemError(errno: err, path: target.path(percentEncoded: false))
                    }
                }
                guard let placed else {
                    unlink(temporary.path(percentEncoded: false))
                    throw FileSystemError(.other("Couldn’t find a free name for the alias"), path: base)
                }
                outcome.made.append((original, placed))
            } catch {
                outcome.failed.append((original, error as? FileSystemError ?? FileSystemError(foundation: error, path: original.path(percentEncoded: false))))
            }
        }
        return outcome
    }

    public static func make(to originals: [URL], in folder: URL) async -> Outcome {
        await runOnListingQueue { makeBlocking(to: originals, in: folder) }
    }
}
