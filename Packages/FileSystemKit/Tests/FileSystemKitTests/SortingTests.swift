import Foundation
import Testing
@testable import FileSystemKit

@Suite("Sorting")
struct SortingTests {
    static let locale = Locale(identifier: "en_US")

    static func reference(_ names: [String]) -> [String] {
        names.sorted { NameCollation.compare($0, $1, locale: locale) == .orderedAscending }
    }

    static func ours(_ names: [String]) -> [String] {
        NameCollation.sortedIndices(of: names, locale: locale).map { names[Int($0)] }
    }

    @Test func matchesLocalizedStandardCompareOnTrickyNames() {
        let names = [
            "file10.txt", "file2.txt", "file1.txt", "File3.txt", "file02.txt", "a", "B", "b", "Ä", "z", "Zebra",
            "émile", "Emile", "emile", "_under", "-dash", "(paren)", "🎉party", "名前", "１２", "12", "3",
            "Cafe\u{0301}", "Caf\u{00E9}x", "a b", "a  b", "ab", ".hidden", "IMG_0010.JPG", "IMG_9.JPG", "",
        ]
        #expect(Self.ours(names) == Self.reference(names))
        // Spot-check the Finder behaviours users notice:
        let sorted = Self.ours(["file10", "file2", "file1"])
        #expect(sorted == ["file1", "file2", "file10"])
    }

    @Test(arguments: [2, 4095, 4096 * 3, 4096 * 5 + 7, 50_000])
    func matchesReferenceAtScale(count: Int) {
        var rng = SeededGenerator(seed: UInt64(count))
        let words = ["File", "file", "Report", "IMG_", "Ärger", "zebra", "draft", "名前", "naïve", "Backup", "ｆｕｌｌ"]
        let names = (0..<count).map { i in
            "\(words[Int(rng.next() % UInt64(words.count))]) \(rng.next() % 100_000) #\(i)"
        }
        #expect(Self.ours(names) == Self.reference(names))
    }

    @Test func icuPreSortIsAvailable() {
        // Not a hard requirement (we fall back to CF), but on supported macOS it must be there
        // or 100k-item folders miss their sort budget.
        #expect(NameCollation.usesICU)
    }

    /// Pathological names mixing scripts, ligatures, combining marks and full-width letters.
    /// ICU disagrees with CF on some of these, and CF's own comparator is *inconsistent* on a
    /// few (e.g. "å…" vs full-width "Ａ…"), so no algorithm can match "the" reference exactly.
    /// Requirement: a permutation that is at least as well sorted as a plain CF sort.
    @Test(arguments: [3000, 30_000])
    func pathologicalNamesAreAtLeastAsSortedAsReference(count: Int) {
        var rng = SeededGenerator(seed: 7 &+ UInt64(count))
        let alphabet = Array("aAbBzZäÄöÖåÅéÉçñßæøœ0123456789１２３ -_.,()[]{}#@!~+=&'’\"/:;ａＡıİǅ\u{0301}\u{0308}ﬁﬀ½²³ⅨⅣ名前日本語中文한국어αβΓΔабвЖשלוםمرحبا🎉👩‍👩‍👧⌘•–—")
        var names = Set<String>()
        while names.count < count {
            let length = 1 + Int(rng.next() % 12)
            names.insert(String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }))
            if rng.next() % 4 == 0 { names.insert("file\(rng.next() % 2000)\(["", ".txt", " copy", "-2"][Int(rng.next() % 4)])") }
        }
        let list = Array(names)
        func inversions(_ a: [String]) -> Int {
            (1..<a.count).filter { NameCollation.compare(a[$0 - 1], a[$0], locale: Self.locale) == .orderedDescending }.count
        }
        let ours = Self.ours(list)
        #expect(Set(ours) == names && ours.count == list.count)
        #expect(inversions(ours) <= inversions(Self.reference(list)))
        #expect(inversions(ours) <= count / 500) // a handful, never a scrambled order
    }

    /// The ICU pre-sort must not change the result where CF's comparator is consistent.
    @Test func icuPathMatchesCFOnlyPathOnRealisticNames() {
        var rng = SeededGenerator(seed: 99)
        let words = ["Report", "ﬁle", "ｆｕｌｌ", "Ärger", "naïve", "IMG_", "名前", "Résumé", "zebra", "Backup", "１２3"]
        let names = (0..<20_000).map { "\(words[Int(rng.next() % UInt64(words.count))]) \(rng.next() % 50_000) #\($0)" }
        let withICU = NameCollation.sortedIndices(of: names, locale: Self.locale)
        let cfOnly = NameCollation.sortedIndices(of: names, locale: Self.locale, allowICU: false)
        #expect(withICU == cfOnly)
        #expect(withICU.map { names[Int($0)] } == Self.reference(names))
    }

    @Test func ranksAreInversePermutation() {
        let names = ["c", "a", "b"]
        #expect(NameCollation.ranks(of: names, locale: Self.locale) == [2, 0, 1])
        #expect(NameCollation.ranks(of: [], locale: Self.locale) == [])
    }

    static let items: [FileItem] = [
        FileItem(name: "b.txt", kind: .file, size: 300, modificationDate: Date(timeIntervalSince1970: 3)),
        FileItem(name: "A folder", kind: .directory, modificationDate: Date(timeIntervalSince1970: 9)),
        FileItem(name: "a.txt", kind: .file, size: 100, modificationDate: Date(timeIntervalSince1970: 5)),
        FileItem(name: ".secret", kind: .file, flags: .hidden, size: 1, modificationDate: Date(timeIntervalSince1970: 1)),
        FileItem(name: "Zed folder", kind: .directory, modificationDate: Date(timeIntervalSince1970: 1)),
        FileItem(name: "c.txt", kind: .file, size: 100, modificationDate: Date(timeIntervalSince1970: 5)),
        FileItem(name: "App.app", kind: .directory, flags: .package, modificationDate: Date(timeIntervalSince1970: 2)),
    ]

    func names(_ sort: FileSort, hidden: Bool = false) -> [String] {
        FolderContents(items: Self.items, locale: Self.locale).ordered(by: sort, includeHidden: hidden).map(\.name)
    }

    @Test func nameAscendingPutsFoldersFirstAndPackagesWithFiles() {
        #expect(names(.init(field: .name)) == ["A folder", "Zed folder", "a.txt", "App.app", "b.txt", "c.txt"])
    }

    @Test func descendingReversesEverything() {
        #expect(names(.init(field: .name, ascending: false)) == ["c.txt", "b.txt", "App.app", "a.txt", "Zed folder", "A folder"])
    }

    @Test func hiddenItemsOnlyWhenRequested() {
        #expect(!names(.init(field: .name)).contains(".secret"))
        #expect(names(.init(field: .name), hidden: true).contains(".secret"))
    }

    @Test func sizeSortUsesNameAsTieBreaker() {
        #expect(names(.init(field: .size)) == ["A folder", "Zed folder", "App.app", "a.txt", "c.txt", "b.txt"])
    }

    @Test func dateSortUsesNameAsTieBreaker() {
        #expect(names(.init(field: .dateModified)) == ["Zed folder", "A folder", "App.app", "b.txt", "a.txt", "c.txt"])
    }

    @Test func kindDescriptions() {
        #expect(FileKind.description(for: FileItem(name: "Docs", kind: .directory)) == FileKind.folder)
        #expect(FileKind.description(for: FileItem(name: "x.zzqx", kind: .file)) == "ZZQX file")
        #expect(FileKind.description(for: FileItem(name: "link", kind: .symlink)) == FileKind.alias)
        let pdf = FileKind.description(for: FileItem(name: "a.pdf", kind: .file))
        #expect(!pdf.isEmpty && pdf != "PDF file") // a real localized description
        let app = FileKind.description(for: FileItem(name: "A.app", kind: .directory, flags: .package))
        #expect(app != FileKind.folder && !app.isEmpty)
    }

    @Test func kindSortGroupsByDescriptionThenName() {
        let items = [
            FileItem(name: "b.zzqb", kind: .file), FileItem(name: "a.zzqb", kind: .file),
            FileItem(name: "c.zzqa", kind: .file), FileItem(name: "Folder", kind: .directory),
        ]
        let names = FolderContents(items: items, locale: Self.locale).ordered(by: .init(field: .kind), includeHidden: true).map(\.name)
        #expect(names == ["Folder", "c.zzqa", "a.zzqb", "b.zzqb"])
    }

    @Test func emptyContents() {
        #expect(FolderContents.empty.ordered(by: .default, includeHidden: true).isEmpty)
    }
}

/// Deterministic PRNG (SplitMix64) so failures are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
