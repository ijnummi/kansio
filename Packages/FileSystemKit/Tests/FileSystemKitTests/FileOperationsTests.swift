import Foundation
import Testing
@testable import FileSystemKit

@Suite("Simple file operations")
struct FileOperationsTests {
    @Test func nameValidation() {
        #expect(FileNames.validate("ok.txt") == nil)
        #expect(FileNames.validate(" leading space") == nil)
        #expect(FileNames.validate("") == .empty)
        #expect(FileNames.validate("   ") == .empty)
        #expect(FileNames.validate("a/b") == .containsSlash)
        #expect(FileNames.validate("..") == .reserved)
        #expect(FileNames.validate(String(repeating: "é", count: 128)) == .tooLong) // 256 bytes
        #expect(FileNames.validate("colon:ok") == nil) // legal on APFS (Finder shows it as "/")
    }

    @Test func explorerNumbering() {
        #expect(FileNames.numbered("New folder", 1) == "New folder")
        #expect(FileNames.numbered("New folder", 2) == "New folder (2)")
        #expect(FileNames.numbered("Notes.txt", 3) == "Notes (3).txt")
        #expect(FileNames.numbered(".env", 2) == ".env (2)")
        #expect(FileNames.numbered("archive.tar.gz", 2) == "archive.tar (2).gz")
    }

    @Test func editableRangeSkipsExtension() {
        #expect(FileNames.editableRange(of: "Report.pdf", isFolder: false) == NSRange(location: 0, length: 6))
        #expect(FileNames.editableRange(of: "Folder.v2", isFolder: true) == NSRange(location: 0, length: 9))
        #expect(FileNames.editableRange(of: ".env", isFolder: false) == NSRange(location: 0, length: 4))
        #expect(FileNames.editableRange(of: "noext", isFolder: false) == NSRange(location: 0, length: 5))
    }

    @Test func renameNeverOverwrites() throws {
        let t = try TempDir()
        let a = try t.file("a.txt", bytes: 1)
        try t.file("b.txt", bytes: 2)
        #expect(throws: FileOperations.RenameError.alreadyExists("b.txt")) { try FileOperations.renameBlocking(a, to: "b.txt") }
        #expect(try Data(contentsOf: t.url.appending(path: "b.txt")).count == 2) // untouched
        let renamed = try FileOperations.renameBlocking(a, to: "c.txt")
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(FileManager.default.fileExists(atPath: renamed.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: a.path(percentEncoded: false)))
    }

    @Test func caseOnlyRenameWorksOnCaseInsensitiveVolume() throws {
        let t = try TempDir()
        let a = try t.file("readme.md")
        let renamed = try FileOperations.renameBlocking(a, to: "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: t.path)
        #expect(names == ["README.md"])
        #expect(renamed.lastPathComponent == "README.md")
    }

    @Test func renameRejectsInvalidNames() throws {
        let t = try TempDir()
        let a = try t.file("a")
        #expect(throws: FileOperations.RenameError.invalidName(.containsSlash)) { try FileOperations.renameBlocking(a, to: "x/y") }
        #expect(throws: FileOperations.RenameError.invalidName(.empty)) { try FileOperations.renameBlocking(a, to: " ") }
    }

    @Test func renameVanishedItemReportsNotFound() async throws {
        let t = try TempDir()
        let gone = t.url.appending(path: "gone.txt")
        let result = await FileOperations.rename(gone, to: "x.txt")
        guard case .failure(.failed(let e)) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(e.code == .notFound)
    }

    @Test func newFolderNumbering() throws {
        let t = try TempDir()
        #expect(try FileOperations.createFolderBlocking(in: t.url) == "New folder")
        #expect(try FileOperations.createFolderBlocking(in: t.url) == "New folder (2)")
        try t.file("New folder (3)") // a *file* with that name also blocks it
        #expect(try FileOperations.createFolderBlocking(in: t.url) == "New folder (4)")
    }

    @Test func newFolderInReadOnlyFolderFails() throws {
        let t = try TempDir()
        let locked = try t.dir("locked")
        chmod(locked.path(percentEncoded: false), 0o555)
        defer { chmod(locked.path(percentEncoded: false), 0o755) }
        #expect(throws: FileSystemError(.permissionDenied, path: locked.path(percentEncoded: false))) {
            try FileOperations.createFolderBlocking(in: locked)
        }
    }

    @Test func directoryTrasherKeepsBothOnNameClash() throws {
        let t = try TempDir()
        let trash = DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory))
        try t.dir("a"); try t.file("a/x.txt")
        try t.dir("b"); try t.file("b/x.txt")
        let outcome = FileOperations.trashBlocking([t.url.appending(path: "a/x.txt"), t.url.appending(path: "b/x.txt")], using: trash)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.trashed.map { $0.inTrash.lastPathComponent }.sorted() == ["x (2).txt", "x.txt"])
    }

    @Test func trashReportsFailuresAndContinues() throws {
        let t = try TempDir()
        let trash = DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory))
        let ok = try t.file("ok.txt")
        let outcome = FileOperations.trashBlocking([t.url.appending(path: "missing"), ok], using: trash)
        #expect(outcome.trashed.count == 1)
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed.first?.error.code == .notFound)
    }

    /// The real Trash, on a disk image (its own .Trashes) — never the user's ~/.Trash.
    @Test func systemTrashOnTestVolume() throws {
        let volume = try TestVolume()
        let file = volume.url.appending(path: "doomed.txt")
        try Data("x".utf8).write(to: file)
        let outcome = FileOperations.trashBlocking([file], using: SystemTrasher())
        #expect(outcome.failed.isEmpty, "\(outcome.failed)")
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let inTrash = try #require(outcome.trashed.first?.inTrash)
        // On the test volume's own .Trashes (paths compared resolved: /var → /private/var).
        let trashPath = inTrash.resolvingSymlinksInPath().path(percentEncoded: false)
        #expect(trashPath.hasPrefix(volume.url.resolvingSymlinksInPath().path(percentEncoded: false)), "\(trashPath)")
        #expect(trashPath.contains("/.Trashes/"), "\(trashPath)")
        #expect(FileManager.default.fileExists(atPath: inTrash.path(percentEncoded: false)))
    }

    @Test func incrementalContentsMatchFullRanking() {
        let locale = Locale(identifier: "en_US")
        var rng = SeededGenerator(seed: 5)
        var names = Set<String>()
        while names.count < 3000 { names.insert("Item \(rng.next() % 100_000) \(["a", "B", "ä", "ﬁ", ""][Int(rng.next() % 5)])") }
        var items = names.map { FileItem(name: $0, kind: .file) }
        var contents = FolderContents(items: items, locale: locale)
        for round in 0..<20 {
            let remove = Set(items.prefix(round % 7).map(\.name))
            let add = (0..<(round % 5)).map { FileItem(name: "New \(round)-\($0) \(rng.next() % 1000)", kind: .file) }
            contents = contents.applying(removing: remove, adding: add, locale: locale)
            items = items.filter { !remove.contains($0.name) } + add
            items.shuffle(using: &rng)
            let reference = FolderContents(items: items, locale: locale).ordered(by: .default, includeHidden: true).map(\.name)
            #expect(contents.ordered(by: .default, includeHidden: true).map(\.name) == reference, "round \(round)")
        }
    }

    @Test func renameViaContentsKeepsOrder() {
        let locale = Locale(identifier: "en_US")
        let contents = FolderContents(items: ["b", "d", "f"].map { FileItem(name: $0, kind: .file) }, locale: locale)
        let renamed = contents.applying(removing: ["f"], adding: [FileItem(name: "a", kind: .file)], locale: locale)
        #expect(renamed.ordered(by: .default, includeHidden: true).map(\.name) == ["a", "b", "d"])
        let replaced = renamed.applying(adding: [FileItem(name: "b", kind: .file, size: 9)], locale: locale)
        #expect(replaced.items.count == 3)
        #expect(replaced.item(named: "b")?.size == 9)
    }
}
