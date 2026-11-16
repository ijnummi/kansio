import Foundation
import Testing
@testable import FileSystemKit

@Suite("Folder sizes (P1-6)")
struct FolderSizeTests {
    private func entry(_ bytes: Int64) -> FolderSizeCache.Entry {
        var totals = ItemStatistics.Totals()
        totals.bytes = bytes
        return .init(totals: totals, eventID: 1)
    }

    @Test func aChangeInsideInvalidatesTheFolderAndItsAncestors() {
        let cache = FolderSizeCache()
        for path in ["/a", "/a/b", "/a/b/c", "/a/x", "/z"] { cache.store(entry(1), for: path) }
        let dropped = cache.invalidate(changed: ["/a/b/c/d/e"])
        #expect(dropped == ["/a/b/c", "/a/b", "/a"])
        #expect(cache.entry("/a/x") != nil && cache.entry("/z") != nil && cache.entry("/a") == nil)
    }

    @Test func aChangeOlderThanTheMeasurementIsAlreadyInIt() {
        let cache = FolderSizeCache()
        var totals = ItemStatistics.Totals()
        totals.bytes = 1
        cache.store(.init(totals: totals, eventID: 100), for: "/a")   // measured before the change
        cache.store(.init(totals: totals, eventID: 300), for: "/a/b") // measured after it
        let dropped = cache.invalidate(changedAt: ["/a/b/c": 200])
        #expect(dropped == ["/a"] && cache.entry("/a/b") != nil)
    }

    @Test func subtreeRescanDropsEverythingBelowAndAbove() {
        let cache = FolderSizeCache()
        for path in ["/a", "/a/b", "/a/b/c", "/a/x", "/ab"] { cache.store(entry(1), for: path) }
        cache.invalidate(subtree: "/a/b")
        #expect(cache.entry("/a/b/c") == nil && cache.entry("/a/b") == nil && cache.entry("/a") == nil)
        #expect(cache.entry("/a/x") != nil && cache.entry("/ab") != nil) // a sibling with a common prefix stays
    }

    @Test func oldestEntriesGoBeyondTheLimit() {
        let cache = FolderSizeCache(limit: 3)
        for i in 0..<5 { cache.store(entry(Int64(i)), for: "/f\(i)") }
        #expect(cache.count == 3 && cache.entry("/f0") == nil && cache.entry("/f4")?.totals.bytes == 4)
        cache.store(entry(9), for: "/f2/") // updating keeps one entry (trailing slash ignored)
        #expect(cache.count == 3 && cache.entry("/f2")?.totals.bytes == 9)
    }

    @Test func sortingBySizeUsesFolderSizes() {
        let contents = FolderContents(items: [
            FileItem(name: "small", kind: .directory, fileID: 1),
            FileItem(name: "big", kind: .directory, fileID: 2),
            FileItem(name: "unknown", kind: .directory, fileID: 3),
            FileItem(name: "file.txt", kind: .file, size: 5_000, fileID: 4),
        ])
        let sizes: [String: Int64] = ["small": 10, "big": 1_000_000]
        let descending = contents.ordered(by: FileSort(field: .size, ascending: false), includeHidden: true, folderSizes: sizes)
        // Descending reverses the whole list (Explorer): files first, then folders largest first.
        #expect(descending.map(\.name) == ["file.txt", "big", "small", "unknown"])
        let ascending = contents.ordered(by: FileSort(field: .size, ascending: true), includeHidden: true, folderSizes: sizes)
        #expect(ascending.map(\.name) == ["unknown", "small", "big", "file.txt"])
    }

    @Test func automaticWorkSkipsProtectedFoldersExceptTheOneBrowsed() {
        let home = "/nonexistent-kansio-home" // no TCC.db there: "no Full Disk Access"
        let fromHome = Privacy.automaticSkips(browsing: home, home: home)
        #expect(fromHome.contains(home + "/Desktop") && fromHome.contains(home + "/Library/Containers") && fromHome.contains(home + "/Movies/TV"))
        let inDesktop = Privacy.automaticSkips(browsing: home + "/Desktop/project", home: home)
        #expect(!inDesktop.contains(home + "/Desktop") && inDesktop.contains(home + "/Documents"))
    }

    @Test func privacyDenialIsTellableFromFolderPermissions() {
        #expect(FileSystemError(errno: EPERM, path: "/x").isPrivacyDenied)
        #expect(!FileSystemError(errno: EACCES, path: "/x").isPrivacyDenied)
        #expect(FileSystemError(errno: EACCES, path: "/x").code == .permissionDenied)
    }
}
