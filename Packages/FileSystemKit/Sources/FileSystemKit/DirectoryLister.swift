import Foundation
import Synchronization

/// Lists the immediate children of a directory.
///
/// Implementations are *blocking* and must never be called on the main thread.
/// Use `batches(of:)` from async code: it runs the blocking work on a dedicated
/// GCD queue instead of the Swift concurrency cooperative pool, so a hung network
/// volume can't starve the pool that the rest of the app depends on.
public protocol DirectoryLister: Sendable {
    /// Lists `directory`, delivering entries in batches as they are read.
    /// Return `false` from `onBatch` to stop early (cancellation).
    /// Entries are unordered; "." and ".." are never included.
    func list(_ directory: URL, onBatch: ([FileItem]) -> Bool) throws(FileSystemError)
}

extension DirectoryLister {
    /// Convenience: reads the whole directory. Blocking.
    public func listAll(_ directory: URL) throws(FileSystemError) -> [FileItem] {
        var all: [FileItem] = []
        try list(directory) { batch in
            all.append(contentsOf: batch)
            return true
        }
        return all
    }

    /// Streams batches of entries. Cancelling the consuming task (or dropping the
    /// stream) stops the underlying listing at the next batch boundary.
    public func batches(of directory: URL) -> AsyncThrowingStream<[FileItem], any Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancellationFlag()
            continuation.onTermination = { _ in cancelled.cancel() }
            ListingQueue.queue.async {
                do {
                    try self.list(directory) { batch in
                        if cancelled.isCancelled { return false }
                        continuation.yield(batch)
                        return !cancelled.isCancelled
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// The default lister for local and network volumes.
public func makeDefaultLister() -> any DirectoryLister {
    BulkDirectoryLister()
}

enum ListingQueue {
    /// Concurrent, so one slow volume doesn't block listing another folder.
    static let queue = DispatchQueue(label: "kansio.listing", qos: .userInitiated, attributes: .concurrent)
}

/// Thread-safe one-way flag used to propagate cancellation into blocking loops.
public final class CancellationFlag: Sendable {
    private let state = Atomic<Bool>(false)
    public init() {}
    public func cancel() { state.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { state.load(ordering: .relaxed) }
}
