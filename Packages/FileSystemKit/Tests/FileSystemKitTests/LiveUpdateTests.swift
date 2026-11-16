import Foundation
import Synchronization
import Testing
@testable import FileSystemKit

@Suite("Live updates", .serialized)
struct LiveUpdateTests {
    let fm = FileManager.default
    func path(_ u: URL) -> String { u.path(percentEncoded: false) }

    /// Collects watcher events; waits until `condition` holds for the names seen so far.
    final class Collector: Sendable {
        let names = Mutex<Set<String>>([])
        let events = Mutex<[FolderWatcher.Event]>([])
        func add(_ e: FolderWatcher.Event) {
            events.withLock { $0.append(e) }
            if case .changed(let n) = e { names.withLock { $0.formUnion(n) } }
        }
        func wait(_ timeout: Duration = .seconds(3), until condition: (Set<String>, [FolderWatcher.Event]) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition(names.withLock { $0 }, events.withLock { $0 }) { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }

    func watch(_ url: URL) -> (FolderWatcher, Collector) {
        let collector = Collector()
        let watcher = FolderWatcher(folder: url) { collector.add($0) }
        watcher.start(latency: 0.02)
        return (watcher, collector)
    }

    @Test func reportsCreatedRemovedRenamedAndModifiedChildren() async throws {
        let t = try TempDir()
        try t.file("existing.txt", bytes: 1)
        try t.file("old-name.txt", bytes: 1)
        let (watcher, c) = watch(t.url)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100)) // stream running
        try t.file("new.txt", bytes: 3)
        try fm.removeItem(at: t.url.appending(path: "existing.txt"))
        try fm.moveItem(at: t.url.appending(path: "old-name.txt"), to: t.url.appending(path: "renamed.txt"))
        let ok = await c.wait { names, _ in names.isSuperset(of: ["new.txt", "existing.txt", "old-name.txt", "renamed.txt"]) }
        #expect(ok, "\(c.names.withLock { $0 })")
    }

    @Test func ignoresChangesDeeperDown() async throws {
        let t = try TempDir()
        try t.dir("sub/deeper")
        let (watcher, c) = watch(t.url)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        try t.file("sub/deeper/x.txt")
        try t.file("marker.txt")
        _ = await c.wait { names, _ in names.contains("marker.txt") }
        #expect(!c.names.withLock { $0 }.contains("x.txt"))
        #expect(!c.names.withLock { $0 }.contains("deeper"))
    }

    @Test func noticesTheFolderItselfGoingAway() async throws {
        let t = try TempDir()
        let watched = try t.dir("watched")
        let (watcher, c) = watch(watched)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        try fm.moveItem(at: watched, to: t.url.appending(path: "moved-away"))
        let ok = await c.wait { _, events in events.contains(.folderGone) }
        #expect(ok, "\(c.events.withLock { $0 })")
    }

    @Test func burstOf1000FilesIsCoalescedIntoFewEvents() async throws {
        let t = try TempDir()
        let (watcher, c) = watch(t.url)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        for i in 0..<1000 { try t.file("f\(i)") }
        let ok = await c.wait(.seconds(5)) { names, _ in names.count >= 1000 }
        #expect(ok)
        #expect(c.events.withLock { $0.count } < 100, "coalesced: \(c.events.withLock { $0.count }) events for 1000 files")
    }

    @Test func readChangesClassifiesPresentAndGone() throws {
        let t = try TempDir()
        try t.file("here.txt", bytes: 7)
        try t.dir("Folder")
        try t.symlink("link", to: "Folder")
        let changes = LiveChanges.readChanges(["here.txt", "Folder", "gone.txt", "link"], in: t.url)
        #expect(changes.removed == ["gone.txt"])
        let byName = Dictionary(uniqueKeysWithValues: changes.updated.map { ($0.name, $0) })
        #expect(byName["here.txt"]?.size == 7)
        #expect(byName["Folder"]?.isFolder == true)
        #expect(byName["link"]?.isFolder == true, "new links are classified")
    }

    @Test func diffFindsOnlyRealChanges() {
        let a = FileItem(name: "a", kind: .file, size: 1, fileID: 1)
        let b = FileItem(name: "b", kind: .file, size: 2, fileID: 2)
        let b2 = FileItem(name: "b", kind: .file, size: 99, fileID: 2) // modified
        let c = FileItem(name: "c", kind: .file, size: 3, fileID: 3)
        let d = FileItem(name: "d", kind: .file, size: 4, fileID: 4)
        let diff = LiveChanges.diff(old: [a, b, c], new: [a, b2, d])
        #expect(diff.removed == ["c"])
        #expect(Set(diff.updated.map(\.name)) == ["b", "d"])
        #expect(diff.updated.first { $0.name == "b" }?.size == 99)
    }

    @Test func renameIsRecognisedByInode() {
        let old = FolderContents(items: [FileItem(name: "old.txt", kind: .file, fileID: 42), FileItem(name: "x", kind: .file, fileID: 7)])
        let renames = LiveChanges.renames(removed: ["old.txt", "x"], updated: [FileItem(name: "new.txt", kind: .file, fileID: 42)], previous: old)
        #expect(renames == ["old.txt": "new.txt"])
    }

    @Test func applyingLiveChangesMatchesAFreshListing() async throws {
        let t = try TempDir()
        for i in 0..<200 { try t.file("item \(i).txt", bytes: i) }
        var contents = FolderContents(items: try BulkDirectoryLister().listAll(t.url))
        // Simulate a burst of external changes.
        for i in 0..<50 { try fm.removeItem(at: t.url.appending(path: "item \(i).txt")) }
        for i in 0..<30 { try t.file("new \(i).txt", bytes: 1) }
        try Data(repeating: 1, count: 5000).write(to: t.url.appending(path: "item 100.txt"))
        let names = Set((0..<50).map { "item \($0).txt" } + (0..<30).map { "new \($0).txt" } + ["item 100.txt"])
        let changes = LiveChanges.readChanges(names, in: t.url)
        contents = contents.applying(removing: changes.removed, adding: changes.updated)
        let fresh = FolderContents(items: try BulkDirectoryLister().listAll(t.url))
        let a = contents.ordered(by: .default, includeHidden: true)
        let b = fresh.ordered(by: .default, includeHidden: true)
        #expect(a.map(\.name) == b.map(\.name))
        #expect(a.first { $0.name == "item 100.txt" }?.size == 5000)
    }

    @Test func pausedWatcherCatchesUpFromAnEventID() async throws {
        let temp = try TempDir()
        let since = FolderWatcher.currentEventID
        try temp.file("made-while-paused.txt")
        try await Task.sleep(for: .milliseconds(200))
        let box = EventCollector()
        let watcher = FolderWatcher(folder: temp.url) { box.add($0) }
        watcher.start(latency: 0.02, since: since)
        defer { watcher.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !box.events.contains(.rescan) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.events.contains(.rescan))
    }

    @Test func nothingToReplayMeansNoRescan() async throws {
        let temp = try TempDir()
        try await Task.sleep(for: .milliseconds(200))
        let since = FolderWatcher.currentEventID
        let box = EventCollector()
        let watcher = FolderWatcher(folder: temp.url) { box.add($0) }
        watcher.start(latency: 0.02, since: since)
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(!box.events.contains(.rescan))
        try temp.file("live.txt") // then live events as usual
        let deadline = ContinuousClock.now + .seconds(5)
        while !box.events.contains(.changed(["live.txt"])) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.events.contains(.changed(["live.txt"])))
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FolderWatcher.Event] = []
    func add(_ event: FolderWatcher.Event) { lock.withLock { all.append(event) } }
    var events: [FolderWatcher.Event] { lock.withLock { all } }
}

