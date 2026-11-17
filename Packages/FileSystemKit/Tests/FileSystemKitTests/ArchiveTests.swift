import Darwin
import Foundation
import Testing
@testable import FileSystemKit

/// The bundled 7-Zip, built by Tools/fetch-7zip.sh (KANSIO_7ZZ overrides). Tests that need it are skipped without it.
let sevenZipPath: String? = {
    if let env = ProcessInfo.processInfo.environment["KANSIO_7ZZ"], FileManager.default.isExecutableFile(atPath: env) { return env }
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let build = repo.appending(path: "build")
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: build.path(percentEncoded: false))) ?? []
    for dir in dirs.sorted().reversed() where dir.hasPrefix("7zip-") {
        for arch in ["m_arm64", "m_x64"] {
            let path = build.appending(path: "\(dir)/src/CPP/7zip/Bundles/Alone2/b/\(arch)/7zz").path(percentEncoded: false)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
    }
    return nil
}()

func sevenZip() -> SevenZipEngine? { sevenZipPath.map { SevenZipEngine(executable: URL(filePath: $0)) } }

@Suite("Archives: names and layout (P2-3)")
struct ArchiveNameTests {
    @Test func recognizesArchivesAndTheirBaseNames() {
        #expect(ArchiveNames.archiveExtension("Photos.tar.gz") == "tar.gz")
        #expect(ArchiveNames.archiveExtension("a.7Z") == "7z")
        #expect(ArchiveNames.archiveExtension("notes.txt") == nil)
        #expect(ArchiveNames.archiveExtension(".zip") == nil, "a dot-file named .zip isn't an archive")
        #expect(ArchiveNames.baseName("Photos.tar.gz") == "Photos")
        #expect(ArchiveNames.baseName("report.v2.zip") == "report.v2")
        #expect(ArchiveNames.isStreamed("x.tgz") && !ArchiveNames.isStreamed("x.7z"))
    }

    @Test func suggestsNamesLike7Zip() throws {
        let t = try TempDir()
        let folder = try t.dir("Holiday/Photos")
        let file = try t.file("Holiday/report.pdf")
        let dot = try t.file("Holiday/.env")
        let isFolder: (URL) -> Bool = { $0.hasDirectoryPath }
        #expect(ArchiveNames.suggestedBase(for: [folder], isFolder: isFolder) == "Photos")
        #expect(ArchiveNames.suggestedBase(for: [file], isFolder: isFolder) == "report")
        #expect(ArchiveNames.suggestedBase(for: [dot], isFolder: isFolder) == ".env")
        #expect(ArchiveNames.suggestedBase(for: [folder, file], isFolder: isFolder) == "Holiday")
        try t.file("Holiday/Holiday.7z")
        #expect(ArchiveNames.freeName("Holiday", extension: "7z", in: t.path + "/Holiday") == "Holiday (2).7z")
        #expect(ArchiveNames.freeName("Photos", extension: nil, in: t.path + "/Holiday") == "Photos (2)")
    }

    @Test func layoutRules() {
        func layout(_ paths: [String]) -> ArchiveLayout {
            ArchiveLayout(paths.map { ArchiveEntry(path: $0, isFolder: $0.hasSuffix("/"), size: 1) })
        }
        // (a) files at the top level
        #expect(layout(["a.jpg", "b.jpg"]).filesFolder == "")
        #expect(layout(["a.jpg", "b.jpg"]).singleTopFolder == nil)
        // (b) one folder
        #expect(layout(["Photos/", "Photos/a.jpg", "Photos/b.jpg"]).filesFolder == "Photos")
        #expect(layout(["Photos/a.jpg", "Photos/b.jpg"]).singleTopFolder == "Photos", "folder entries may be missing")
        // (c) a chain of folders
        #expect(layout(["Photos/2024/a.jpg", "Photos/2024/b.jpg", "Photos/empty/"]).filesFolder == "Photos/2024")
        // (d) top level and a folder
        #expect(layout(["readme.txt", "Photos/a.jpg"]).filesFolder == nil)
        #expect(layout(["readme.txt", "Photos/a.jpg"]).topLevel == ["readme.txt", "Photos"])
        #expect(layout(["only.txt"]).singleTopFolder == nil, "a single file isn't a single folder")
    }

    @Test func parses7ZipListing() {
        let text = """
        Path = Folder
        Size = 0
        Attributes = D drwxr-xr-x
        Encrypted = -

        Path = Folder/a b.txt
        Size = 1988895
        Attributes = A -rw-r--r--
        Encrypted = -

        Path = Folder/link
        Size = 5
        Attributes = A lrwxr-xr-x
        Encrypted = +

        """
        let entries = SevenZipEngine.parseListing(text)
        #expect(entries.count == 3)
        #expect(entries[0] == ArchiveEntry(path: "Folder", isFolder: true))
        #expect(entries[1].path == "Folder/a b.txt" && entries[1].size == 1_988_895 && !entries[1].isFolder)
        #expect(entries[2].isSymlink && entries[2].isEncrypted)
    }

    @Test func progressParsing() {
        #expect(ArchiveProcess.lastPercent(Data("  0%\u{8}\u{8}\u{8} 45% 12 - a.txt\u{8}\u{8} 67%".utf8)) == 67)
        #expect(ArchiveProcess.lastPercent(Data("1234 files".utf8)) == nil)
    }

    @Test func verificationFindsMissingAndChangedFiles() throws {
        let t = try TempDir()
        try t.dir("F/sub")
        try t.file("F/a.txt", bytes: 10)
        try t.file("F/sub/b.txt", bytes: 3)
        let tree = ArchiveSource.scan(base: t.url, items: ["F"], cancel: CancellationFlag())
        let good = [ArchiveEntry(path: "F/a.txt", isFolder: false, size: 10), ArchiveEntry(path: "F/sub/b.txt", isFolder: false, size: 3)]
        #expect(ArchiveSource.mismatch(tree, good) == nil, "folders implied by paths count")
        #expect(ArchiveSource.mismatch(tree, [good[0]])?.contains("missing") == true)
        #expect(ArchiveSource.mismatch(tree, [good[0], ArchiveEntry(path: "F/sub/b.txt", isFolder: false, size: 4)])?.contains("size") == true)
    }
}

@Suite("Archives: engines and operations (P2-3)", .serialized)
struct ArchiveOperationTests {
    let fm = FileManager.default
    func path(_ u: URL) -> String { u.path(percentEncoded: false) }
    func text(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }
    func names(_ u: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: path(u)).sorted() }
    func noPartials(_ u: URL) throws -> Bool { try names(u).allSatisfy { !$0.hasPrefix(".kansio-partial-") } }

    /// "Tree/": a.txt, ünï.txt (decomposed), sub/b.txt, empty/, link → a.txt
    func makeTree(_ t: TempDir, in parent: String = "src") throws -> URL {
        let root = try t.dir("\(parent)/Tree")
        try t.dir("\(parent)/Tree/sub")
        try t.dir("\(parent)/Tree/empty")
        try Data((0..<50_000).map { UInt8($0 % 251) }).write(to: root.appending(path: "a.txt"))
        try Data("unicode".utf8).write(to: root.appending(path: "u\u{0308}ni\u{0308}.txt"))
        try Data("bee".utf8).write(to: root.appending(path: "sub/b.txt"))
        try t.symlink("\(parent)/Tree/link", to: "a.txt")
        return root
    }

    func checkTree(_ root: URL) throws {
        #expect(try Data(contentsOf: root.appending(path: "a.txt")).count == 50_000)
        #expect(try text(root.appending(path: "sub/b.txt")) == "bee")
        let names = try fm.contentsOfDirectory(atPath: path(root))
        #expect(names.contains { $0 == "ünï.txt" }, "unicode name (canonically equal): \(names)")
        #expect(names.contains("empty"))
        #expect(try fm.destinationOfSymbolicLink(atPath: path(root.appending(path: "link"))) == "a.txt", "symlinks stay links")
    }

    func engines() -> [any ArchiveEngine] {
        var list: [any ArchiveEngine] = []
        if let z = sevenZip() { list.append(z) }
        if LibArchiveEngine.isAvailable { list.append(LibArchiveEngine()) }
        return list
    }

    @Test(arguments: ArchiveFormat.allCases)
    func roundTripWithEveryEngineAndAcrossEngines(format: ArchiveFormat) async throws {
        let all = engines()
        try #require(all.count == 2, "needs 7zz (Tools/fetch-7zip.sh) and libarchive")
        for writer in all {
            for reader in all {
                let t = try TempDir()
                let tree = try makeTree(t)
                let ops = ArchiveOperations(engines: [writer])
                let made = await ops.compress([tree], name: "Tree.\(format.fileExtension)", format: format, level: .normal, verify: true)
                #expect(made.error == nil, "\(writer.name) \(format): \(String(describing: made.error))")
                let archive = try #require(made.archive)
                #expect(archive.lastPathComponent == "Tree.\(format.fileExtension)")
                #expect(try noPartials(t.url.appending(path: "src")))
                // The archive is portable: no extended attributes, no ._ files, no __MACOSX.
                let listed = try reader.list(archive, cancel: CancellationFlag())
                #expect(!listed.contains { $0.path.contains("__MACOSX") || $0.path.hasPrefix("._") || $0.path.contains("/._") })

                let out = try t.dir("out")
                let extracted = await ArchiveOperations(engines: [reader]).extract([archive], mode: .here, into: out)
                #expect(extracted.errors.isEmpty, "\(writer.name)→\(reader.name) \(format): \(extracted.errors)")
                try checkTree(out.appending(path: "Tree"))
                #expect(extracted.created.map(\.lastPathComponent) == ["Tree"])
                #expect(try noPartials(out))
            }
        }
    }

    @Test func compressNamesNeverReplace() async throws {
        let t = try TempDir()
        let tree = try makeTree(t)
        let ops = ArchiveOperations(engines: engines())
        let first = await ops.compress([tree], name: "Tree.7z", format: .sevenZip, level: .fast, verify: false)
        let second = await ops.compress([tree], name: "Tree.7z", format: .sevenZip, level: .fast, verify: false)
        #expect(first.archive?.lastPathComponent == "Tree.7z")
        #expect(second.archive?.lastPathComponent == "Tree (2).7z")
        // Several items: listed relative to their folder.
        let other = try t.file("src/note.txt", bytes: 5)
        let both = await ops.compress([tree, other], name: "src.zip", format: .zip, level: .normal, verify: true)
        let listed = try ops.listWithFallback(try #require(both.archive), cancel: CancellationFlag())
        #expect(Set(ArchiveLayout(listed).topLevel) == ["Tree", "note.txt"])
    }

    @Test func extractAsFolderAndSingleTopFolder() async throws {
        let t = try TempDir()
        let tree = try makeTree(t)
        let loose = try t.file("src/loose.txt", bytes: 3)
        let ops = ArchiveOperations(engines: engines())
        let single = try #require(await ops.compress([tree], name: "Single.7z", format: .sevenZip, level: .fast, verify: false).archive)
        let multi = try #require(await ops.compress([tree, loose], name: "Multi.zip", format: .zip, level: .fast, verify: false).archive)
        let out = try t.dir("out")

        let a = await ops.extract([multi], mode: .asFolder, into: out)
        #expect(a.created.map(\.lastPathComponent) == ["Multi"])
        #expect(try names(out.appending(path: "Multi")) == ["Tree", "loose.txt"])
        let b = await ops.extract([multi], mode: .asFolder, into: out)
        #expect(b.created.map(\.lastPathComponent) == ["Multi (2)"], "never into an existing folder")

        let c = await ops.extract([single], mode: .asFolder, into: out)
        #expect(c.created.map(\.lastPathComponent) == ["Tree"], "a single top-level folder isn't wrapped in another")
        try checkTree(out.appending(path: "Tree"))
        #expect(try noPartials(out))
    }

    @Test func extractHereAsksAboutClashes() async throws {
        let t = try TempDir()
        let tree = try makeTree(t)
        let archive = try #require(await ArchiveOperations(engines: engines())
            .compress([tree], name: "Tree.7z", format: .sevenZip, level: .fast, verify: false).archive)
        let out = try t.dir("out")
        try t.dir("out/Tree")
        try Data("mine".utf8).write(to: out.appending(path: "Tree/a.txt"))

        let skip = await ArchiveOperations(engines: engines()).extract([archive], mode: .here, into: out)
        #expect(skip.skipped.count == 1, "default: skip")
        #expect(try text(out.appending(path: "Tree/a.txt")) == "mine")

        let trash = DirectoryTrasher(directory: t.url.appending(path: "trash", directoryHint: .isDirectory))
        let keepBoth = await ArchiveOperations(engines: engines(), trasher: trash, resolver: { _ in .keepBoth })
            .extract([archive], mode: .here, into: out)
        #expect(keepBoth.created.map(\.lastPathComponent) == ["Tree (2)"])
        #expect(try text(out.appending(path: "Tree/a.txt")) == "mine")

        // Merge: only the clashing file is asked about; Replace sends the existing one to the Trash.
        let merge = await ArchiveOperations(engines: engines(), trasher: trash, resolver: { $0.existingIsFolder ? .merge : .replace })
            .extract([archive], mode: .here, into: out)
        #expect(merge.errors.isEmpty, "\(merge.errors)")
        #expect(try Data(contentsOf: out.appending(path: "Tree/a.txt")).count == 50_000)
        #expect(merge.replaced.count == 1)
        #expect(try text(trash.directory.appending(path: "a.txt")) == "mine")
        #expect(try noPartials(out))
    }

    @Test func flatExtractChecksFirstThenGathersFiles() async throws {
        let t = try TempDir()
        let ops = ArchiveOperations(engines: engines(), resolver: { _ in .keepBoth })
        // part1: files at the top; part2: files in a chain of folders; bad: files in two places.
        try t.dir("p1")
        try Data("1".utf8).write(to: t.url.appending(path: "p1/one.txt"))
        try Data("dup-1".utf8).write(to: t.url.appending(path: "p1/same.txt"))
        try t.dir("p2/Photos/2024")
        try t.dir("p2/Photos/empty")
        try Data("2".utf8).write(to: t.url.appending(path: "p2/Photos/2024/two.txt"))
        try Data("dup-2".utf8).write(to: t.url.appending(path: "p2/Photos/2024/same.txt"))
        try t.dir("p3/Sub")
        try Data("x".utf8).write(to: t.url.appending(path: "p3/top.txt"))
        try Data("y".utf8).write(to: t.url.appending(path: "p3/Sub/deep.txt"))
        let part1 = try #require(await ops.compress([t.url.appending(path: "p1/one.txt"), t.url.appending(path: "p1/same.txt")],
                                                    name: "Holiday-part1.zip", format: .zip, level: .fast, verify: false).archive)
        let part2 = try #require(await ops.compress([t.url.appending(path: "p2/Photos")], name: "Holiday-part2.7z",
                                                    format: .sevenZip, level: .fast, verify: false).archive)
        let bad = try #require(await ops.compress([t.url.appending(path: "p3/top.txt"), t.url.appending(path: "p3/Sub")],
                                                  name: "bad.7z", format: .sevenZip, level: .fast, verify: false).archive)
        let out = try t.dir("out")

        let refused = await ops.extract([part1, bad], mode: .flat(name: "Holiday-part1"), into: out)
        #expect(refused.errors.first?.error.description.contains("more than one folder") == true)
        #expect(refused.errors.first?.url == bad)
        #expect(try names(out).isEmpty, "nothing is extracted when an archive doesn't qualify")

        let flat = await ops.extract([part1, part2], mode: .flat(name: "Holiday-part1"), into: out)
        #expect(flat.errors.isEmpty, "\(flat.errors)")
        #expect(flat.created.map(\.lastPathComponent) == ["Holiday-part1"])
        #expect(try names(out.appending(path: "Holiday-part1")) == ["one.txt", "same (2).txt", "same.txt", "two.txt"],
                "the folders are left out; a duplicate name went to the conflict resolver (Keep Both)")
        #expect(try noPartials(out))
    }

    @Test func cancelLeavesNothingBehind() async throws {
        let t = try TempDir()
        let src = try t.dir("src")
        // Incompressible data so it takes a while at Maximum.
        var bytes = [UInt8](repeating: 0, count: 48 << 20)
        arc4random_buf(&bytes, bytes.count)
        try Data(bytes).write(to: src.appending(path: "big.bin"))
        for engine in engines() {
            let task = Task {
                await ArchiveOperations(engines: [engine]).compress([src.appending(path: "big.bin")], name: "big.7z",
                                                                    format: .sevenZip, level: .maximum, verify: false)
            }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()
            let result = await task.value
            #expect(result.cancelled && result.archive == nil, "\(engine.name)")
            let left = try names(src)
            #expect(left == ["big.bin"], "\(engine.name): no partial archive left: \(left)")
        }
    }

    @Test func passwordProtectedArchivesSayNotSupported() async throws {
        let z = try #require(sevenZipPath)
        let t = try TempDir()
        try Data("secret".utf8).write(to: t.url.appending(path: "s.txt"))
        let run = ArchiveProcess.run(URL(filePath: z), ["a", "-pPW", "-mhe=on", "-bso0", "-bsp0", path(t.url.appending(path: "enc.7z")), "s.txt"],
                                     cwd: t.url, cancel: CancellationFlag())
        #expect(run.status == 0)
        let out = try t.dir("out")
        let result = await ArchiveOperations(engines: engines()).extract([t.url.appending(path: "enc.7z")], mode: .here, into: out)
        #expect(result.errors.first?.error.description.contains("Password-protected") == true, "\(result.errors)")
        #expect(try names(out).isEmpty)
    }

    @Test func entriesThatClimbOutAreNotWrittenOutside() async throws {
        let t = try TempDir()
        try t.dir("make")
        try Data("evil".utf8).write(to: t.url.appending(path: "make/evil.txt"))
        // An archive whose entry is "../evil.txt" (bsdtar -P keeps it; -s rewrites the name).
        let run = ArchiveProcess.run(URL(filePath: "/usr/bin/tar"), ["-cPf", path(t.url.appending(path: "evil.tar")), "-s", "|^|../|", "evil.txt"],
                                     cwd: t.url.appending(path: "make"), cancel: CancellationFlag())
        #expect(run.status == 0, "\(run.stderr)")
        for engine in engines() {
            let box = try t.dir("box-\(engine.name)/inside")
            _ = await ArchiveOperations(engines: [engine]).extract([t.url.appending(path: "evil.tar")], mode: .here, into: box)
            #expect(!fm.fileExists(atPath: path(box.deletingLastPathComponent().appending(path: "evil.txt"))), "\(engine.name) wrote outside")
            #expect(try noPartials(box))
        }
    }

    @Test func fallsBackToTheNextEngine() async throws {
        struct Refuses: ArchiveEngine {
            var name: String { "refuses" }
            func list(_ archive: URL, cancel: CancellationFlag) throws(FileSystemError) -> [ArchiveEntry] {
                throw ArchiveError.unreadable(archive.path(percentEncoded: false), "unsupported")
            }
            func create(_ archive: URL, base: URL, items: [String], format: ArchiveFormat, level: ArchiveLevel,
                        cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {}
            func extract(_ archive: URL, into folder: URL, cancel: CancellationFlag,
                         progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
                try? Data("junk".utf8).write(to: folder.appending(path: "partial"))
                throw ArchiveError.unreadable(archive.path(percentEncoded: false), "unsupported")
            }
        }
        let t = try TempDir()
        let tree = try makeTree(t)
        let archive = try #require(await ArchiveOperations(engines: [LibArchiveEngine()])
            .compress([tree], name: "Tree.zip", format: .zip, level: .fast, verify: false).archive)
        let out = try t.dir("out")
        let result = await ArchiveOperations(engines: [Refuses(), LibArchiveEngine()]).extract([archive], mode: .here, into: out)
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(try names(out) == ["Tree"], "the first engine's partial output is gone")
    }
}
