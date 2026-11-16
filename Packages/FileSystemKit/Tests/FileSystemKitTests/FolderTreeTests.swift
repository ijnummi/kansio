import Foundation
import Testing
@testable import FileSystemKit

@Suite("Folder tree (P1-1)")
struct FolderTreeTests {
    private func folder(_ name: String, id: UInt64, hidden: Bool = false) -> FileItem {
        FileItem(name: name, kind: .directory, flags: hidden ? .hidden : [], fileID: id)
    }

    private func home(_ tree: FolderTree) -> TreeNode {
        tree.setRoots([
            .init(url: URL(filePath: "/Users/me", directoryHint: .isDirectory), title: "Home", kind: .home, isNetwork: false),
            .init(url: URL(filePath: "/", directoryHint: .isDirectory), title: "Macintosh HD", kind: .volume, isNetwork: false),
            .init(url: URL(filePath: "/Volumes/Share", directoryHint: .isDirectory), title: "Share", kind: .volume, isNetwork: true),
        ])
        return tree.roots[0]
    }

    @Test func diffPlanReproducesTheNewOrderWithoutRemovingKeptNodes() {
        let tree = FolderTree()
        let root = home(tree)
        _ = tree.apply([folder("a", id: 1), folder("b", id: 2), folder("c", id: 3), folder("d", id: 4)], realPath: nil, to: root)
        let old = root.children
        let (a, b, c) = (old[0], old[1], old[2])
        // "a" renamed to "e" (same inode → same node, moves to the end), "c" removed, "aa" added.
        let change = tree.apply([folder("aa", id: 5), folder("b", id: 2), folder("d", id: 4), folder("e", id: 1)], realPath: nil, to: root)
        let new = root.children
        #expect(new[3] === a && a.name == "e" && new[1] === b)
        #expect(change.renamed.map(\.name) == ["e"] && change.removed.first === c)
        let replayed = TreeDiff.apply(change.plan, to: old, new: new)
        #expect(replayed.count == new.count && zip(replayed, new).allSatisfy { $0 === $1 })
        #expect(change.plan.removed == IndexSet([2]) && change.plan.inserted == IndexSet([0]) && change.plan.moves.count == 1)
    }

    @Test func diffPlanForFirstListingIsOneInsertBatch() {
        let tree = FolderTree()
        let root = home(tree)
        let items = (0..<10_000).map { folder(String(format: "f%05d", $0), id: UInt64($0 + 1)) }
        let change = tree.apply(items, realPath: nil, to: root)
        #expect(change.plan.inserted == IndexSet(0..<10_000) && change.plan.removed.isEmpty && change.plan.moves.isEmpty)
        let again = tree.apply(items, realPath: nil, to: root)
        #expect(again.plan.isEmpty)
    }

    @Test func randomChangesAlwaysReplayCorrectly() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let tree = FolderTree()
            let root = home(tree)
            var ids = (0..<Int.random(in: 0...30, using: &generator)).map { UInt64($0 + 1) }
            _ = tree.apply(ids.map { folder("n\($0)", id: $0) }, realPath: nil, to: root)
            let old = root.children
            ids.removeAll { _ in Bool.random(using: &generator) && Bool.random(using: &generator) }
            ids += (100...UInt64(100 + Int.random(in: 0...10, using: &generator))).filter { _ in Bool.random(using: &generator) }
            ids.shuffle(using: &generator) // arbitrary new order (renames)
            let change = tree.apply(ids.map { folder("n\($0)", id: $0) }, realPath: nil, to: root)
            let replayed = TreeDiff.apply(change.plan, to: old, new: root.children)
            #expect(replayed.count == root.children.count && zip(replayed, root.children).allSatisfy { $0 === $1 })
        }
    }

    @Test func hiddenFoldersFollowTheSettingWithoutLosingNodes() {
        let tree = FolderTree(showHidden: false)
        let root = home(tree)
        _ = tree.apply([folder(".git", id: 1, hidden: true), folder("src", id: 2), folder("Library", id: 3, hidden: true)], realPath: nil, to: root)
        #expect(root.children.map(\.name) == ["src"])
        let dotGit = root.allChildren![0]
        let shown = tree.setShowHidden(true)
        #expect(root.children.map(\.name) == [".git", "src", "Library"] && root.children[0] === dotGit)
        #expect(shown.count == 1 && shown[0].plan.inserted == IndexSet([0, 2]))
        let hidden = tree.setShowHidden(false)
        #expect(root.children.map(\.name) == ["src"] && hidden[0].plan.removed == IndexSet([0, 2]))
    }

    @Test func revealUsesTheMostSpecificRoot() {
        let tree = FolderTree()
        _ = home(tree)
        let underHome = tree.revealTarget(for: URL(filePath: "/Users/me/Projects/kansio"))
        #expect(underHome?.root.title == "Home" && underHome?.names == ["Projects", "kansio"])
        let elsewhere = tree.revealTarget(for: URL(filePath: "/Users/other/x"))
        #expect(elsewhere?.root.title == "Macintosh HD" && elsewhere?.names == ["Users", "other", "x"])
        let share = tree.revealTarget(for: URL(filePath: "/Volumes/Share/movies/"))
        #expect(share?.root.title == "Share" && share?.names == ["movies"] && share?.root.isNetwork == true)
        #expect(tree.revealTarget(for: URL(filePath: "/Users/me"))?.names == [])
        #expect(tree.revealTarget(for: URL(filePath: "/Users/meme"))?.root.title == "Macintosh HD")
    }

    @Test func autoExpandedBranchesCollapseWhenLeftHandExpandedStay() {
        let tree = FolderTree()
        let root = home(tree)
        _ = tree.apply([folder("a", id: 1), folder("x", id: 2)], realPath: nil, to: root)
        let a = root.children[0], x = root.children[1]
        _ = tree.apply([folder("b", id: 3)], realPath: nil, to: a)
        let b = a.children[0]
        tree.didExpand(root, automatically: true)
        tree.didExpand(a, automatically: true)
        tree.didExpand(b, automatically: true)
        tree.didExpand(x, automatically: false) // by hand
        // Leaving ~/a/b for ~/x: a and b collapse (deepest first), root and x stay.
        let collapse = tree.autoExpandedToCollapse(keeping: [root, x])
        #expect(collapse.map(\.name) == ["b", "a"])
        collapse.forEach(tree.didCollapse)
        // A branch the user expands by hand after the reveal opened it stays.
        tree.didExpand(a, automatically: true)
        tree.didExpand(a, automatically: false)
        #expect(tree.autoExpandedToCollapse(keeping: [root]).isEmpty && a.isExpanded && !a.expandedAutomatically)
    }

    @Test func disclosureRules() {
        let tree = FolderTree()
        let root = home(tree)
        let share = tree.roots[2]
        _ = tree.apply([folder("local", id: 1), FileItem(name: "link", kind: .symlink, flags: .linkToFolder, fileID: 2)], realPath: nil, to: root)
        _ = tree.apply([folder("movies", id: 3)], realPath: nil, to: share)
        let local = root.children[1].name == "local" ? root.children[1] : root.children[0]
        let link = root.children.first { $0.kind == .link }!
        let movies = share.children[0]
        #expect(!local.showsDisclosure(checkNetwork: false)) // unknown → none (no flicker)
        #expect(local.needsSubfolderCheck(checkNetwork: false))
        local.hasSubfolders = true
        #expect(local.showsDisclosure(checkNetwork: false))
        #expect(link.showsDisclosure(checkNetwork: false) && !link.needsSubfolderCheck(checkNetwork: true))
        #expect(movies.showsDisclosure(checkNetwork: false) && !movies.needsSubfolderCheck(checkNetwork: false))
        #expect(!movies.showsDisclosure(checkNetwork: true) && movies.needsSubfolderCheck(checkNetwork: true))
        _ = tree.apply([], realPath: nil, to: local) // listed, empty
        #expect(!local.showsDisclosure(checkNetwork: false))
    }

    @Test func realPathIndexFollowsListingsAndRemovals() {
        let tree = FolderTree()
        let root = home(tree)
        _ = tree.apply([folder("a", id: 1)], realPath: "/Users/me", to: root)
        let a = root.children[0]
        _ = tree.apply([folder("b", id: 2)], realPath: "/Users/me/a", to: a)
        _ = tree.apply([], realPath: "/Users/me/a/b", to: a.children[0])
        #expect(tree.listedNodes(atRealPath: "/Users/me/a/") .first === a)
        #expect(Set(tree.listedNodes(underRealPath: "/Users/me/a").map(\.name)) == ["a", "b"])
        _ = tree.apply([], realPath: "/Users/me", to: root) // "a" deleted: its subtree leaves the index
        #expect(tree.listedRealPaths == ["/Users/me"])
    }

    // MARK: Real folders

    @Test func listsOnlyFoldersAndLinksToFoldersInFinderOrder() throws {
        let temp = try TempDir()
        try temp.dir("b10")
        try temp.dir("b9")
        try temp.dir(".hidden")
        try temp.dir("Tool.app") // package
        try temp.file("file.txt")
        try temp.symlink("to-b9", to: "b9")
        try temp.symlink("to-file", to: "file.txt")
        try temp.symlink("broken", to: "nowhere")
        let listing = try FolderTreeIO.listFoldersBlocking(temp.url)
        #expect(listing.items.map(\.name) == [".hidden", "b9", "b10", "to-b9"])
        #expect(listing.realPath == FolderTreeIO.realPath(temp.path))
        #expect(FolderTreeIO.hasShownSubfolderBlocking(temp.url, showHidden: false))
        let onlyHidden = try temp.dir("only-hidden")
        try FileManager.default.createDirectory(at: onlyHidden.appending(path: ".git"), withIntermediateDirectories: true)
        #expect(!FolderTreeIO.hasShownSubfolderBlocking(onlyHidden, showHidden: false))
        #expect(FolderTreeIO.hasShownSubfolderBlocking(onlyHidden, showHidden: true))
        let packageOnly = try temp.dir("pkg-only")
        try FileManager.default.createDirectory(at: packageOnly.appending(path: "X.app"), withIntermediateDirectories: true)
        #expect(!FolderTreeIO.hasShownSubfolderBlocking(packageOnly, showHidden: true))
    }

    @Test func linkLoopsExpandOneLevelPerStepAndEndAtPathLimits() async throws {
        let temp = try TempDir()
        let a = try temp.dir("a")
        try FileManager.default.createSymbolicLink(atPath: a.appending(path: "up").path(percentEncoded: false),
                                                   withDestinationPath: "..") // a/up → temp (contains a)
        let tree = FolderTree()
        tree.setRoots([.init(url: temp.url, title: "T", kind: .volume, isNetwork: false)])
        var node = tree.roots[0]
        var steps = 0
        // Expanding a → up → a → up …: each step lists one folder; the path grows until the system refuses.
        while steps < 400 {
            let result = await FolderTreeIO.listFolders(node.url)
            guard case .success(let listing) = result else { break }
            _ = tree.apply(listing.items, realPath: listing.realPath, to: node)
            guard let next = node.children.first(where: { $0.name == (steps % 2 == 0 ? "a" : "up") }) else { break }
            node = next
            steps += 1
        }
        #expect(steps > 10 && steps < 400) // finite: ended by a path-length error, never hangs
        #expect(node.kind == .link || node.kind == .folder)
    }

    @Test func watcherReportsChangedDirectoriesOnly() async throws {
        let temp = try TempDir()
        let sub = try temp.dir("sub")
        let events = EventBox()
        let watcher = TreeWatcher(rootPath: temp.path) { events.add($0) }
        watcher.start(latency: 0.05)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.createDirectory(at: sub.appending(path: "new"), withIntermediateDirectories: false)
        let real = FolderTreeIO.realPath(sub.path(percentEncoded: false))!
        let deadline = ContinuousClock.now + .seconds(5)
        while !events.changedPaths.contains(real) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(events.changedPaths.contains(real))
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TreeWatcher.Event] = []
    func add(_ event: TreeWatcher.Event) { lock.withLock { all.append(event) } }
    var changedPaths: Set<String> {
        lock.withLock {
            all.reduce(into: Set<String>()) { result, event in if case .changed(let paths) = event { result.formUnion(paths) } }
        }
    }
}
