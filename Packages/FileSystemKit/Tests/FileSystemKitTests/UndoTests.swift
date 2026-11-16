import Foundation
import Testing
@testable import FileSystemKit

@Suite("Undo / Redo", .serialized)
struct UndoTests {
    let fm = FileManager.default
    let performer = UndoPerformer()
    func path(_ u: URL) -> String { u.path(percentEncoded: false) }
    func exists(_ u: URL) -> Bool { fm.fileExists(atPath: path(u)) }
    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    func write(_ text: String, _ u: URL) throws {
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func undo(_ step: UndoStep, _ trasher: any Trasher) async -> [(url: URL, error: FileSystemError)] {
        await performer.perform(step.inverse, trasher: trasher)
    }
    func redo(_ step: UndoStep, _ trasher: any Trasher) async -> [(url: URL, error: FileSystemError)] {
        await performer.perform(step, trasher: trasher)
    }

    func setup() throws -> (TempDir, DirectoryTrasher) {
        let t = try TempDir()
        return (t, DirectoryTrasher(directory: t.url.appending(path: ".trash", directoryHint: .isDirectory)))
    }

    @Test func renameUndoRedo() async throws {
        let (t, trash) = try setup()
        let a = try t.file("a.txt", bytes: 1)
        let b = try FileOperations.renameBlocking(a, to: "b.txt")
        let step = UndoStep("Rename", [.renamed(from: a, to: b)])
        #expect(await undo(step, trash).isEmpty)
        #expect(exists(a) && !exists(b))
        #expect(await redo(step, trash).isEmpty)
        #expect(!exists(a) && exists(b))
        #expect(await undo(step, trash).isEmpty)
        #expect(exists(a))
    }

    @Test func newFolderUndoTrashesItAndRedoPutsItBack() async throws {
        let (t, trash) = try setup()
        let name = try FileOperations.createFolderBlocking(in: t.url)
        let folder = t.url.appending(path: name)
        try write("inside", folder.appending(path: "x.txt")) // made after creation: still survives undo/redo
        let step = UndoStep("New Folder", [.created(folder, slot: TrashSlot())])
        #expect(await undo(step, trash).isEmpty)
        #expect(!exists(folder))
        #expect(read(trash.directory.appending(path: "New folder/x.txt")) == "inside", "undo never deletes: it's in the Trash")
        #expect(await redo(step, trash).isEmpty)
        #expect(read(folder.appending(path: "x.txt")) == "inside")
    }

    @Test func moveToTrashUndoPutsBackAndRedoTrashesAgain() async throws {
        let (t, trash) = try setup()
        let doc = try t.file("doc.txt", bytes: 4)
        let outcome = FileOperations.trashBlocking([doc], using: trash)
        let step = UndoStep("Move to Trash", outcome.trashed.map { .trashed(original: $0.original, slot: TrashSlot($0.inTrash)) })
        #expect(!exists(doc))
        #expect(await undo(step, trash).isEmpty)
        #expect(exists(doc))
        #expect(await redo(step, trash).isEmpty)
        #expect(!exists(doc))
        #expect(await undo(step, trash).isEmpty, "the slot was refreshed by the redo")
        #expect(exists(doc))
    }

    @Test func putBackRefusesToReplace() async throws {
        let (t, trash) = try setup()
        let doc = try t.file("doc.txt", bytes: 1)
        let outcome = FileOperations.trashBlocking([doc], using: trash)
        let step = UndoStep("Move to Trash", [.trashed(original: doc, slot: TrashSlot(outcome.trashed[0].inTrash))])
        try write("someone else's", doc) // the name was reused meanwhile
        let errors = await undo(step, trash)
        #expect(errors.first?.error.description.contains("in the way") == true)
        #expect(read(doc) == "someone else's")
        #expect(exists(outcome.trashed[0].inTrash), "still safe in the Trash")
    }

    @Test func undoWhenTheTrashWasEmptiedReportsIt() async throws {
        let (t, trash) = try setup()
        let doc = try t.file("doc.txt", bytes: 1)
        let outcome = FileOperations.trashBlocking([doc], using: trash)
        try fm.removeItem(at: outcome.trashed[0].inTrash) // (test only) as if the Trash was emptied
        let errors = await undo(UndoStep("Move to Trash", [.trashed(original: doc, slot: TrashSlot(outcome.trashed[0].inTrash))]), trash)
        #expect(errors.first?.error.description.contains("no longer in the Trash") == true)
    }

    @Test func copyUndoTrashesTheCopies() async throws {
        let (t, trash) = try setup()
        let src = try t.dir("src"), dest = try t.dir("dest")
        try write("a", src.appending(path: "a.txt"))
        try write("b", src.appending(path: "F/b.txt"))
        let result = await CopyEngine(kind: .copy, sources: [src.appending(path: "a.txt"), src.appending(path: "F")],
                                      destination: dest, trasher: trash).run()
        let step = UndoStep("Copy", result: result)
        #expect(await undo(step, trash).isEmpty)
        #expect(!exists(dest.appending(path: "a.txt")) && !exists(dest.appending(path: "F")))
        #expect(exists(src.appending(path: "a.txt")), "the originals are untouched")
        #expect(await redo(step, trash).isEmpty)
        #expect(read(dest.appending(path: "F/b.txt")) == "b")
    }

    @Test func sameVolumeMoveUndoRedo() async throws {
        let (t, trash) = try setup()
        let src = try t.dir("src"), dest = try t.dir("dest")
        try write("a", src.appending(path: "a.txt"))
        let result = await CopyEngine(kind: .move, sources: [src.appending(path: "a.txt")], destination: dest, trasher: trash).run()
        let step = UndoStep("Move", result: result)
        #expect(await undo(step, trash).isEmpty)
        #expect(read(src.appending(path: "a.txt")) == "a" && !exists(dest.appending(path: "a.txt")))
        #expect(await redo(step, trash).isEmpty)
        #expect(read(dest.appending(path: "a.txt")) == "a" && !exists(src.appending(path: "a.txt")))
    }

    @Test func crossVolumeMoveUndoMovesItBack() async throws {
        let volume = try TestVolume(sizeMB: 32)
        let (t, trash) = try setup()
        let src = try t.dir("src")
        try write("payload", src.appending(path: "F/deep/x.txt"))
        let result = await CopyEngine(kind: .move, sources: [src.appending(path: "F")], destination: volume.url, trasher: trash).run()
        #expect(!exists(src.appending(path: "F")))
        let step = UndoStep("Move", result: result)
        #expect(await undo(step, trash).isEmpty)
        #expect(read(src.appending(path: "F/deep/x.txt")) == "payload")
        #expect(!exists(volume.url.appending(path: "F")))
    }

    @Test func copyWithReplaceUndoRestoresTheReplacedItem() async throws {
        let (t, trash) = try setup()
        let src = try t.dir("src"), dest = try t.dir("dest")
        try write("new", src.appending(path: "x.txt"))
        try write("old", dest.appending(path: "x.txt"))
        let result = await CopyEngine(kind: .copy, sources: [src.appending(path: "x.txt")], destination: dest, trasher: trash,
                                      resolver: { _ in .replace }).run()
        let step = UndoStep("Copy", result: result)
        #expect(read(dest.appending(path: "x.txt")) == "new")
        #expect(await undo(step, trash).isEmpty)
        #expect(read(dest.appending(path: "x.txt")) == "old", "undo brings the replaced item back")
        #expect(await redo(step, trash).isEmpty)
        #expect(read(dest.appending(path: "x.txt")) == "new")
    }

    @Test func moveMergeUndoRecreatesTheSourceFolder() async throws {
        let (t, trash) = try setup()
        let src = try t.dir("src"), dest = try t.dir("dest")
        try write("1", src.appending(path: "A/one.txt"))
        try write("2", src.appending(path: "A/sub/two.txt"))
        try write("keep", dest.appending(path: "A/keep.txt"))
        let result = await CopyEngine(kind: .move, sources: [src.appending(path: "A")], destination: dest, trasher: trash,
                                      resolver: { _ in .merge }).run()
        #expect(!exists(src.appending(path: "A")))
        let step = UndoStep("Move", result: result)
        #expect(await undo(step, trash).isEmpty)
        #expect(read(src.appending(path: "A/one.txt")) == "1")
        #expect(read(src.appending(path: "A/sub/two.txt")) == "2")
        #expect(read(dest.appending(path: "A/keep.txt")) == "keep")
        #expect(!exists(dest.appending(path: "A/one.txt")))
    }

    /// The real Trash, on a disk image (its own .Trashes): trash → undo puts it back.
    @Test func realTrashPutBack() async throws {
        let volume = try TestVolume(sizeMB: 16)
        let doc = volume.url.appending(path: "doc.txt")
        try write("x", doc)
        let outcome = FileOperations.trashBlocking([doc], using: SystemTrasher())
        let step = UndoStep("Move to Trash", outcome.trashed.map { .trashed(original: $0.original, slot: TrashSlot($0.inTrash)) })
        #expect(!exists(doc))
        #expect(await undo(step, SystemTrasher()).isEmpty)
        #expect(read(doc) == "x")
    }

    @Test func inverseIsAnInvolution() {
        let a = URL(filePath: "/a"), b = URL(filePath: "/b")
        let step = UndoStep("Test", [.renamed(from: a, to: b), .moved(from: b, to: a), .created(a, slot: TrashSlot())])
        let twice = step.inverse.inverse
        #expect(twice.changes.count == 3)
        if case .renamed(let f, let t) = twice.changes[0] { #expect(f == a && t == b) } else { Issue.record("order/kind") }
        if case .created = twice.changes[2] {} else { Issue.record("created should round-trip") }
    }
}
