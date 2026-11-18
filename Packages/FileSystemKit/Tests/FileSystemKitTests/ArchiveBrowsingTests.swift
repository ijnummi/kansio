import Darwin
import Foundation
import Testing
@testable import FileSystemKit

@Suite("Archives: browsing as folders (P3-5)", .serialized)
struct ArchiveBrowsingTests {
    func engines() -> [any ArchiveEngine] {
        var list: [any ArchiveEngine] = []
        if let z = sevenZip() { list.append(z) }
        if LibArchiveEngine.isAvailable { list.append(LibArchiveEngine()) }
        return list
    }

    /// photos.zip: dir/a.txt, dir/sub/b.txt, dir/sub/deeper/c.txt, top.txt, .hidden (made with /usr/bin/zip).
    func makeZip(_ t: TempDir) throws -> URL {
        let src = try t.dir("src")
        for (path, text) in [("dir/a.txt", "a"), ("dir/sub/b.txt", "bb"), ("dir/sub/deeper/c.txt", "ccc"), ("top.txt", "top"), (".hidden", "h")] {
            let url = src.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let zip = t.url.appending(path: "photos.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", "-X", zip.path(percentEncoded: false), "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }

    @Test func indexHasEveryFolderIncludingImpliedOnes() {
        // No entry for "x" or "x/y": implied by the file's path.
        let entries = [ArchiveEntry(path: "x/y/file.txt", isFolder: false, size: 5), ArchiveEntry(path: "x/z", isFolder: true),
                       ArchiveEntry(path: "readme.md", isFolder: false, size: 1), ArchiveEntry(path: ".git/config", isFolder: false)]
        let index = ArchiveIndex(archivePath: "/a/b.zip/", entries: entries, size: 10, modified: .now)
        #expect(index.archivePath == "/a/b.zip")
        #expect(Set(index.items(in: "")?.map(\.name) ?? []) == ["x", "readme.md", ".git"])
        #expect(index.subfolders(in: "x")?.map(\.name) == ["y", "z"])
        #expect(index.items(in: "x/y")?.first.map { $0.name == "file.txt" && $0.size == 5 && $0.kind == .file && $0.flags.contains(.inArchive) } == true)
        #expect(index.items(in: "nope") == nil)
        #expect(index.items(in: "")?.first { $0.name == ".git" }?.isHidden == true)
        #expect(index.items(in: "x")?.first { $0.name == "y" }?.isFolder == true)
        // Stable identities, different per path.
        let again = ArchiveIndex(archivePath: "/a/b.zip", entries: entries, size: 10, modified: .now)
        #expect(index.items(in: "x")?.map(\.fileID).sorted() == again.items(in: "x")?.map(\.fileID).sorted())
        #expect(Set(index.items(in: "x")?.map(\.fileID) ?? []).count == 2)
        #expect(index.storedPath(of: "file.txt", in: "x/y") == "x/y/file.txt")
    }

    @Test func readsDatesAndListsWithEachEngine() throws {
        let t = try TempDir()
        let zip = try makeZip(t)
        for engine in engines() {
            let index = try ArchiveIndex.readBlocking(zip, engines: [engine], cancel: CancellationFlag())
            #expect(Set(index.items(in: "")?.map(\.name) ?? []) == ["dir", "top.txt", ".hidden"], "\(engine.name)")
            #expect(index.subfolders(in: "dir/sub")?.map(\.name) == ["deeper"], "\(engine.name)")
            let file = index.items(in: "dir")?.first { $0.name == "a.txt" }
            #expect(file.map { abs($0.modificationDate.timeIntervalSinceNow) < 600 } == true, "\(engine.name): entry dates read")
        }
    }

    @Test func registryFindsLocationsThroughTheArchive() throws {
        let registry = OpenedArchives()
        let index = ArchiveIndex(archivePath: "/tmp/k/photos.zip", entries: [ArchiveEntry(path: "a/b/c.txt", isFolder: false)], size: 1, modified: .now)
        #expect(registry.location(of: "/tmp/k/photos.zip/a") == nil) // not opened yet
        registry.register(index)
        #expect(registry.location(of: "/tmp/k/photos.zip").map { $0.inner } == "")
        #expect(registry.location(of: "/tmp/k/photos.zip/a/b/").map { $0.inner } == "a/b")
        #expect(registry.location(of: "/tmp/k/photos.zipper/a") == nil)
        #expect(registry.location(of: "/tmp/k") == nil)
        #expect(registry.archiveNames(inFolder: "/tmp/k/") == ["photos.zip"])
        #expect(registry.archiveNames(inFolder: "/tmp").isEmpty)
        registry.forget("/tmp/k/photos.zip")
        #expect(registry.location(of: "/tmp/k/photos.zip/a") == nil)
    }

    @Test func extractsSelectedItemsWithEachEngine() async throws {
        let t = try TempDir()
        let zip = try makeZip(t)
        for engine in engines() {
            let out = try t.dir("out-\(engine.name)")
            try Data("keep".utf8).write(to: out.appending(path: "a.txt")) // a clash: skipped by default, never overwritten
            let result = await ArchiveOperations(engines: [engine]).extractItems(from: zip, paths: ["dir/sub", "dir/a.txt", "top.txt"], into: out)
            // The clash is reported (the default resolver skips it), nothing else.
            #expect(result.errors.count == 1 && result.errors.allSatisfy { $0.url.lastPathComponent == "a.txt" }, "\(engine.name): \(result.errors.map(\.error.description))")
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path(percentEncoded: false)))
            #expect(names == ["a.txt", "sub", "top.txt"], "\(engine.name): \(names)")
            #expect(try String(contentsOf: out.appending(path: "a.txt"), encoding: .utf8) == "keep")
            #expect(try String(contentsOf: out.appending(path: "sub/deeper/c.txt"), encoding: .utf8) == "ccc")
            #expect(result.created.map(\.lastPathComponent).sorted() == ["sub", "top.txt"])
            #expect(!names.contains { $0.hasPrefix(".kansio-partial") })
        }
    }

    @Test func treeShowsOnlyOpenedArchivesAndTheirFolders() throws {
        let t = try TempDir()
        let zip = try makeZip(t)
        defer { OpenedArchives.shared.forget(zip.path(percentEncoded: false)) }
        #expect(try FolderTreeIO.listFoldersBlocking(t.url).items.map(\.name) == ["src"]) // not opened: a file
        OpenedArchives.shared.register(try ArchiveIndex.readBlocking(zip, engines: engines(), cancel: CancellationFlag()))
        let listed = try FolderTreeIO.listFoldersBlocking(t.url).items
        #expect(listed.map(\.name) == ["photos.zip", "src"])
        #expect(listed.first?.flags.contains(.inArchive) == true && listed.first?.kind == .directory)
        #expect(try FolderTreeIO.listFoldersBlocking(zip).items.map(\.name) == ["dir"])
        #expect(try FolderTreeIO.listFoldersBlocking(zip.appending(path: "dir/sub")).items.map(\.name) == ["deeper"])
        #expect(FolderTreeIO.hasShownSubfolderBlocking(zip.appending(path: "dir"), showHidden: false))
        #expect(!FolderTreeIO.hasShownSubfolderBlocking(zip.appending(path: "dir/sub/deeper"), showHidden: false))
        #expect(FolderTreeIO.hasShownSubfolderBlocking(t.url, showHidden: false))
    }
}
