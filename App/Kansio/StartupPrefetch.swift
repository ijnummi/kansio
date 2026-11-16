import Foundation
import FileSystemKit
import Synchronization

/// Lists the startup folder in parallel with AppKit's own start-up (~50–100 ms of
/// NSApplication, menu, window and toolbar setup), so the rows are ready before the
/// window is first shown and the very first frame already contains them.
///
/// Started at the top of `main()`; consumed once by the first `FileListViewController`
/// that shows that folder. Anything not ready in time falls back to the normal async path.
enum StartupPrefetch {
    struct Result: Sendable {
        let url: URL
        let update: ListingUpdate
        let ordered: [FileItem]
        let sort: FileSort
        let showHidden: Bool
    }

    private static let state = Mutex<(url: URL?, result: Result?, done: Bool)>((nil, nil, false))
    private static let finished = DispatchSemaphore(value: 0)

    /// Begins listing `url` with the persisted view settings. Call once, as early as possible.
    static func start(_ url: URL, sort: FileSort, showHidden: Bool) {
        state.withLock { $0.url = url }
        Task.detached(priority: .userInitiated) {
            var last: ListingUpdate?
            do {
                for try await update in DirectoryLoader().load(url) where update.isComplete { last = update }
            } catch {}
            let result = last.map {
                Result(url: url, update: $0, ordered: $0.contents.ordered(by: sort, includeHidden: showHidden),
                       sort: sort, showHidden: showHidden)
            }
            state.withLock { $0.result = result; $0.done = true }
            finished.signal()
        }
    }

    /// The prefetched listing for `url`, waiting at most `timeout` for it (it's normally done
    /// long before the window exists). Returns nil if it isn't for this folder, failed
    /// (the normal path then reports the error), or isn't ready in time.
    static func take(for url: URL, waitingAtMost timeout: Duration = .milliseconds(5)) -> Result? {
        guard state.withLock({ $0.url }) == url else { return nil }
        if !state.withLock({ $0.done }) {
            let ms = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
            _ = finished.wait(timeout: .now() + .milliseconds(ms))
        }
        return state.withLock { s in
            defer { s.url = nil; s.result = nil } // single use
            return s.done ? s.result : nil
        }
    }
}
