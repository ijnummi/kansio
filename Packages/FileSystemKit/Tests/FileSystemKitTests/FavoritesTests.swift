import Foundation
import Testing
@testable import FileSystemKit

@Suite("Favorites (P1-2)")
struct FavoritesTests {
    @Test func pinUnpinAndNoDuplicates() {
        var list = FavoriteList()
        let a = list.pin(FavoriteEntry(path: "/a"))
        let b = list.pin(FavoriteEntry(path: "/b/"))
        let again = list.pin(FavoriteEntry(path: "/b")) // already pinned (trailing slash ignored)
        let c = list.pin(FavoriteEntry(path: "/c"), at: 0)
        #expect(a && b && !again && c)
        #expect(list.entries.map(\.path) == ["/c", "/a", "/b"])
        list.unpin(list.entries[1].id)
        #expect(list.entries.map(\.path) == ["/c", "/b"])
        #expect(list.entries[0].title == "c")
    }

    @Test func moveUsesDropIndexes() {
        var list = FavoriteList(["/1", "/2", "/3", "/4"].map { FavoriteEntry(path: $0) })
        list.move(from: 0, to: 2) // drop between /2 and /3
        #expect(list.entries.map(\.path) == ["/2", "/1", "/3", "/4"])
        list.move(from: 3, to: 0) // to the top
        #expect(list.entries.map(\.path) == ["/4", "/2", "/1", "/3"])
        list.move(from: 1, to: 4) // to the end
        #expect(list.entries.map(\.path) == ["/4", "/1", "/3", "/2"])
        list.move(from: 9, to: 0) // out of range: nothing
        #expect(list.entries.count == 4)
    }

    @Test func roundTripsThroughJSON() throws {
        var list = FavoriteList()
        list.pin(FavoriteEntry(path: "/x", bookmark: Data([1, 2, 3]), title: "X"))
        let decoded = try JSONDecoder().decode(FavoriteList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }

    @Test func bookmarksFollowRenamesAndMoves() throws {
        let temp = try TempDir()
        let folder = try temp.dir("Project")
        let elsewhere = try temp.dir("Archive")
        let bookmark = try #require(Bookmarks.make(folder))
        let real = { (url: URL) in FolderTreeIO.realPath(url.path(percentEncoded: false)) }

        let renamed = temp.url.appending(path: "Project 2", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: renamed)
        guard case .found(let afterRename, _) = Bookmarks.resolve(bookmark) else { Issue.record("not found after rename"); return }
        #expect(real(afterRename) == real(renamed))

        let moved = elsewhere.appending(path: "Project 2", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: renamed, to: moved)
        guard case .found(let afterMove, _) = Bookmarks.resolve(bookmark) else { Issue.record("not found after move"); return }
        #expect(real(afterMove) == real(moved))

        try FileManager.default.removeItem(at: moved)
        #expect(Bookmarks.resolve(bookmark) == .missing)
    }

    @Test func aFolderInTheTrashCountsAsMissing() throws {
        // A real Trash would be the user's: use a folder named like one inside the temp dir instead.
        let temp = try TempDir()
        let folder = try temp.dir("Pinned")
        let bookmark = try #require(Bookmarks.make(folder))
        let trash = try temp.dir(".Trash")
        try FileManager.default.moveItem(at: folder, to: trash.appending(path: "Pinned"))
        #expect(Bookmarks.resolve(bookmark) == .missing)
    }

    @Test func garbageBookmarkIsMissing() {
        #expect(Bookmarks.resolve(Data([0, 1, 2, 3])) == .missing)
    }
}
