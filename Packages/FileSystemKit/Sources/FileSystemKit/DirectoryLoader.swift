import Foundation

/// A progressive snapshot of a folder being listed.
public struct ListingUpdate: Sendable {
    public let contents: FolderContents
    /// False while more entries are still being read.
    public let isComplete: Bool
}

/// Turns a stream of raw batches into display-ready snapshots.
///
/// The first batch is published immediately (first rows on screen fast). After that,
/// intermediate snapshots are throttled: each one costs a full name ranking, so on a
/// local disk (100k items list in ~80 ms) only the final snapshot follows. On slow
/// volumes (SMB) the user still sees the folder fill in every `throttle` interval.
public struct DirectoryLoader: Sendable {
    public var lister: any DirectoryLister
    public var throttle: Duration

    public init(lister: any DirectoryLister = makeDefaultLister(), throttle: Duration = .milliseconds(250)) {
        self.lister = lister
        self.throttle = throttle
    }

    public func load(_ directory: URL) -> AsyncThrowingStream<ListingUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [lister, throttle] in
                let clock = ContinuousClock()
                var items: [FileItem] = []
                var lastEmit: ContinuousClock.Instant?
                do {
                    for try await batch in lister.batches(of: directory) {
                        try Task.checkCancellation()
                        items.append(contentsOf: batch)
                        let now = clock.now
                        if lastEmit.map({ now - $0 >= throttle }) ?? true {
                            continuation.yield(ListingUpdate(contents: FolderContents(items: items), isComplete: false))
                            lastEmit = clock.now
                        }
                    }
                    try Task.checkCancellation()
                    continuation.yield(ListingUpdate(contents: FolderContents(items: items), isComplete: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
