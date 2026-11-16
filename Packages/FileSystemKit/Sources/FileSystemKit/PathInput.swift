import Darwin
import Foundation

/// Interprets what the user types or pastes into the address bar.
public enum PathInput {
    /// Turns address-bar text into a file URL. Accepts absolute paths, `~` / `~/…` / `~user/…`,
    /// `file://` URLs, paths relative to `base`, and paths wrapped in quotes (as copied from
    /// Terminal). `.` and `..` are resolved lexically; symlinks are *not* resolved (the
    /// logical path is kept, as Explorer does). Returns nil for empty input.
    public static func resolve(_ text: String, relativeTo base: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, let first = t.first, first == t.last, first == "\"" || first == "'" {
            t = String(t.dropFirst().dropLast())
        }
        guard !t.isEmpty else { return nil }

        if t.lowercased().hasPrefix("file://"), let url = URL(string: t), url.isFileURL {
            return standardized(url.path(percentEncoded: false))
        }
        if t == "~" || t.hasPrefix("~/") {
            return standardized(home.path(percentEncoded: false) + "/" + t.dropFirst())
        }
        if t.hasPrefix("~") {
            let rest = t.dropFirst()
            let user = rest.prefix { $0 != "/" }
            if let userHome = FileManager.default.homeDirectory(forUser: String(user)) {
                return standardized(userHome.path(percentEncoded: false) + "/" + rest.dropFirst(user.count))
            }
        }
        if t.hasPrefix("/") { return standardized(t) }
        return standardized(base.path(percentEncoded: false) + "/" + t)
    }

    /// Lexically normalizes a path: collapses `//`, resolves `.` and `..` (never above `/`).
    static func standardized(_ path: String) -> URL {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        let joined = "/" + parts.joined(separator: "/")
        return URL(filePath: joined, directoryHint: .inferFromPath)
    }

    /// What a path points at (follows symlinks, like opening it would).
    public enum Target: Sendable, Equatable {
        case folder
        /// A file or package: the address bar opens its folder and selects it.
        case item
        case missing
        case noPermission
        case failed(Int32)
    }

    /// Classifies `url`. Blocking (one `stat`, which can hang on a dead network mount):
    /// use `target(of:)` from async code.
    public static func targetBlocking(of url: URL) -> Target {
        var st = stat()
        let path = url.path(percentEncoded: false)
        guard stat(path, &st) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EACCES, EPERM: return .noPermission
            default: return .failed(errno)
            }
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { return .item }
        return PackageExtensions.isPackage(name: (path as NSString).lastPathComponent) ? .item : .folder
    }

    public static func target(of url: URL) async -> Target {
        await runOnListingQueue { targetBlocking(of: url) }
    }

    /// Like `target(of:)`, but gives up after `timeout` (nil) — e.g. a path inside a dead network mount.
    public static func target(of url: URL, timeout: Duration) async -> Target? {
        await runWithDeadline(timeout) { targetBlocking(of: url) }.fast
    }
}

/// One clickable segment of the address bar.
public struct Breadcrumb: Sendable, Equatable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public enum Breadcrumbs {
    /// Segments for `url`: the volume it's on (by name), then each folder below the mount point.
    /// `/Users/a/Docs` on the startup disk → "Macintosh HD", "Users", "a", "Docs".
    public static func segments(for url: URL, volumes: [Volume]) -> [Breadcrumb] {
        let path = PathInput.standardized(url.path(percentEncoded: false)).path(percentEncoded: false)
        // The deepest mount point containing the path wins (/Volumes/X over /).
        let volume = volumes
            .filter { $0.contains(path: path) }
            .max { $0.url.path(percentEncoded: false).count < $1.url.path(percentEncoded: false).count }
        let mount = volume.map { PathInput.standardized($0.url.path(percentEncoded: false)).path(percentEncoded: false) } ?? "/"
        var crumbs = [Breadcrumb(title: volume?.name ?? "/", url: URL(filePath: mount, directoryHint: .isDirectory))]
        let rest = path.dropFirst(mount == "/" ? 1 : mount.count)
        var current = mount == "/" ? "" : mount
        for component in rest.split(separator: "/") {
            current += "/" + component
            crumbs.append(Breadcrumb(title: String(component), url: URL(filePath: current, directoryHint: .isDirectory)))
        }
        return crumbs
    }
}
