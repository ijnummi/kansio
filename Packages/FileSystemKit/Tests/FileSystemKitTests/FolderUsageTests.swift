import Foundation
import Testing
@testable import FileSystemKit

@Suite("Most used folders (FolderUsage)")
struct FolderUsageTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 24 * 3600

    @Test func ranksByWeightedUse() {
        var usage = FolderUsage()
        usage.record("/a", weight: 1, at: t0)
        usage.record("/b", weight: 4, at: t0)
        usage.record("/a", weight: 1, at: t0)
        usage.record("/c", weight: 3, at: t0)
        #expect(usage.top(10, at: t0).map(\.path) == ["/b", "/c", "/a"])
        #expect(usage.score(of: "/a", at: t0) == 2)
        #expect(usage.top(1, at: t0).map(\.path) == ["/b"])
        #expect(usage.top(0, at: t0).isEmpty)
    }

    @Test func tiesGoToTheMoreRecent() {
        var usage = FolderUsage(halfLife: 0) // no fading: equal scores
        usage.record("/old", weight: 2, at: t0)
        usage.record("/new", weight: 2, at: t0 + 60)
        #expect(usage.top(2, at: t0 + 120).map(\.path) == ["/new", "/old"])
    }

    @Test func scoresFadeWithTheHalfLife() {
        var usage = FolderUsage(halfLife: 30 * day)
        usage.record("/a", weight: 8, at: t0)
        #expect(abs(usage.score(of: "/a", at: t0 + 30 * day) - 4) < 1e-9)
        #expect(abs(usage.score(of: "/a", at: t0 + 60 * day) - 2) < 1e-9)
        // Heavy use long ago vs light use now: the recent folder overtakes eventually, not after one visit.
        usage.record("/b", weight: 4, at: t0 + 10 * day)
        #expect(usage.top(2, at: t0 + 10 * day).map(\.path) == ["/a", "/b"])
        usage.record("/b", weight: 4, at: t0 + 40 * day)
        #expect(usage.top(2, at: t0 + 40 * day).map(\.path) == ["/b", "/a"])
        // A use adds to the faded score.
        usage.record("/a", weight: 1, at: t0 + 30 * day)
        #expect(abs(usage.score(of: "/a", at: t0 + 30 * day) - 5) < 1e-9)
    }

    @Test func trailingSlashIsTheSameFolderAndUnicodeIsCanonical() {
        var usage = FolderUsage()
        usage.record("/Users/x/Docs/", weight: 1, at: t0)
        usage.record("/Users/x/Docs", weight: 1, at: t0)
        usage.record("/", weight: 1, at: t0)
        usage.record("/Caf\u{E9}", weight: 1, at: t0)       // NFC
        usage.record("/Cafe\u{301}", weight: 1, at: t0)     // NFD
        #expect(usage.count == 3)
        #expect(usage.score(of: "/Users/x/Docs", at: t0) == 2)
        #expect(usage.top(5, at: t0).contains { $0.path == "/" })
        #expect(usage.score(of: "/Caf\u{E9}", at: t0) == 2)
    }

    @Test func ignoresZeroWeightAndEmptyPaths() {
        var usage = FolderUsage()
        usage.record("/a", weight: 0, at: t0)
        usage.record("/a", weight: -1, at: t0)
        usage.record("", weight: 1, at: t0)
        #expect(usage.isEmpty)
    }

    @Test func boundedToMaxEntriesKeepingTheBest() {
        var usage = FolderUsage(halfLife: 0)
        usage.record("/favourite", weight: 1000, at: t0)
        for i in 0..<(FolderUsage.maxEntries + 50) { usage.record("/f\(i)", weight: 1, at: t0 + Double(i)) }
        #expect(usage.count == FolderUsage.maxEntries)
        #expect(usage.top(1, at: t0).first?.path == "/favourite")
    }

    @Test func removeAndReset() {
        var usage = FolderUsage()
        usage.record("/a", weight: 1, at: t0)
        usage.record("/b", weight: 1, at: t0)
        usage.remove("/a/")
        #expect(usage.top(5, at: t0).map(\.path) == ["/b"])
        usage.removeAll()
        #expect(usage.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var usage = FolderUsage(halfLife: 7 * day)
        usage.record("/a", weight: 3, at: t0)
        usage.record("/b/ü", weight: 1, at: t0 + 5)
        let data = try JSONEncoder().encode(usage)
        let back = try JSONDecoder().decode(FolderUsage.self, from: data)
        #expect(back == usage)
        #expect(back.halfLife == 7 * day)
        // Damaged entries are dropped, not trusted.
        let bad = #"{"entries":[{"path":"","score":1,"lastUsed":0},{"path":"/x","score":-2,"lastUsed":0},{"path":"/y","score":1,"lastUsed":0}]}"#
        let cleaned = try JSONDecoder().decode(FolderUsage.self, from: Data(bad.utf8))
        #expect(cleaned.top(5, at: t0).map(\.path) == ["/y"])
    }
}
