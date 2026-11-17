import Darwin
import Foundation
import Testing
@testable import FileSystemKit

@Suite("Trash (P2-1)")
struct TrashTests {
    // MARK: History

    @Test func historyRecordsAndPersists() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "history.json")
        let trash = try tmp.dir("trash")
        let source = try tmp.file("a.txt", bytes: 3)
        let history = TrashHistory(file: file)
        let trasher = RecordingTrasher(DirectoryTrasher(directory: trash), history: history)
        let inTrash = try trasher.trash(source)
        history.flushNow() // saved a moment later on its own; at once here

        let reloaded = TrashHistory(file: file)
        var st = stat()
        #expect(lstat(inTrash.path(percentEncoded: false), &st) == 0)
        let path = TrashPaths.canonical(inTrash.path(percentEncoded: false))
        let record = try #require(reloaded.lookup(path, fileID: UInt64(st.st_ino)))
        #expect(record.original == source.path(percentEncoded: false))
        #expect(abs(record.date.timeIntervalSinceNow) < 60)
        // A different item later at the same path isn't mistaken for it.
        #expect(reloaded.lookup(path, fileID: UInt64(st.st_ino) + 1) == nil)
    }

    @Test func recordingManyItemsIsFast() throws {
        let tmp = try TempDir()
        let history = TrashHistory(file: tmp.url.appending(path: "h.json"))
        let start = ContinuousClock.now
        for i in 0..<20_000 { history.record(original: URL(filePath: "/x/\(i)"), inTrash: URL(filePath: "/nowhere/\(i)")) }
        history.flushNow()
        #expect(ContinuousClock.now - start < .seconds(2)) // was quadratic: a copy + file write per item
        #expect(TrashHistory(file: tmp.url.appending(path: "h.json")).count == 20_000)
    }

    @Test func historyPrunesOnlyOldMissingRecords() {
        let history = TrashHistory(file: nil)
        history.record(original: URL(filePath: "/x/old"), inTrash: URL(filePath: "/nowhere/old"), date: .now.addingTimeInterval(-40 * 86_400))
        history.record(original: URL(filePath: "/x/young"), inTrash: URL(filePath: "/nowhere/young"), date: .now)
        history.prune(exists: { _ in false })
        #expect(history.count == 1)
        #expect(history.lookup("/nowhere/young", fileID: 0)?.original == "/x/young")
    }

    // MARK: Finder's .DS_Store

    @Test func readsFinderPutBackData() throws {
        let tmp = try TempDir()
        let trash = try tmp.dir("trash")
        let data = DSStoreWriter.make([
            ("Report.pdf", "ptbL", "Users/me/Documents/"), ("Report.pdf", "ptbN", "Report.pdf"),
            ("Report 2.pdf", "ptbL", "Users/me/Desktop/"), ("Report 2.pdf", "ptbN", "Report.pdf"),
            ("Report 2.pdf", "Iloc", nil), // a non-string record in between is skipped
            ("ünïcode", "ptbL", "Users/me/"),
        ])
        try data.write(to: trash.appending(path: ".DS_Store"))
        let map = FinderPutBack.read(TrashFolder(url: trash, volumeRoot: URL(filePath: "/")))
        #expect(map["Report.pdf"] == "/Users/me/Documents/Report.pdf")
        #expect(map["Report 2.pdf"] == "/Users/me/Desktop/Report.pdf") // renamed in the Trash; put back under its own name
        #expect(map["ünïcode"] == "/Users/me/ünïcode")
    }

    @Test func malformedDSStoreYieldsNothing() {
        #expect(DSStore.records(Data([0, 0, 0, 1]) + Data("Bud1".utf8) + Data(repeating: 0xff, count: 60), codes: ["ptbL"]).isEmpty)
        #expect(DSStore.records(Data(), codes: ["ptbL"]).isEmpty)
        var good = DSStoreWriter.make([("a", "ptbL", "x/")])
        good.removeLast(good.count / 2) // truncated
        #expect(DSStore.records(good, codes: ["ptbL"]).isEmpty)
    }

    // MARK: Listing and sorting

    @Test func listsTrashFoldersWithOrigins() throws {
        let tmp = try TempDir()
        let trashA = try tmp.dir("A/.Trash"), trashB = try tmp.dir("B/.Trashes/501")
        let history = TrashHistory(file: nil)
        let kansio = RecordingTrasher(DirectoryTrasher(directory: trashA), history: history)
        let docs = try tmp.dir("docs")
        let first = docs.appending(path: "first.txt")
        try Data("1".utf8).write(to: first)
        _ = try kansio.trash(first)
        try Data("2".utf8).write(to: trashB.appending(path: "finder.txt")) // trashed by Finder: origin in .DS_Store
        try DSStoreWriter.make([("finder.txt", "ptbL", "projects/"), ("finder.txt", "ptbN", "finder.txt")])
            .write(to: trashB.appending(path: ".DS_Store"))
        try Data("3".utf8).write(to: trashB.appending(path: "unknown.txt"))

        let folders = [TrashFolder(url: trashA, volumeRoot: URL(filePath: "/")),
                       TrashFolder(url: trashB, volumeRoot: tmp.url.appending(path: "B")),
                       TrashFolder(url: tmp.url.appending(path: "missing/.Trashes/501"), volumeRoot: tmp.url)]
        let (entries, errors) = TrashListing.listBlocking(folders, history: history)
        #expect(errors.isEmpty) // a missing Trash folder is not an error
        #expect(entries.map(\.displayName).sorted() == ["finder.txt", "first.txt", "unknown.txt"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.displayName, $0) })
        #expect(byName["first.txt"]?.original == first.path(percentEncoded: false))
        #expect(byName["first.txt"]?.path == TrashPaths.canonical(trashA.appending(path: "first.txt").path(percentEncoded: false)))
        #expect(byName["finder.txt"]?.original == tmp.url.appending(path: "B/projects/finder.txt").path(percentEncoded: false))
        #expect(byName["unknown.txt"]?.original == nil)
        #expect(byName["unknown.txt"]?.dateDeleted != nil) // when it was added to the folder
    }

    @Test func sortsByOriginalLocationAndDateDeleted() {
        func entry(_ name: String, _ original: String?, _ days: Double, folder: Bool = false) -> TrashEntry {
            TrashEntry(item: FileItem(name: "T/" + name, kind: folder ? .directory : .file), displayName: name,
                       original: original, dateDeleted: Date(timeIntervalSinceReferenceDate: days * 86_400))
        }
        let entries = [entry("b", "/Users/me/Desktop/b", 3), entry("a", "/Users/me/Documents/a", 1),
                       entry("c", nil, 2), entry("Folder", "/Users/me/Desktop/Folder", 4, folder: true)]
        let byName = TrashListing.ordered(entries, sort: FileSort(field: .name), key: nil, ascending: true, includeHidden: true)
        #expect(byName.map(\.displayName) == ["Folder", "a", "b", "c"]) // folders first, like a folder
        let byOrigin = TrashListing.ordered(entries, sort: .default, key: .originalLocation, ascending: true, includeHidden: true)
        #expect(byOrigin.map(\.displayName) == ["b", "Folder", "a", "c"]) // Desktop, Desktop, Documents, unknown last
        let newest = TrashListing.ordered(entries, sort: .default, key: .dateDeleted, ascending: false, includeHidden: true)
        #expect(newest.map(\.displayName) == ["Folder", "b", "c", "a"])
    }

    // MARK: Put Back and permanent deletion

    @Test func putBackRecreatesFolderAndNeverReplaces() async throws {
        let tmp = try TempDir()
        let trash = try tmp.dir("trash")
        let gone = tmp.url.appending(path: "gone/deeper/file.txt")
        let item = try tmp.file("trash/file.txt", bytes: 5)
        #expect(await TrashActions.putBack(item, to: gone) == nil)
        #expect(FileManager.default.fileExists(atPath: gone.path(percentEncoded: false)))

        let again = try tmp.file("trash/file.txt", bytes: 7)
        let error = await TrashActions.putBack(again, to: gone)
        #expect(error != nil) // occupied: reported, nothing replaced
        #expect((try? FileManager.default.attributesOfItem(atPath: gone.path(percentEncoded: false))[.size] as? Int) == 5)
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "file.txt").path(percentEncoded: false)))
    }

    @Test func deletesOnlyInsideTheTrash() throws {
        let tmp = try TempDir()
        let trash = try tmp.dir("trash")
        let outside = try tmp.file("keep.txt", bytes: 1)
        let target = try tmp.dir("target")
        try tmp.file("target/precious.txt", bytes: 1)
        let folder = try tmp.dir("trash/folder")
        try tmp.file("trash/folder/x", bytes: 1)
        try tmp.symlink("trash/link", to: target.path(percentEncoded: false))
        let sneaky = trash.appending(path: "../keep.txt") // ".." can't escape the check

        let outcome = TrashActions.deletePermanentlyBlocking(
            [folder, trash.appending(path: "link"), outside, sneaky, trash], within: [trash])
        #expect(outcome.deleted.count == 2)
        #expect(outcome.failed.count == 3) // outside, "..", and the Trash folder itself
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "precious.txt").path(percentEncoded: false))) // link removed, not followed
        #expect(FileManager.default.fileExists(atPath: trash.path(percentEncoded: false)))
    }

    @Test func emptyTrashEmptiesEveryFolder() throws {
        let tmp = try TempDir()
        let a = try tmp.dir("a"), b = try tmp.dir("b")
        try tmp.file("a/1", bytes: 1)
        try tmp.dir("a/sub")
        try tmp.file("a/sub/2", bytes: 1)
        try tmp.file("b/.DS_Store", bytes: 1)
        let keep = try tmp.file("keep", bytes: 1)
        let outcome = TrashActions.emptyBlocking([TrashFolder(url: a, volumeRoot: tmp.url), TrashFolder(url: b, volumeRoot: tmp.url)])
        #expect(outcome.failed.isEmpty && outcome.deleted.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.path(percentEncoded: false)).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: b.path(percentEncoded: false)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))
    }

    // MARK: Network volumes

    @Test func networkVolumesUseTheirOwnTrashFolderOnlyWhenAsked() throws {
        let tmp = try TempDir()
        let share = try tmp.dir("share"), local = try tmp.dir("local"), trash = try tmp.dir("trash")
        let sharePath = share.path(percentEncoded: false)
        let trasher = VolumeAwareTrasher(DirectoryTrasher(directory: trash), networkRoot: { url in
            url.path(percentEncoded: false).hasPrefix(sharePath) ? share : nil
        })
        let remote = try tmp.file("share/doc.txt", bytes: 2)
        #expect(throws: FileSystemError.self) { try trasher.trash(remote) } // refused: the caller asks, then deletes
        #expect(FileManager.default.fileExists(atPath: remote.path(percentEncoded: false)))

        trasher.usesVolumeFolders = true
        let inTrash = try trasher.trash(remote)
        #expect(inTrash.path(percentEncoded: false) == TrashFolders.volumeTrash(root: share).appending(path: "doc.txt").path(percentEncoded: false))
        let near = try tmp.file("local/near.txt", bytes: 1)
        #expect(try trasher.trash(near).deletingLastPathComponent().lastPathComponent == "trash") // local: the base trasher
        _ = local
    }

    // MARK: A real volume's Trash

    @Test func findsAVolumesOwnTrash() throws {
        let volume = try TestVolume()
        let file = volume.url.appending(path: "on-volume.txt")
        try Data("v".utf8).write(to: file)
        let history = TrashHistory(file: nil)
        let inTrash = try RecordingTrasher(SystemTrasher(), history: history).trash(file) // → the image's .Trashes/<uid>
        let home = try TempDir()
        let mounted = Volume(url: volume.url, name: "Test", isRoot: false, isInternal: false, isEjectable: true, isNetwork: false)
        let folders = TrashFolders.discoverBlocking(home: home.url, volumes: [mounted], includeNetwork: false)
        #expect(folders.count == 2) // ~/.Trash (here: a temp "home") + the volume's
        let volumeTrash = try #require(folders.last)
        #expect(volumeTrash.path == TrashPaths.canonicalFolder(TrashFolders.volumeTrash(root: volume.url).path(percentEncoded: false)))
        let (entries, _) = TrashListing.listBlocking([volumeTrash], history: history)
        let entry = try #require(entries.first { $0.displayName == inTrash.lastPathComponent })
        #expect(entry.original == file.path(percentEncoded: false))

        let networkOnly = Volume(url: volume.url, name: "Net", isRoot: false, isInternal: false, isEjectable: false, isNetwork: true)
        #expect(TrashFolders.discoverBlocking(home: home.url, volumes: [networkOnly], includeNetwork: false).count == 1)
        #expect(TrashFolders.discoverBlocking(home: home.url, volumes: [networkOnly], includeNetwork: true).count == 2)
    }
}

/// Writes a minimal valid `.DS_Store` (one leaf node) — the layout Finder uses, to test the reader.
enum DSStoreWriter {
    /// (file name, record code, string value — nil writes a 'blob' record instead).
    static func make(_ records: [(String, String, String?)]) -> Data {
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } }
        // Records sorted by name (case-insensitive), as in a real B-tree.
        let sorted = records.enumerated().sorted { a, b in
            let order = a.element.0.lowercased().compare(b.element.0.lowercased())
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
        var leaf = u32(0) + u32(sorted.count)
        for (name, code, value) in sorted {
            leaf += u32(name.utf16.count) + utf16(name) + Array(code.utf8)
            if let value { leaf += Array("ustr".utf8) + u32(value.utf16.count) + utf16(value) }
            else { leaf += Array("blob".utf8) + u32(3) + [1, 2, 3] }
        }
        // Layout (offsets relative to byte 4): DSDB header at 0x40 (32 bytes), leaf at 0x80 (4 KiB), root at 0x1100.
        let dsdbAddress = 0x40 | 5, leafAddress = 0x80 | 12
        let dsdb = u32(1) + u32(0) + u32(sorted.count) + u32(1) + u32(0x1000) // root node = block 1
        var root = u32(2) + u32(0) + u32(dsdbAddress) + u32(leafAddress)
        root += [UInt8](repeating: 0, count: 4 * 254) // padding to 256 addresses
        root += u32(1) + [4] + Array("DSDB".utf8) + u32(0)
        var file = [UInt8](repeating: 0, count: 4 + 0x1100 + 0x800)
        func put(_ bytes: [UInt8], at offset: Int) { file.replaceSubrange((offset + 4)..<(offset + 4 + bytes.count), with: bytes) }
        file.replaceSubrange(0..<4, with: u32(1))
        put(Array("Bud1".utf8) + u32(0x1100) + u32(0x800) + u32(0x1100), at: 0)
        put(dsdb, at: 0x40)
        put(leaf, at: 0x80)
        put(root, at: 0x1100)
        return Data(file)
    }
}
