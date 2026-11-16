import Foundation
import Synchronization
import Testing
@testable import FileSystemKit

@Suite("Name conflicts", .serialized)
struct ConflictTests {
    let fm = FileManager.default
    func path(_ u: URL) -> String { u.path(percentEncoded: false) }
    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    func write(_ text: String, _ u: URL) throws {
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    func names(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: path(u))) ?? []).sorted() }

    func setup() throws -> (TempDir, src: URL, dest: URL, trash: DirectoryTrasher) {
        let t = try TempDir()
        let src = try t.dir("src"), dest = try t.dir("dest")
        return (t, src, dest, DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory)))
    }

    @Test func replaceFileWithFileTrashesTheOldOne() async throws {
        let (_, src, dest, trash) = try setup()
        try write("new", src.appending(path: "x.txt"))
        try write("old", dest.appending(path: "x.txt"))
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest, trasher: trash,
                                 resolver: { _ in .replace }).run()
        #expect(r.errors.isEmpty)
        #expect(read(dest.appending(path: "x.txt")) == "new")
        #expect(read(trash.directory.appending(path: "x.txt")) == "old")
    }

    @Test func replaceAcrossTypes() async throws {
        let (_, src, dest, trash) = try setup()
        // folder replaces file
        try write("inside", src.appending(path: "thing/inner.txt"))
        try write("i am a file", dest.appending(path: "thing"))
        let r1 = await CopyEngine(kind: .copy, sources: [src.appending(path: "thing")], destination: dest, trasher: trash,
                                  resolver: { c in #expect(c.sourceIsFolder && !c.existingIsFolder); return .replace }).run()
        #expect(r1.errors.isEmpty)
        #expect(read(dest.appending(path: "thing/inner.txt")) == "inside")
        #expect(read(trash.directory.appending(path: "thing")) == "i am a file")
        // file replaces folder
        try write("plain", src.appending(path: "box"))
        try write("deep", dest.appending(path: "box/deep.txt"))
        let r2 = await CopyEngine(kind: .move, sources: [src.appending(path: "box")], destination: dest, trasher: trash,
                                  resolver: { _ in .replace }).run()
        #expect(r2.errors.isEmpty)
        #expect(read(dest.appending(path: "box")) == "plain")
        #expect(read(trash.directory.appending(path: "box/deep.txt")) == "deep", "the replaced folder is in the trash, whole")
    }

    @Test func keepBothNumbersFoldersAndFiles() async throws {
        let (_, src, dest, trash) = try setup()
        try write("a", src.appending(path: "Folder/a.txt"))
        try write("b", dest.appending(path: "Folder/b.txt"))
        try write("doc", src.appending(path: "Notes.txt"))
        try write("doc", dest.appending(path: "Notes.txt"))
        try write("doc", dest.appending(path: "Notes (2).txt"))
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "Folder"), src.appending(path: "Notes.txt")],
                                 destination: dest, trasher: trash, resolver: { _ in .keepBoth }).run()
        #expect(r.errors.isEmpty)
        #expect(names(dest) == ["Folder", "Folder (2)", "Notes (2).txt", "Notes (3).txt", "Notes.txt"])
        #expect(names(dest.appending(path: "Folder")) == ["b.txt"], "keep both never merges")
    }

    @Test func copyMergeResolvesNestedClashes() async throws {
        let (_, src, dest, trash) = try setup()
        try write("new a", src.appending(path: "F/a.txt"))
        try write("c", src.appending(path: "F/c.txt"))
        try write("new d", src.appending(path: "F/sub/d.txt"))
        try write("e", src.appending(path: "F/sub/e.txt"))
        try write("old a", dest.appending(path: "F/a.txt"))
        try write("b", dest.appending(path: "F/b.txt"))
        try write("old d", dest.appending(path: "F/sub/d.txt"))
        let asked = Recorder<String>()
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "F")], destination: dest, trasher: trash) { c in
            asked.append(c.existing.lastPathComponent)
            if c.sourceIsFolder && c.existingIsFolder { return .merge }
            return c.source.lastPathComponent == "a.txt" ? .keepBoth : .replace
        }.run()
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(asked.values == ["F", "a.txt", "sub", "d.txt"], "every clash, nested ones included, is asked about")
        #expect(names(dest.appending(path: "F")) == ["a (2).txt", "a.txt", "b.txt", "c.txt", "sub"])
        #expect(read(dest.appending(path: "F/a.txt")) == "old a")
        #expect(read(dest.appending(path: "F/a (2).txt")) == "new a")
        #expect(read(dest.appending(path: "F/sub/d.txt")) == "new d")
        #expect(read(trash.directory.appending(path: "d.txt")) == "old d")
        #expect(names(dest.appending(path: "F/sub")) == ["d.txt", "e.txt"])
        #expect(fm.fileExists(atPath: path(src.appending(path: "F/a.txt"))), "copy leaves the source")
        #expect(r.completed.first?.destination.lastPathComponent == "F")
    }

    @Test func moveMergeRemovesTheEmptiedSourceButKeepsSkippedItems() async throws {
        let (_, src, dest, trash) = try setup()
        try write("1", src.appending(path: "A/one.txt"))
        try write("2", src.appending(path: "A/two.txt"))
        try write("x", dest.appending(path: "A/two.txt"))
        try write("3", src.appending(path: "B/three.txt"))
        try fm.createDirectory(at: dest.appending(path: "B"), withIntermediateDirectories: true)
        let r = await CopyEngine(kind: .move, sources: [src.appending(path: "A"), src.appending(path: "B")], destination: dest,
                                 trasher: trash) { c in c.existingIsFolder && c.sourceIsFolder ? .merge : .skip }.run()
        #expect(read(dest.appending(path: "A/one.txt")) == "1")
        #expect(read(dest.appending(path: "A/two.txt")) == "x", "skipped: existing kept")
        #expect(read(src.appending(path: "A/two.txt")) == "2", "skipped: source kept where it was")
        #expect(!fm.fileExists(atPath: path(src.appending(path: "A/one.txt"))))
        #expect(!fm.fileExists(atPath: path(src.appending(path: "B"))), "fully merged folder removed (it was empty)")
        #expect(read(dest.appending(path: "B/three.txt")) == "3")
        #expect(r.skipped.map(\.lastPathComponent) == ["two.txt"])
    }

    @Test func crossVolumeMoveMerge() async throws {
        let volume = try TestVolume(sizeMB: 32)
        let (_, src, _, trash) = try setup()
        try write("1", src.appending(path: "A/one.txt"))
        try write("2", src.appending(path: "A/sub/two.txt"))
        try write("old", volume.url.appending(path: "A/keep.txt"))
        let r = await CopyEngine(kind: .move, sources: [src.appending(path: "A")], destination: volume.url, trasher: trash,
                                 resolver: { _ in .merge }).run()
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(names(volume.url.appending(path: "A")) == ["keep.txt", "one.txt", "sub"])
        #expect(read(volume.url.appending(path: "A/sub/two.txt")) == "2")
        #expect(!fm.fileExists(atPath: path(src.appending(path: "A"))))
    }

    @Test func mergeOnlyAppliesToTwoFolders() async throws {
        let (_, src, dest, trash) = try setup()
        try write("new", src.appending(path: "x.txt"))
        try write("old", dest.appending(path: "x.txt"))
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest, trasher: trash,
                                 resolver: { _ in .merge }).run()
        #expect(r.skipped.count == 1)
        #expect(read(dest.appending(path: "x.txt")) == "old")
    }

    @Test func stopInsideAMerge() async throws {
        let (_, src, dest, trash) = try setup()
        for n in ["a", "b", "c"] { try write(n, src.appending(path: "F/\(n)")); try write("old", dest.appending(path: "F/\(n)")) }
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "F")], destination: dest, trasher: trash) { c in
            c.sourceIsFolder ? .merge : .stop
        }.run()
        #expect(r.cancelled)
        #expect(names(dest.appending(path: "F")).allSatisfy { read(dest.appending(path: "F/\($0)")) == "old" })
    }

    @Test func neverReplacesTheFolderThatContainsTheSource() async throws {
        let t = try TempDir()
        try write("data", t.url.appending(path: "a/b/b/file.txt"))
        let trash = DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory))
        let r = await CopyEngine(kind: .move, sources: [t.url.appending(path: "a/b/b")], destination: t.url.appending(path: "a"),
                                 trasher: trash, resolver: { _ in .replace }).run()
        #expect(r.errors.first?.error.description.contains("contains the item") == true)
        #expect(read(t.url.appending(path: "a/b/b/file.txt")) == "data")
        #expect(!fm.fileExists(atPath: path(trash.directory)))
    }

    @Test func caseOnlyNameClashIsAConflictOnCaseInsensitiveVolumes() async throws {
        let (_, src, dest, trash) = try setup()
        try write("lower", src.appending(path: "readme.md"))
        try write("UPPER", dest.appending(path: "README.md"))
        let asked = Recorder<String>()
        let r = await CopyEngine(kind: .copy, sources: [src.appending(path: "readme.md")], destination: dest, trasher: trash) { c in
            asked.append(c.existing.lastPathComponent)
            return .keepBoth
        }.run()
        #expect(asked.values.count == 1, "readme.md vs README.md is the same name here")
        #expect(r.errors.isEmpty)
        #expect(names(dest) == ["README.md", "readme (2).md"])
        #expect(read(dest.appending(path: "README.md")) == "UPPER")
    }

    @Test func applyToAllAsksOncePerKind() async throws {
        let (_, src, dest, trash) = try setup()
        for i in 0..<5 {
            try write("new \(i)", src.appending(path: "f\(i).txt"))
            try write("old \(i)", dest.appending(path: "f\(i).txt"))
        }
        try write("n", src.appending(path: "D/n.txt"))
        try write("o", dest.appending(path: "D/o.txt"))
        let asked = Recorder<Bool>()
        let policy = ConflictPolicy { c in
            asked.append(c.sourceIsFolder)
            return c.sourceIsFolder ? (.merge, false) : (.replace, true)
        }
        let sources = (0..<5).map { src.appending(path: "f\($0).txt") } + [src.appending(path: "D")]
        let r = await CopyEngine(kind: .copy, sources: sources, destination: dest, trasher: trash, resolver: policy.resolver).run()
        #expect(r.errors.isEmpty)
        #expect(asked.values == [false, true], "one question for all file clashes, folders asked separately")
        #expect((0..<5).allSatisfy { read(dest.appending(path: "f\($0).txt")) == "new \($0)" })
        #expect(names(dest.appending(path: "D")) == ["n.txt", "o.txt"])
    }

    @Test func applyToAllIsNotRememberedForStop() async {
        let policy = ConflictPolicy { _ in (.stop, true) }
        let c = Conflict(source: URL(filePath: "/a"), existing: URL(filePath: "/b"), sourceIsFolder: false, existingIsFolder: false)
        _ = await policy.resolve(c)
        _ = await policy.resolve(c)
        #expect(await policy.questionsAsked == 2)
    }
}
