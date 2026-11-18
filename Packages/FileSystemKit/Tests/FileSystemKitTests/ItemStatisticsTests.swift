import Darwin
import Foundation
import Testing
@testable import FileSystemKit

@Suite("Item statistics (Get Info sizes)")
struct ItemStatisticsTests {
    @Test func countsFilesFoldersAndBytes() throws {
        let t = try TempDir()
        try t.dir("F/sub")
        try t.file("F/a", bytes: 100)
        try t.file("F/sub/b", bytes: 50)
        try t.file("top", bytes: 7)
        let totals = ItemStatistics.measure([t.url.appending(path: "F"), t.url.appending(path: "top")])
        #expect(totals.files == 3)
        #expect(totals.folders == 2)
        #expect(totals.bytes == 157)
    }

    /// Deep trees (node_modules, the fixtures' `deep`) overflowed a worker thread's stack while the walk recursed per
    /// level. Now it keeps its own stack: 400 levels measure fine on a thread with only 128 KB of stack.
    @Test func deepTreesDontOverflowTheStack() throws {
        let t = try TempDir()
        let depth = 400
        let rel = Array(repeating: "d", count: depth).joined(separator: "/")
        try t.dir(rel)
        try t.file(rel + "/leaf", bytes: 42)
        let base = t.url
        let root = base.appending(path: "d", directoryHint: .isDirectory)
        nonisolated(unsafe) var totals = ItemStatistics.Totals()
        nonisolated(unsafe) var scanned = ArchiveSource.Tree()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            totals = ItemStatistics.measure([root])
            scanned = ArchiveSource.scan(base: base, items: ["d"], cancel: CancellationFlag())
            done.signal()
        }
        thread.stackSize = 128 * 1024
        thread.start()
        done.wait()
        #expect(totals.folders == depth && totals.files == 1 && totals.bytes == 42)
        #expect(scanned.folders.count == depth && scanned.bytes == 42)
    }

    @Test func skippedFoldersAreNotEntered() throws {
        let t = try TempDir()
        try t.dir("F/private/deep")
        try t.file("F/private/deep/x", bytes: 900)
        try t.file("F/a", bytes: 10)
        let skip = FolderTree.normalized(t.url.appending(path: "F/private").path(percentEncoded: false))
        let totals = ItemStatistics.measure([t.url.appending(path: "F", directoryHint: .isDirectory)],
                                            options: .init(skipDataless: true, skipping: [skip]))
        #expect(totals.bytes == 10 && totals.skipped == 1 && totals.folders == 2)
        // The skip list applies to the measured folder itself too (trailing slash or not).
        let itself = ItemStatistics.measure([t.url.appending(path: "F/private", directoryHint: .isDirectory)], options: .init(skipping: [skip]))
        #expect(itself.bytes == 0 && itself.skipped == 1)
    }

    @Test func symlinksAreNotFollowedAndLoopsAreHarmless() throws {
        let t = try TempDir()
        try t.dir("F")
        try t.file("F/big", bytes: 1000)
        try t.symlink("F/to-big", to: "big")
        try t.symlink("F/to-self", to: ".")
        try t.symlink("F/to-parent", to: "..")
        let totals = ItemStatistics.measure([t.url.appending(path: "F")])
        #expect(totals.bytes == 1000, "the link target isn't counted twice")
        #expect(totals.others == 3)
        #expect(totals.folders == 1)
    }

    @Test func hardLinksCountOnce() throws {
        let t = try TempDir()
        try t.dir("F")
        let file = try t.file("F/data", bytes: 500)
        #expect(link(file.path(percentEncoded: false), t.url.appending(path: "F/data-link").path(percentEncoded: false)) == 0)
        let totals = ItemStatistics.measure([t.url.appending(path: "F")])
        #expect(totals.bytes == 500)
        #expect(totals.files == 1)
    }

    @Test func unreadableFoldersAreReported() throws {
        let t = try TempDir()
        let locked = try t.dir("F/locked")
        try t.file("F/locked/x", bytes: 9)
        chmod(locked.path(percentEncoded: false), 0)
        defer { chmod(locked.path(percentEncoded: false), 0o755) }
        let totals = ItemStatistics.measure([t.url.appending(path: "F")])
        #expect(totals.unreadable == 1)
        #expect(totals.bytes == 0)
    }

    @Test func cancellationStopsEarly() throws {
        let t = try TempDir()
        for i in 0..<3000 { try t.file("f\(i)", bytes: 1) }
        let cancel = CancellationFlag()
        let totals = ItemStatistics.measure([t.url], cancel: cancel) { _ in cancel.cancel() }
        #expect(totals.files < 3000)
    }
}
