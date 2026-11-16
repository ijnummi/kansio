import Foundation
import Testing
@testable import FileSystemKit

@Suite("Progressive loading")
struct LoaderTests {
    @Test func emitsGrowingSnapshotsEndingWithCompleteOne() async throws {
        let t = try TempDir()
        for i in 0..<3000 { try t.file("item \(i).txt") }
        let loader = DirectoryLoader(lister: BulkDirectoryLister(bufferSize: 4096), throttle: .zero)
        var counts: [Int] = []
        var completeFlags: [Bool] = []
        for try await update in loader.load(t.url) {
            counts.append(update.contents.items.count)
            completeFlags.append(update.isComplete)
        }
        #expect(counts.count > 1, "expected progressive updates")
        #expect(counts == counts.sorted(), "snapshots must only grow")
        #expect(counts.last == 3000)
        #expect(completeFlags.last == true)
        #expect(completeFlags.dropLast().allSatisfy { !$0 })
    }

    @Test func smallFolderIsComplete() async throws {
        let t = try TempDir()
        try t.file("one")
        var last: ListingUpdate?
        for try await update in DirectoryLoader().load(t.url) { last = update }
        #expect(last?.isComplete == true)
        #expect(last?.contents.items.map(\.name) == ["one"])
    }

    @Test func missingFolderThrows() async throws {
        let t = try TempDir()
        await #expect(throws: FileSystemError.self) {
            for try await _ in DirectoryLoader().load(t.url.appending(path: "gone")) {}
        }
    }
}
