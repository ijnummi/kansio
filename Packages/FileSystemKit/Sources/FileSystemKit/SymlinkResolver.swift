import Darwin
import Foundation
import Synchronization

/// Classifies symlink targets (folder / package / file / broken) so links to folders
/// group and open like folders. Never follows links recursively: one `stat` per link
/// (the kernel resolves the chain and reports `ELOOP` for cycles).
///
/// Blocking — a link into a dead network mount can stall `stat`, so this runs on the
/// listing queue after the listing itself has been published (see `DirectoryLoader`).
public enum SymlinkResolver {
    /// Returns `items` with link flags set for every symlink. Non-links are untouched.
    public static func resolved(_ items: [FileItem], in directory: URL) -> [FileItem] {
        let base = directory.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var result = items
        for i in result.indices where result[i].kind == .symlink {
            result[i].flags.subtract(.linkTarget)
            result[i].flags.insert(classify(prefix + result[i].name))
        }
        return result
    }

    /// Link flags for the symlink at `path` (blocking: call off-main).
    public static func classify(_ path: String) -> FileItem.Flags {
        var st = stat()
        guard stat(path, &st) == 0 else { return .brokenLink }
        guard st.st_mode & S_IFMT == S_IFDIR else { return .linkToFile }
        // Package detection by the *target's* name (e.g. a link named "Editor" → "/Applications/TextEdit.app").
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let targetName = realpath(path, &buffer) != nil
            ? (String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) as NSString).lastPathComponent
            : (path as NSString).lastPathComponent
        return PackageExtensions.isPackage(name: targetName) ? .linkToPackage : .linkToFolder
    }
}

/// Runs blocking work on the listing queue and returns its result if it finishes within
/// `timeout`; otherwise returns nil immediately and keeps the work running (`late`).
func runWithDeadline<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () -> T) async -> (fast: T?, late: Task<T, Never>) {
    let late = Task { await runOnListingQueue(work) }
    let fast: T? = await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task { once.resume(await late.value) }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(nil)
        }
    }
    return (fast, late)
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = Mutex(continuation) }
    func resume(_ value: T?) {
        let c = continuation.withLock { c in defer { c = nil }; return c }
        c?.resume(returning: value)
    }
}

/// Finder alias files (not symlinks): bookmark data that points at another item.
public enum Aliases {
    /// The alias's target, or nil if it can't be resolved. Never shows UI and never mounts a
    /// volume (an alias to an unmounted server fails instead of stalling). Blocking.
    public static func resolveBlocking(_ url: URL) -> URL? {
        try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
    }

    public static func resolve(_ url: URL) async -> URL? {
        await runOnListingQueue { resolveBlocking(url) }
    }
}
