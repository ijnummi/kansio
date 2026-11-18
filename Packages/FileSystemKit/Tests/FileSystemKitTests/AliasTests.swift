import Foundation
import Testing
@testable import FileSystemKit

@Suite("Aliases")
struct AliasTests {
    @Test func naming() {
        #expect(Aliases.name(for: "Report.pdf", sameFolder: false, isTaken: { _ in false }) == "Report.pdf")
        #expect(Aliases.name(for: "Report.pdf", sameFolder: true, isTaken: { _ in false }) == "Report.pdf alias")
        let taken: Set = ["Report.pdf", "Report.pdf alias", "Report.pdf alias 2"]
        #expect(Aliases.name(for: "Report.pdf", sameFolder: false, isTaken: taken.contains) == "Report.pdf alias 3")
    }

    @Test func makesResolvableAliasesWithoutOverwriting() throws {
        let t = try TempDir()
        let fm = FileManager.default
        let originals = t.url.appending(path: "originals", directoryHint: .isDirectory)
        let destination = t.url.appending(path: "destination", directoryHint: .isDirectory)
        try fm.createDirectory(at: originals.appending(path: "Folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = originals.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        try Data("keep me".utf8).write(to: destination.appending(path: "notes.txt")) // a clash

        let outcome = Aliases.makeBlocking(to: [file, originals.appending(path: "Folder")], in: destination)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.made.map(\.alias.lastPathComponent) == ["notes.txt alias", "Folder"])
        #expect(try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8) == "keep me") // untouched
        for (original, alias) in outcome.made {
            let resolved = try URL(resolvingAliasFileAt: alias)
            #expect(resolved.resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path)
        }
        // The listing sees them as Finder aliases; no temporary files are left.
        let listed = try BulkDirectoryLister().listAll(destination)
        #expect(Set(listed.map(\.name)) == ["notes.txt", "notes.txt alias", "Folder"])
        #expect(listed.filter { $0.flags.contains(.alias) }.map(\.name).sorted() == ["Folder", "notes.txt alias"])

        // In the original's own folder: "name alias", then "name alias 2".
        let again = Aliases.makeBlocking(to: [file, file], in: originals)
        #expect(again.made.map(\.alias.lastPathComponent) == ["notes.txt alias", "notes.txt alias 2"])
    }

    @Test func missingOriginalIsReported() throws {
        let t = try TempDir()
        let outcome = Aliases.makeBlocking(to: [t.url.appending(path: "gone.txt")], in: t.url)
        #expect(outcome.made.isEmpty && outcome.failed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path).isEmpty) // no temporary file left
    }
}
