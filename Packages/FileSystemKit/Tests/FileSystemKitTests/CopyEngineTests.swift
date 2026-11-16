import Darwin
import Foundation
import Synchronization
import Testing
@testable import FileSystemKit

@Suite("Copy/move engine", .serialized)
struct CopyEngineTests {
    let fm = FileManager.default

    func path(_ u: URL) -> String { u.path(percentEncoded: false) }

    func makeTree(in t: TempDir) throws -> URL {
        let root = try t.dir("Tree")
        try t.dir("Tree/sub/deeper")
        try Data(repeating: 1, count: 10_000).write(to: root.appending(path: "a.bin"))
        try Data("hello".utf8).write(to: root.appending(path: "sub/b.txt"))
        try Data(repeating: 2, count: 3000).write(to: root.appending(path: "sub/deeper/c.dat"))
        try t.symlink("Tree/link-to-a", to: "a.bin")
        setxattr(path(root.appending(path: "a.bin")), "dev.kansio.test", "value", 5, 0, 0)
        // A Finder tag (it's an xattr) must survive the copy too.
        try (root.appending(path: "sub/b.txt") as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: path(root.appending(path: "sub/b.txt")))
        return root
    }

    func xattr(_ url: URL, _ name: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(path(url), name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : nil
    }

    func checkTreeCopy(_ copy: URL) throws {
        #expect(try Data(contentsOf: copy.appending(path: "a.bin")).count == 10_000)
        #expect(try String(contentsOf: copy.appending(path: "sub/b.txt"), encoding: .utf8) == "hello")
        #expect(try Data(contentsOf: copy.appending(path: "sub/deeper/c.dat")).count == 3000)
        let link = path(copy.appending(path: "link-to-a"))
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == "a.bin", "symlinks are copied as symlinks")
        #expect(xattr(copy.appending(path: "a.bin"), "dev.kansio.test") == "value")
        let tags = try copy.appending(path: "sub/b.txt").resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Red"])
        let date = try fm.attributesOfItem(atPath: path(copy.appending(path: "sub/b.txt")))[.modificationDate] as? Date
        #expect(date == Date(timeIntervalSince1970: 1_500_000_000))
    }

    func noPartials(_ folder: URL) throws -> Bool {
        try fm.contentsOfDirectory(atPath: path(folder)).allSatisfy { !$0.hasPrefix(".kansio-partial-") }
    }

    @Test(arguments: [false, true])
    func copiesTreesPreservingMetadata(clone: Bool) async throws {
        let t = try TempDir()
        let tree = try makeTree(in: t)
        let dest = try t.dir("Dest")
        var engine = CopyEngine(kind: .copy, sources: [tree], destination: dest)
        engine.disableClone = !clone
        let result = await engine.run()
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.completed.count == 1)
        try checkTreeCopy(dest.appending(path: "Tree"))
        #expect(fm.fileExists(atPath: path(tree.appending(path: "a.bin"))), "copy leaves the source")
        #expect(try noPartials(dest))
        #expect(result.progress.completedItems == result.progress.totalItems)
        #expect(result.progress.totalBytes == 13_005)
    }

    @Test func sameFolderCopyIsNamedLikeExplorer() async throws {
        let t = try TempDir()
        let file = try t.file("Report.txt", bytes: 3)
        for _ in 0..<2 { _ = await CopyEngine(kind: .copy, sources: [file], destination: t.url).run() }
        let names = try fm.contentsOfDirectory(atPath: t.path).sorted()
        #expect(names == ["Report - Copy (2).txt", "Report - Copy.txt", "Report.txt"])
    }

    @Test func conflictsAreSkippedByDefaultAndNeverOverwrite() async throws {
        let t = try TempDir()
        let src = try t.dir("src")
        try Data("new".utf8).write(to: src.appending(path: "x.txt"))
        let dest = try t.dir("dest")
        try Data("old".utf8).write(to: dest.appending(path: "x.txt"))
        let result = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest).run()
        #expect(result.skipped.count == 1 && result.completed.isEmpty)
        #expect(result.errors.first?.error.description.contains("already exists") == true)
        #expect(try String(contentsOf: dest.appending(path: "x.txt"), encoding: .utf8) == "old")
    }

    @Test func keepBothAndReplace() async throws {
        let t = try TempDir()
        let src = try t.dir("src")
        try Data("new".utf8).write(to: src.appending(path: "x.txt"))
        let dest = try t.dir("dest")
        try Data("old".utf8).write(to: dest.appending(path: "x.txt"))
        let keepBoth = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest, resolver: { _ in .keepBoth }).run()
        #expect(keepBoth.completed.first?.destination.lastPathComponent == "x (2).txt")
        #expect(try String(contentsOf: dest.appending(path: "x.txt"), encoding: .utf8) == "old")

        let trash = DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory))
        let replace = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest,
                                       trasher: trash, resolver: { _ in .replace }).run()
        #expect(replace.errors.isEmpty)
        #expect(try String(contentsOf: dest.appending(path: "x.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: trash.directory.appending(path: "x.txt"), encoding: .utf8) == "old", "replaced item went to the trash")
    }

    @Test func stopEndsTheOperation() async throws {
        let t = try TempDir()
        let src = try t.dir("src")
        for n in ["a", "b", "c"] { try Data(n.utf8).write(to: src.appending(path: n)) }
        let dest = try t.dir("dest")
        try Data("x".utf8).write(to: dest.appending(path: "a"))
        let result = await CopyEngine(kind: .copy, sources: ["a", "b", "c"].map { src.appending(path: $0) }, destination: dest,
                                      resolver: { _ in .stop }).run()
        #expect(result.cancelled)
        #expect(!fm.fileExists(atPath: path(dest.appending(path: "b"))))
    }

    @Test func sameVolumeMoveIsARename() async throws {
        let t = try TempDir()
        let tree = try makeTree(in: t)
        let inode = try fm.attributesOfItem(atPath: path(tree))[.systemFileNumber] as? Int
        let dest = try t.dir("Dest")
        let result = await CopyEngine(kind: .move, sources: [tree], destination: dest).run()
        #expect(result.errors.isEmpty)
        #expect(!fm.fileExists(atPath: path(tree)))
        let moved = dest.appending(path: "Tree")
        #expect(try fm.attributesOfItem(atPath: path(moved))[.systemFileNumber] as? Int == inode, "same file, not a copy")
        try checkTreeCopy(moved)
    }

    @Test func moveOntoItselfIsANoOpAndIntoItselfAnError() async throws {
        let t = try TempDir()
        let tree = try makeTree(in: t)
        let same = await CopyEngine(kind: .move, sources: [tree], destination: t.url).run()
        #expect(same.skipped.count == 1 && same.errors.isEmpty)
        let into = await CopyEngine(kind: .move, sources: [tree], destination: tree.appending(path: "sub")).run()
        #expect(into.errors.first?.error.description.contains("into itself") == true)
        let copyInto = await CopyEngine(kind: .copy, sources: [tree], destination: tree.appending(path: "sub")).run()
        #expect(copyInto.errors.first?.error.description.contains("into itself") == true)
        #expect(fm.fileExists(atPath: path(tree.appending(path: "a.bin"))))
    }

    @Test func crossVolumeMoveRemovesSourceOnlyAfterSuccess() async throws {
        let volume = try TestVolume(sizeMB: 32)
        let t = try TempDir()
        let tree = try makeTree(in: t)
        let result = await CopyEngine(kind: .move, sources: [tree], destination: volume.url).run()
        #expect(result.errors.isEmpty, "\(result.errors)")
        try checkTreeCopy(volume.url.appending(path: "Tree"))
        #expect(!fm.fileExists(atPath: path(tree)), "source removed after a verified copy")
        #expect(try noPartials(volume.url))
    }

    @Test func crossVolumeMoveKeepsSourceWhenAFileFails() async throws {
        let volume = try TestVolume(sizeMB: 32)
        let t = try TempDir()
        let tree = try makeTree(in: t)
        let secret = tree.appending(path: "sub/b.txt")
        chmod(path(secret), 0) // unreadable
        defer { chmod(path(secret), 0o644) }
        let result = await CopyEngine(kind: .move, sources: [tree], destination: volume.url).run()
        #expect(!result.errors.isEmpty)
        #expect(fm.fileExists(atPath: path(secret)), "the original is kept when anything failed")
        #expect(result.errors.contains { $0.error.description.contains("original was kept") })
        #expect(fm.fileExists(atPath: path(volume.url.appending(path: "Tree/a.bin"))), "what could be copied is there")
    }

    @Test func apfsCloneIsInstantAndUsesNoSpace() async throws {
        let volume = try TestVolume(sizeMB: 300)
        let big = volume.url.appending(path: "big.bin")
        let fd = open(path(big), O_CREAT | O_WRONLY, 0o644)
        let chunk = [UInt8](repeating: 7, count: 1 << 20)
        for _ in 0..<100 { _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } } // 100 MB of real data
        close(fd)
        func free() -> Int64 { var s = statfs(); statfs(path(volume.url), &s); return Int64(s.f_bavail) * Int64(s.f_bsize) }
        let before = free()
        let start = ContinuousClock.now
        let dest = volume.url.appending(path: "dest", directoryHint: .isDirectory)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = await CopyEngine(kind: .copy, sources: [big], destination: dest).run()
        let elapsed = ContinuousClock.now - start
        #expect(result.errors.isEmpty)
        #expect(try fm.attributesOfItem(atPath: path(dest.appending(path: "big.bin")))[.size] as? Int == 100 << 20)
        #expect(before - free() < 5 << 20, "a clone shares blocks: free space barely changes (\(before - free()) bytes)")
        #expect(elapsed < .milliseconds(300), "\(elapsed)")
    }

    @Test func cancelInsideALargeFileLeavesNothingBehind() async throws {
        let volume = try TestVolume(sizeMB: 300)
        let t = try TempDir()
        let big = t.url.appending(path: "big.bin")
        let fd = open(path(big), O_CREAT | O_WRONLY, 0o644)
        let chunk = [UInt8](repeating: 9, count: 1 << 20)
        for _ in 0..<200 { _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
        close(fd)
        // Cancel deterministically from the first progress report that has moved data
        // (i.e. while copyfile is inside the file).
        let flag = CancellationFlag()
        let destination = volume.url
        let result = await Task.detached {
            var engine = CopyEngine(kind: .copy, sources: [big], destination: destination)
            engine.progressInterval = .zero // see every chunk
            return engine.runBlocking(cancel: flag) { p in
                if p.completedBytes > 0 && !p.isPreparing { flag.cancel() }
            }
        }.value
        #expect(result.cancelled)
        #expect(result.progress.completedBytes < 200 << 20, "stopped inside the file")
        #expect(!fm.fileExists(atPath: path(volume.url.appending(path: "big.bin"))))
        #expect(try noPartials(volume.url))
    }

    @Test func vanishedSourceAndReadOnlyDestinationAreReported() async throws {
        let t = try TempDir()
        let dest = try t.dir("dest")
        let gone = await CopyEngine(kind: .copy, sources: [t.url.appending(path: "gone.txt")], destination: dest).run()
        #expect(gone.errors.first?.error.code == .notFound)
        let file = try t.file("ok.txt", bytes: 5)
        let locked = try t.dir("locked")
        chmod(path(locked), 0o555)
        defer { chmod(path(locked), 0o755) }
        let denied = await CopyEngine(kind: .copy, sources: [file], destination: locked).run()
        #expect(denied.completed.isEmpty)
        #expect(denied.errors.first?.error.code == .permissionDenied, "\(denied.errors)")
    }

    @Test func progressIsMonotonicAndComplete() async throws {
        let t = try TempDir()
        let src = try t.dir("many")
        for i in 0..<300 { try Data(repeating: 1, count: 1000).write(to: src.appending(path: "f\(i)")) }
        let dest = try t.dir("dest")
        let seen = Recorder<OperationProgress>()
        var engine = CopyEngine(kind: .copy, sources: [src], destination: dest)
        engine.disableClone = true
        let result = await engine.run { p in seen.append(p) }
        let values = seen.values
        #expect(values.count >= 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(result.progress.completedBytes == 300_000)
        #expect(result.progress.totalItems == 301)
    }

    @Test func newTextFileNumbering() throws {
        let t = try TempDir()
        #expect(try FileOperations.createTextFileBlocking(in: t.url) == "New Text Document.txt")
        #expect(try FileOperations.createTextFileBlocking(in: t.url) == "New Text Document (2).txt")
    }
}

final class Recorder<T: Sendable>: Sendable {
    private let storage = Mutex<[T]>([])
    func append(_ value: T) { storage.withLock { $0.append(value) } }
    var values: [T] { storage.withLock { $0 } }
}
