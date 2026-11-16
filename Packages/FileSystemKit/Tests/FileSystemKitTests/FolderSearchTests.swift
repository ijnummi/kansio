import Foundation
import Testing
@testable import FileSystemKit

@Suite("Folder search (P1-5)")
struct FolderSearchTests {
    @Test func matchingIgnoresCaseDiacriticsAndNeedsEveryWord() {
        let index = FolderSearch.Index(names: ["Café Menu.pdf", "cafe.txt", "Report 2026.docx", "résumé.pages", "notes"])
        #expect(index.matching(FolderSearch.words("cafe")) == [0, 1])
        #expect(index.matching(FolderSearch.words("MENU café")) == [0])
        #expect(index.matching(FolderSearch.words("resume")) == [3])
        #expect(index.matching(FolderSearch.words("report docx")) == [2])
        #expect(index.matching(FolderSearch.words("report pdf")).isEmpty)
        #expect(index.matching(FolderSearch.words("   ")).isEmpty)
    }

    @Test func filteringHundredThousandNamesIsFast() {
        let names = (0..<100_000).map { "file \($0) report.txt" }
        let index = FolderSearch.Index(names: names)
        let start = ContinuousClock.now
        let hits = index.matching(FolderSearch.words("99 rep"))
        let elapsed = ContinuousClock.now - start
        #expect(hits.count == names.filter { $0.contains("99") }.count)
        #expect(elapsed < .milliseconds(50)) // the per-keystroke budget (debug build)
    }

    @Test func walksSubfoldersButNotPackagesLinksOrHiddenFolders() throws {
        let temp = try TempDir()
        try temp.dir("a/b/c")
        try temp.file("top-report.txt") // the root's own entries are the caller's to filter
        try temp.file("a/report-1.txt")
        try temp.file("a/b/c/Report-3.TXT")
        try temp.dir("Tool.app/Contents")
        try temp.file("Tool.app/Contents/report-in-package.txt")
        try temp.dir(".hidden")
        try temp.file(".hidden/report-hidden.txt")
        try temp.symlink("link-to-a", to: "a")
        var found: [String] = []
        let result = FolderSearch.searchSubfolders(of: temp.url, query: "report", includeHidden: false, cancel: CancellationFlag()) {
            found += $0.map(\.name)
        }
        #expect(Set(found) == ["a/report-1.txt", "a/b/c/Report-3.TXT"])
        #expect(result.folders == 3)
        var withHidden: [String] = []
        FolderSearch.searchSubfolders(of: temp.url, query: "report", includeHidden: true, cancel: CancellationFlag()) { withHidden += $0.map(\.name) }
        #expect(withHidden.contains(".hidden/report-hidden.txt"))
    }

    @Test func folderNamesMatchToo() throws {
        let temp = try TempDir()
        try temp.dir("x/Reports 2026/inner")
        var found: [String] = []
        FolderSearch.searchSubfolders(of: temp.url, query: "reports", includeHidden: false, cancel: CancellationFlag()) { found += $0.map(\.name) }
        #expect(found == ["x/Reports 2026"])
    }

    @Test func cancellationStopsTheWalk() throws {
        let temp = try TempDir()
        for i in 0..<200 { try temp.dir("d\(i)/e") }
        let cancel = CancellationFlag()
        var batches = 0
        let result = FolderSearch.searchSubfolders(of: temp.url, query: "e", includeHidden: false, cancel: cancel, batchInterval: .zero) { _ in
            batches += 1
            cancel.cancel()
        }
        #expect(batches == 1 && result.folders < 400)
    }
}
