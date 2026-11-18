import Foundation
import Testing
@testable import FileSystemKit

@Suite("Recent destinations")
struct RecentDestinationsTests {
    @Test func newestFirstNoDuplicatesBounded() throws {
        var recent = RecentDestinations(limit: 3)
        recent.add("/a")
        recent.add("/b/")
        recent.add("/a/") // same folder: moves to the front
        #expect(recent.paths == ["/a", "/b"])
        recent.add("/c")
        recent.add("/d")
        #expect(recent.paths == ["/d", "/c", "/a"])
        recent.remove("/c/")
        #expect(recent.paths == ["/d", "/a"])
        let decoded = try JSONDecoder().decode(RecentDestinations.self, from: JSONEncoder().encode(recent))
        #expect(decoded == recent)
    }
}
