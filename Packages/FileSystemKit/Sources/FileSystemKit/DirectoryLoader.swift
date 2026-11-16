import Foundation

/// A progressive snapshot of a folder being listed.
public struct ListingUpdate: Sendable {
    public let contents: FolderContents
    /// False while more entries are still being read.
    public let isComplete: Bool
}

/// Turns a stream of raw batches into display-ready snapshots.
///
/// - Batches are coalesced for `coalescing` (default 10 ms), so any folder that lists
///   faster than that (≈ 10k items on an SSD) produces exactly one, complete update.
/// - Bigger or slower folders publish their first snapshot right after that, then further
///   snapshots at most every `throttle` (each one costs a name ranking), then the final one.
/// - Symlink targets are classified after listing (links to folders sort/open as folders).
///   If that takes longer than `symlinkDeadline` (dead network mount…), the listing is
///   published first and a second complete update follows when resolution finishes.
public struct DirectoryLoader: Sendable {
    public var lister: any DirectoryLister
    public var coalescing: Duration
    public var throttle: Duration
    public var symlinkDeadline: Duration
    /// A first batch slower than this is shown immediately (slow volumes).
    public var slowFirstBatch: Duration = .milliseconds(50)

    public init(
        lister: any DirectoryLister = makeDefaultLister(),
        coalescing: Duration = .milliseconds(10),
        throttle: Duration = .milliseconds(250),
        symlinkDeadline: Duration = .milliseconds(20)
    ) {
        self.lister = lister
        self.coalescing = coalescing
        self.throttle = throttle
        self.symlinkDeadline = symlinkDeadline
    }

    public func load(_ directory: URL) -> AsyncThrowingStream<ListingUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                let clock = ContinuousClock()
                let start = clock.now
                var items: [FileItem] = []
                var batches = 0
                var lastEmit: ContinuousClock.Instant?
                do {
                    for try await batch in lister.batches(of: directory, coalescing: coalescing) {
                        try Task.checkCancellation()
                        items.append(contentsOf: batch)
                        batches += 1
                        // A lone batch may be the whole folder: publish a partial snapshot only once
                        // a second batch proves there's more, or if the user has already waited long.
                        let worthPartial = batches >= 2 || clock.now - start >= slowFirstBatch
                        if worthPartial, lastEmit.map({ clock.now - $0 >= throttle }) ?? true {
                            continuation.yield(ListingUpdate(contents: FolderContents(items: items), isComplete: false))
                            lastEmit = clock.now
                        }
                    }
                    try Task.checkCancellation()

                    guard items.contains(where: { $0.kind == .symlink }) else {
                        continuation.yield(ListingUpdate(contents: FolderContents(items: items), isComplete: true))
                        continuation.finish()
                        return
                    }
                    let unresolved = items
                    let (fast, late) = await runWithDeadline(symlinkDeadline) {
                        SymlinkResolver.resolved(unresolved, in: directory)
                    }
                    try Task.checkCancellation()
                    if let fast {
                        continuation.yield(ListingUpdate(contents: FolderContents(items: fast), isComplete: true))
                    } else {
                        let contents = FolderContents(items: items)
                        continuation.yield(ListingUpdate(contents: contents, isComplete: true))
                        let resolved = await late.value
                        try Task.checkCancellation()
                        // Names are unchanged, so the (expensive) name ranks can be reused.
                        continuation.yield(ListingUpdate(contents: contents.replacingItems(resolved), isComplete: true))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
