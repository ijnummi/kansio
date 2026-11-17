import Darwin
import Foundation
import Testing
@testable import FileSystemKit

/// SMB shares don't support `RENAME_EXCL` (renamex_np fails with ENOTSUP). Everything that places items must still work
/// there and still never replace an existing item. The tests make their folders behave like such a share.
@Suite("Exclusive rename without RENAME_EXCL (SMB)")
struct ExclusiveRenameTests {
    let fm = FileManager.default
    func path(_ u: URL) -> String { u.path(percentEncoded: false) }
    func text(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }

    /// A folder (on the startup volume, or `volume`) whose renames behave as on an SMB share.
    func smbLike(_ t: TempDir, on volume: TestVolume? = nil) throws -> URL {
        let folder: URL
        if let volume {
            folder = volume.url.appending(path: "share", directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            folder = try t.dir("share")
        }
        ExclusiveRename.simulateUnsupported(under: path(folder))
        return folder
    }

    @Test func fallbackRenamesButNeverReplaces() throws {
        let t = try TempDir()
        let share = try smbLike(t)
        defer { ExclusiveRename.stopSimulating(under: path(share)) }
        let a = share.appending(path: "a.txt"), b = share.appending(path: "b.txt"), c = share.appending(path: "c.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        #expect(ExclusiveRename.rename(path(a), path(b)) == EEXIST)
        #expect(try text(b) == "b", "the existing item is untouched")
        #expect(ExclusiveRename.rename(path(a), path(c)) == 0)
        #expect(try text(c) == "a")
        #expect(!fm.fileExists(atPath: path(a)))
        #expect(ExclusiveRename.rename(path(a), path(b)) == ENOENT)
    }

    @Test func copyAndMoveOntoAShareFromAnotherVolume() async throws {
        let t = try TempDir()
        let volume = try TestVolume(sizeMB: 32)
        let share = try smbLike(t, on: volume)
        defer { ExclusiveRename.stopSimulating(under: path(share)) }
        let src = try t.dir("src")
        try Data("one".utf8).write(to: src.appending(path: "file.txt"))
        try t.dir("src/Folder/sub")
        try Data("two".utf8).write(to: src.appending(path: "Folder/sub/inner.txt"))

        let copy = await CopyEngine(kind: .copy, sources: [src.appending(path: "file.txt")], destination: share).run()
        #expect(copy.errors.isEmpty, "\(copy.errors)")
        #expect(try text(share.appending(path: "file.txt")) == "one")

        // Cut + paste (the reported bug): file and folder, source removed after the verified copy.
        try fm.removeItem(at: share.appending(path: "file.txt"))
        let move = await CopyEngine(kind: .move, sources: [src.appending(path: "file.txt"), src.appending(path: "Folder")],
                                    destination: share).run()
        #expect(move.errors.isEmpty, "\(move.errors)")
        #expect(try text(share.appending(path: "file.txt")) == "one")
        #expect(try text(share.appending(path: "Folder/sub/inner.txt")) == "two")
        #expect(!fm.fileExists(atPath: path(src.appending(path: "file.txt"))))
        #expect(!fm.fileExists(atPath: path(src.appending(path: "Folder"))))
        #expect(try fm.contentsOfDirectory(atPath: path(share)).allSatisfy { !$0.hasPrefix(".kansio-partial-") })
    }

    @Test func conflictsOnAShareStillNeverOverwrite() async throws {
        let t = try TempDir()
        let share = try smbLike(t)
        defer { ExclusiveRename.stopSimulating(under: path(share)) }
        let src = try t.dir("src")
        try Data("new".utf8).write(to: src.appending(path: "x.txt"))
        try Data("old".utf8).write(to: share.appending(path: "x.txt"))
        let skipped = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: share).run()
        #expect(skipped.skipped.count == 1)
        let keepBoth = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: share,
                                        resolver: { _ in .keepBoth }).run()
        #expect(keepBoth.errors.isEmpty, "\(keepBoth.errors)")
        #expect(try text(share.appending(path: "x (2).txt")) == "new")
        #expect(try text(share.appending(path: "x.txt")) == "old")
    }

    @Test func moveRenameAndTrashWithinAShare() async throws {
        let t = try TempDir()
        let share = try smbLike(t)
        defer { ExclusiveRename.stopSimulating(under: path(share)) }
        let sub = try t.dir("share/sub")
        let file = share.appending(path: "f.txt")
        try Data("f".utf8).write(to: file)

        let move = await CopyEngine(kind: .move, sources: [file], destination: sub).run()
        #expect(move.errors.isEmpty, "\(move.errors)")
        let moved = sub.appending(path: "f.txt")
        #expect(try text(moved) == "f")

        try Data("g".utf8).write(to: sub.appending(path: "g.txt"))
        #expect(throws: FileOperations.RenameError.alreadyExists("g.txt")) { try FileOperations.renameBlocking(moved, to: "g.txt") }
        #expect(try text(sub.appending(path: "g.txt")) == "g")
        let renamed = try FileOperations.renameBlocking(moved, to: "h.txt")
        #expect(try text(renamed) == "f")

        let trash = DirectoryTrasher(directory: share.appending(path: ".Trashes/501", directoryHint: .isDirectory))
        let first = try trash.trash(renamed)
        try Data("f2".utf8).write(to: sub.appending(path: "h.txt"))
        let second = try trash.trash(sub.appending(path: "h.txt"))
        #expect(second != first)
        #expect(try text(first) == "f" && text(second) == "f2", "a second item with the same name doesn't replace the first")
    }
}
