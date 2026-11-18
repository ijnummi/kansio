import Foundation
import Testing
@testable import FileSystemKit

@Suite("Search filters (P3-7)")
struct SearchQueryTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        c.firstWeekday = 2 // Monday
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
    func file(_ size: Int64, _ modified: Date) -> FileItem { FileItem(name: "f", kind: .file, size: size, modificationDate: modified) }

    @Test func parsesWordsAndFilters() {
        let q = SearchQuery.parse("report  size:>10MB date:thisweek draft")
        #expect(q.text == "report draft")
        #expect(q.size == .larger(SizeAmount(10, .mb), inclusive: false))
        #expect(q.date == .preset(.thisweek))
        #expect(SearchQuery.parse("size:large").size == .bucket(.large))
        #expect(SearchQuery.parse("size:<=4KiB").size == .smaller(SizeAmount(4, .kib), inclusive: true))
        #expect(SearchQuery.parse("size:1.5GB..2g").size == .between(SizeAmount(1.5, .gb), SizeAmount(2, .gb)))
        #expect(SearchQuery.parse("size:4096").size == .about(SizeAmount(4096, .bytes)))
        #expect(SearchQuery.parse("DATE:2024-05").date == .on(CalendarSpan(year: 2024, month: 5)))
        #expect(SearchQuery.parse("date:>=2024-05-17").date == .after(CalendarSpan(year: 2024, month: 5, day: 17), inclusive: true))
        #expect(SearchQuery.parse("date:2024..2025-02").date == .between(CalendarSpan(year: 2024), CalendarSpan(year: 2025, month: 2)))
        #expect(SearchQuery.parse("date:7d").date == .within(Age(7, .days)))
        #expect(SearchQuery.parse("date:<2w").date == .within(Age(2, .weeks)))
        #expect(SearchQuery.parse("modified:>3m").date == .olderThan(Age(3, .months)))
        // Not filters: they stay words.
        #expect(SearchQuery.parse("size:big kind:pdf date:2024-13").text == "size:big kind:pdf date:2024-13")
        #expect(!SearchQuery.parse("size:big").hasFilters)
    }

    @Test func formatsBackTheSameWay() {
        for text in ["size:>10MB", "size:<=4KiB", "size:1.5GB..2GB", "size:large", "size:10MB", "date:thisweek", "date:2024-05",
                     "date:>=2024-05-17", "date:<2024", "date:2024..2025-02", "date:7d", "date:>3m", "notes size:<1MB date:yesterday"] {
            #expect(SearchQuery.parse(text).formatted == text, "\(text) → \(SearchQuery.parse(text).formatted)")
        }
        var q = SearchQuery.parse("invoice date:today")
        q.size = .bucket(.small)
        q.date = .any
        #expect(q.formatted == "invoice size:small")
    }

    @Test func sizesMatchFilesOnly() {
        let now = Date.now
        func matches(_ query: String, _ size: Int64) -> Bool { SearchQuery.parse(query).predicate(now: now).matches(file(size, now)) }
        #expect(matches("size:>10MB", 10_000_001) && !matches("size:>10MB", 10_000_000) && matches("size:>=10MB", 10_000_000))
        #expect(matches("size:<1KB", 999) && !matches("size:<1KB", 1000) && matches("size:<=1KB", 1000))
        #expect(matches("size:10MB", 10_400_000) && matches("size:10MB", 9_500_000) && !matches("size:10MB", 10_500_000)) // shows as 10 MB
        #expect(matches("size:1MB..2MB", 1_500_000) && !matches("size:1MB..2MB", 2_000_001))
        #expect(matches("size:empty", 0) && !matches("size:empty", 1) && matches("size:tiny", 16_000) && matches("size:small", 16_001))
        #expect(matches("size:gigantic", 5_000_000_000) && matches("size:1KiB", 1024))
        let folder = FileItem(name: "d", kind: .directory)
        #expect(!SearchQuery.parse("size:empty").predicate(now: now).matches(folder)) // folders have no size
        #expect(SearchQuery.parse("date:today").predicate(now: now).matches(FileItem(name: "d", kind: .directory, modificationDate: now)))
    }

    @Test func datesFollowTheCalendar() {
        let now = date(2026, 11, 19, 10) // a Thursday
        func matches(_ query: String, _ modified: Date) -> Bool {
            SearchQuery.parse(query).predicate(now: now, calendar: calendar).matches(file(1, modified))
        }
        #expect(matches("date:today", date(2026, 11, 19, 1)) && !matches("date:today", date(2026, 11, 18, 23)))
        #expect(matches("date:yesterday", date(2026, 11, 18)))
        #expect(matches("date:thisweek", date(2026, 11, 16, 0)) && !matches("date:thisweek", date(2026, 11, 15, 23))) // weeks start Monday
        #expect(matches("date:lastweek", date(2026, 11, 10)) && !matches("date:lastweek", date(2026, 11, 17)))
        #expect(matches("date:thismonth", date(2026, 11, 1, 0)) && matches("date:lastmonth", date(2026, 10, 31)))
        #expect(matches("date:lastyear", date(2025, 6, 1)) && !matches("date:thisyear", date(2025, 12, 31)))
        #expect(matches("date:2024-05", date(2024, 5, 31, 23)) && !matches("date:2024-05", date(2024, 6, 1, 0)))
        #expect(matches("date:>2024-05-17", date(2024, 5, 18, 0)) && !matches("date:>2024-05-17", date(2024, 5, 17, 23)))
        #expect(matches("date:>=2024-05-17", date(2024, 5, 17, 0)) && matches("date:<=2024", date(2024, 12, 31, 23)) && !matches("date:<2024", date(2024, 1, 1, 0)))
        #expect(matches("date:2024-01..2024-02", date(2024, 2, 29)) && !matches("date:2024-01..2024-02", date(2024, 3, 1, 0)))
        #expect(matches("date:7d", date(2026, 11, 13)) && !matches("date:7d", date(2026, 11, 11)))
        #expect(matches("date:>7d", date(2026, 11, 11)) && !matches("date:>7d", date(2026, 11, 13)))
    }

    @Test func subfolderWalkAppliesTheFilter() throws {
        let t = try TempDir()
        try t.dir("a/b")
        try t.file("a/small.txt", bytes: 10)
        try t.file("a/b/big.bin", bytes: 3_000_000)
        try t.file("a/b/big-notes.txt", bytes: 2_000_000)
        func walk(_ query: String) -> [String] {
            let q = SearchQuery.parse(query)
            var names: [String] = []
            FolderSearch.searchSubfolders(of: t.url, query: q.text, includeHidden: false, cancel: CancellationFlag(), filter: q.predicate()) { names += $0.map(\.name) }
            return names.sorted()
        }
        #expect(walk("size:>1MB") == ["a/b/big-notes.txt", "a/b/big.bin"]) // no words: every name, filtered
        #expect(walk("notes size:>1MB") == ["a/b/big-notes.txt"])
        #expect(walk("size:tiny") == ["a/small.txt"])
        #expect(walk("date:yesterday").isEmpty)
        #expect(walk("txt") == ["a/b/big-notes.txt", "a/small.txt"]) // words only: as before
    }
}
