import Foundation
import Testing
@testable import FileSystemKit

@Suite("Progressive loading")
struct LoaderTests {
    @Test func emitsGrowingSnapshotsEndingWithCompleteOne() async throws {
        let t = try TempDir()
        for i in 0..<3000 { try t.file("item \(i).txt") }
        let loader = DirectoryLoader(lister: BulkDirectoryLister(bufferSize: 4096), coalescing: .zero, throttle: .zero)
        var counts: [Int] = []
        var completeFlags: [Bool] = []
        for try await update in loader.load(t.url) {
            counts.append(update.contents.items.count)
            completeFlags.append(update.isComplete)
        }
        #expect(counts.count > 1, "expected progressive updates")
        #expect(counts == counts.sorted(), "snapshots must only grow")
        #expect(counts.last == 3000)
        #expect(completeFlags.last == true)
        #expect(completeFlags.dropLast().allSatisfy { !$0 })
    }

    @Test func smallFolderIsComplete() async throws {
        let t = try TempDir()
        try t.file("one")
        var last: ListingUpdate?
        for try await update in DirectoryLoader().load(t.url) { last = update }
        #expect(last?.isComplete == true)
        #expect(last?.contents.items.map(\.name) == ["one"])
    }

    @Test func fastFolderArrivesAsOneCompleteUpdate() async throws {
        let t = try TempDir()
        for i in 0..<3000 { try t.file("item \(i).txt") }
        // Tiny buffer → ~100 syscalls, but all within the coalescing window.
        let loader = DirectoryLoader(lister: BulkDirectoryLister(bufferSize: 4096), coalescing: .seconds(5))
        var updates: [ListingUpdate] = []
        for try await update in loader.load(t.url) { updates.append(update) }
        #expect(updates.count == 1)
        #expect(updates.first?.isComplete == true)
        #expect(updates.first?.contents.items.count == 3000)
    }

    @Test func symlinkTargetsAreResolvedBeforeTheListingIsComplete() async throws {
        let t = try TempDir()
        try t.dir("Real")
        try t.dir("Tool.app/Contents")
        try t.file("file.txt")
        try t.symlink("to-folder", to: "Real")
        try t.symlink("to-app", to: "Tool.app")
        try t.symlink("to-file", to: "file.txt")
        try t.symlink("dangling", to: "nowhere")
        try t.symlink("loop-a", to: "loop-b")
        try t.symlink("loop-b", to: "loop-a")
        var last: ListingUpdate?
        for try await update in DirectoryLoader().load(t.url) { last = update }
        let items = try #require(last).contents.items
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["to-folder"]?.flags.contains(.linkToFolder) == true)
        #expect(byName["to-folder"]?.isFolder == true)
        #expect(byName["to-app"]?.flags.contains(.linkToPackage) == true)
        #expect(byName["to-app"]?.isFolder == false)
        #expect(byName["to-file"]?.flags.intersection(.linkTarget) == .linkToFile)
        #expect(byName["dangling"]?.flags.contains(.brokenLink) == true)
        #expect(byName["loop-a"]?.flags.contains(.brokenLink) == true)

        // Links to folders sort with the folders (Explorer: folders first).
        let ordered = try #require(last).contents.ordered(by: .default, includeHidden: false).map(\.name)
        #expect(Array(ordered.prefix(2)).sorted() == ["Real", "to-folder"])
    }

    @Test func slowSymlinkResolutionDoesNotHoldBackTheListing() async throws {
        let t = try TempDir()
        try t.dir("Real")
        try t.symlink("to-folder", to: "Real")
        // Deadline 0: the unresolved listing is published, then a resolved one follows.
        let loader = DirectoryLoader(symlinkDeadline: .zero)
        var updates: [ListingUpdate] = []
        for try await update in loader.load(t.url) { updates.append(update) }
        #expect(updates.allSatisfy { $0.isComplete })
        let final = try #require(updates.last).contents.items.first { $0.name == "to-folder" }
        #expect(final?.isFolder == true)
        #expect(updates.count <= 2)
    }

    @Test func finderAliasesResolveAndAreFlagged() async throws {
        let t = try TempDir()
        let target = try t.dir("Target Folder")
        let file = try t.file("doc.txt")
        for (alias, to) in [("folder alias", target), ("file alias", file)] {
            let data = try to.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: t.url.appending(path: alias))
        }
        let items = Dictionary(uniqueKeysWithValues: try BulkDirectoryLister().listAll(t.url).map { ($0.name, $0) })
        #expect(items["folder alias"]?.flags.contains(.alias) == true)
        #expect(items["file alias"]?.flags.contains(.alias) == true)
        let resolvedFolder = await Aliases.resolve(t.url.appending(path: "folder alias"))
        #expect(resolvedFolder?.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
        let resolvedFile = await Aliases.resolve(t.url.appending(path: "file alias"))
        #expect(resolvedFile?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: file)
        #expect(await Aliases.resolve(t.url.appending(path: "file alias")) == nil) // target gone
    }

    @Test func missingFolderThrows() async throws {
        let t = try TempDir()
        await #expect(throws: FileSystemError.self) {
            for try await _ in DirectoryLoader().load(t.url.appending(path: "gone")) {}
        }
    }
}
