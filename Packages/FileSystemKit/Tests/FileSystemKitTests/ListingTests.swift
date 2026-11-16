import Darwin
import Foundation
import Synchronization
import Testing
@testable import FileSystemKit

@Suite("Directory listing")
struct ListingTests {
    /// A folder exercising every kind of entry we care about.
    static func makeMixedFolder() throws -> (TempDir, Set<String>) {
        let t = try TempDir()
        try t.file("plain.txt", bytes: 1234)
        try t.file("empty")
        try t.file(".dotfile", bytes: 3)
        let flagged = try t.file("flagged-hidden.txt", bytes: 5)
        #expect(chflags(flagged.path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)
        try t.dir("Folder")
        try t.dir("Fake.app/Contents/MacOS")
        try t.symlink("link-to-file", to: "plain.txt")
        try t.symlink("link-to-folder", to: "Folder")
        try t.symlink("broken-link", to: "does-not-exist")
        try t.file("Cafe\u{0301}.txt", bytes: 10) // NFD é
        try t.file("名前 🎉.txt", bytes: 7)
        let long = String(repeating: "x", count: 251) + ".txt" // 255 bytes, the APFS limit
        try t.file(long, bytes: 1)
        #expect(mkfifo(t.url.appending(path: "fifo").path(percentEncoded: false), 0o644) == 0)
        let names: Set<String> = [
            "plain.txt", "empty", ".dotfile", "flagged-hidden.txt", "Folder", "Fake.app", "link-to-file",
            "link-to-folder", "broken-link", "Cafe\u{0301}.txt", "名前 🎉.txt", long, "fifo",
        ]
        return (t, names)
    }

    @Test func bulkListsEverythingWithCorrectMetadata() throws {
        let (t, expected) = try Self.makeMixedFolder()
        let items = try BulkDirectoryLister().listAll(t.url)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == expected)

        #expect(byName["plain.txt"]?.kind == .file)
        #expect(byName["plain.txt"]?.size == 1234)
        #expect(byName["empty"]?.size == 0)
        #expect(byName["Folder"]?.kind == .directory)
        #expect(byName["Folder"]?.isFolder == true)
        #expect(byName["Fake.app"]?.isPackage == true)
        #expect(byName["Fake.app"]?.isFolder == false)
        #expect(byName["link-to-file"]?.kind == .symlink)
        #expect(byName["link-to-folder"]?.kind == .symlink) // never followed
        #expect(byName["broken-link"]?.kind == .symlink)
        #expect(byName["fifo"]?.kind == .other)
        #expect(byName[".dotfile"]?.isHidden == true)
        #expect(byName["flagged-hidden.txt"]?.isHidden == true)
        #expect(byName["plain.txt"]?.isHidden == false)
        #expect(items.allSatisfy { $0.fileID != 0 })
        #expect(items.allSatisfy { !$0.flags.contains(.hadError) && !$0.flags.contains(.dataless) })
    }

    @Test func bulkMatchesFoundationReference() throws {
        let (t, _) = try Self.makeMixedFolder()
        let bulk = try BulkDirectoryLister().listAll(t.url)
        let reference = try FoundationDirectoryLister().listAll(t.url)
        let ref = Dictionary(uniqueKeysWithValues: reference.map { ($0.name, $0) })
        #expect(bulk.count == reference.count)
        for item in bulk {
            let r = try #require(ref[item.name], "missing \(item.name) in reference")
            #expect(item.kind == r.kind, "\(item.name)")
            #expect(item.size == r.size, "\(item.name)")
            #expect(item.flags == r.flags, "\(item.name)")
            #expect(item.fileID == r.fileID, "\(item.name)")
            #expect(abs(item.modificationDate.timeIntervalSince(r.modificationDate)) < 0.001, "\(item.name)")
            #expect(abs(item.creationDate.timeIntervalSince(r.creationDate)) < 0.001, "\(item.name)")
        }
    }

    @Test func customIconFlagComesFromFinderInfo() throws {
        let t = try TempDir()
        let u = try t.file("custom.txt")
        try t.file("plain.txt")
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04 // finderFlags (big-endian) = kHasCustomIcon 0x0400
        let rc = setxattr(u.path(percentEncoded: false), "com.apple.FinderInfo", info, info.count, 0, 0)
        #expect(rc == 0)
        let byName = Dictionary(uniqueKeysWithValues: try BulkDirectoryLister().listAll(t.url).map { ($0.name, $0) })
        #expect(byName["custom.txt"]?.flags.contains(.customIcon) == true)
        #expect(byName["plain.txt"]?.flags.contains(.customIcon) == false)
    }

    @Test func coalescingMergesBatches() async throws {
        let t = try TempDir()
        for i in 0..<2000 { try t.file("c\(i)") }
        let lister = BulkDirectoryLister(bufferSize: 4096)
        var raw = 0, merged = 0
        for try await _ in lister.batches(of: t.url) { raw += 1 }
        for try await _ in lister.batches(of: t.url, coalescing: .seconds(5)) { merged += 1 }
        #expect(raw > 10)
        #expect(merged == 1)
    }

    @Test func pathExtension() {
        #expect(FileItem(name: "a.TXT", kind: .file).pathExtension == "txt")
        #expect(FileItem(name: ".bashrc", kind: .file).pathExtension == "")
        #expect(FileItem(name: "archive.tar.gz", kind: .file).pathExtension == "gz")
        #expect(FileItem(name: "noext", kind: .file).pathExtension == "")
        #expect(FileItem(name: "trailing.", kind: .file).pathExtension == "")
    }

    @Test func readItemMatchesListing() throws {
        let (t, names) = try Self.makeMixedFolder()
        let listed = Dictionary(uniqueKeysWithValues: try BulkDirectoryLister().listAll(t.url).map { ($0.name, $0) })
        for name in names {
            let single = try BulkDirectoryLister.readItem(at: t.url.appending(path: name))
            #expect(single == listed[name], "\(name)")
        }
        #expect(throws: FileSystemError.self) { try BulkDirectoryLister.readItem(at: t.url.appending(path: "nope")) }
    }

    @Test func reportsExactModificationDate() throws {
        let t = try TempDir()
        let u = try t.file("dated.txt")
        let date = Date(timeIntervalSince1970: 1_600_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path(percentEncoded: false))
        let item = try #require(try BulkDirectoryLister().listAll(t.url).first)
        #expect(abs(item.modificationDate.timeIntervalSince(date)) < 0.000_01)
    }

    @Test func unicodeNamesArePreservedAndCompareCanonically() throws {
        let t = try TempDir()
        let nfd = "Cafe\u{0301}.txt"
        try t.file(nfd)
        let item = try #require(try BulkDirectoryLister().listAll(t.url).first)
        // Swift String equality is canonical equivalence: NFD == NFC.
        #expect(item.name == "Caf\u{00E9}.txt")
        // APFS preserves the bytes as created; we must not normalize them (or opening would fail on HFS+ edge cases).
        #expect(Array(item.name.utf8) == Array(nfd.utf8))
    }

    @Test func emptyDirectory() throws {
        let t = try TempDir()
        #expect(try BulkDirectoryLister().listAll(t.url).isEmpty)
        #expect(try FoundationDirectoryLister().listAll(t.url).isEmpty)
    }

    @Test(arguments: [4096, 16 * 1024, 128 * 1024])
    func manyEntriesAcrossBatches(bufferSize: Int) throws {
        let t = try TempDir()
        let names = (0..<3000).map { "file-\($0)-\(String(repeating: "n", count: $0 % 40)).dat" }
        for n in names { try t.file(n) }
        var batchCount = 0
        var seen: [String] = []
        try BulkDirectoryLister(bufferSize: bufferSize).list(t.url) { batch in
            batchCount += 1
            seen += batch.map(\.name)
            return true
        }
        #expect(seen.count == names.count)
        #expect(Set(seen) == Set(names))
        if bufferSize == 4096 { #expect(batchCount > 10) }
    }

    @Test func stopsWhenCallbackReturnsFalse() throws {
        let t = try TempDir()
        for i in 0..<2000 { try t.file("f\(i)") }
        var batches = 0
        try BulkDirectoryLister(bufferSize: 4096).list(t.url) { _ in
            batches += 1
            return false
        }
        #expect(batches == 1)
    }

    @Test func errors() throws {
        let t = try TempDir()
        let file = try t.file("a-file")
        let locked = try t.dir("locked")
        try t.file("locked/inside")
        #expect(chmod(locked.path(percentEncoded: false), 0) == 0)
        defer { chmod(locked.path(percentEncoded: false), 0o755) }

        for lister in [BulkDirectoryLister() as any DirectoryLister, FoundationDirectoryLister()] {
            let missing = t.url.appending(path: "missing")
            #expect(throws: FileSystemError(.notFound, path: missing.path(percentEncoded: false))) {
                try lister.listAll(missing)
            }
            #expect(throws: FileSystemError(.notADirectory, path: file.path(percentEncoded: false))) {
                try lister.listAll(file)
            }
            #expect(throws: FileSystemError(.permissionDenied, path: locked.path(percentEncoded: false))) {
                try lister.listAll(locked)
            }
        }
    }

    @Test func streamDeliversAllBatches() async throws {
        let t = try TempDir()
        for i in 0..<1500 { try t.file("s\(i)") }
        var total = 0
        for try await batch in BulkDirectoryLister(bufferSize: 4096).batches(of: t.url) { total += batch.count }
        #expect(total == 1500)
    }

    @Test func streamPropagatesErrors() async throws {
        let t = try TempDir()
        await #expect(throws: FileSystemError.self) {
            for try await _ in BulkDirectoryLister().batches(of: t.url.appending(path: "nope")) {}
        }
    }

    @Test func abandoningStreamStopsTheBlockingListing() async throws {
        let lister = SlowLister(batches: 1000)
        var received = 0
        for try await _ in lister.batches(of: URL(filePath: "/unused")) {
            received += 1
            if received == 2 { break }
        }
        // Production may run ahead of a slow consumer, but must stop soon after it leaves.
        let atBreak = lister.produced.value.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(150))
        let after = lister.produced.value.load(ordering: .relaxed)
        #expect(after - atBreak < 10, "listing kept running after the consumer stopped: \(after - atBreak) more batches")
        #expect(after < 1000)
    }

    @Test func cancellingConsumerTaskStopsListing() async throws {
        let lister = SlowLister(batches: 1000)
        let task = Task {
            var n = 0
            for try await _ in lister.batches(of: URL(filePath: "/unused")) { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = try? await task.value
        let atCancel = lister.produced.value.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(150))
        let after = lister.produced.value.load(ordering: .relaxed)
        #expect(after - atCancel < 10)
        #expect(after < 1000)
    }
}

/// Emits one tiny batch per millisecond, counting how many it produced.
struct SlowLister: DirectoryLister {
    final class Counter: Sendable { let value = Atomic<Int>(0) }
    let batches: Int
    let produced = Counter()

    func list(_ directory: URL, onBatch: ([FileItem]) -> Bool) throws(FileSystemError) {
        for i in 0..<batches {
            usleep(1000)
            produced.value.add(1, ordering: .relaxed)
            if !onBatch([FileItem(name: "item\(i)", kind: .file)]) { return }
        }
    }
}
