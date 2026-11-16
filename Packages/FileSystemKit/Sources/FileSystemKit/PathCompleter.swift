import Foundation

/// One suggestion in the address bar's completion list.
public struct PathCompletion: Sendable, Equatable {
    /// The folder name as shown in the list.
    public let name: String
    /// The full text to put into the address bar (keeps what the user typed, e.g. "~/Doc" → "~/Documents/").
    public let text: String
}

/// Folder-name completion for the address bar.
///
/// Splits the text at its last "/": the part before names the folder to list (resolved like
/// `PathInput.resolve`), the part after is a prefix matched case- and diacritic-insensitively
/// (so NFC/NFD forms match too). Listings are cached per folder for `ttl`, so typing doesn't
/// re-list on every keystroke; listing runs on the listing queue, never on the main thread.
public actor PathCompleter {
    private let lister: any DirectoryLister
    private let ttl: Duration
    private var cache: [String: (time: ContinuousClock.Instant, folders: [String])] = [:]

    public init(lister: any DirectoryLister = makeDefaultLister(), ttl: Duration = .seconds(5)) {
        self.lister = lister
        self.ttl = ttl
    }

    public func completions(for text: String, relativeTo base: URL, includeHidden: Bool, limit: Int = 50,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [PathCompletion] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let dirPart: String
        let prefix: String
        if let slash = trimmed.lastIndex(of: "/") {
            dirPart = String(trimmed[...slash])
            prefix = String(trimmed[trimmed.index(after: slash)...])
        } else if trimmed == "~" {
            return [PathCompletion(name: "~", text: "~/")]
        } else {
            dirPart = ""
            prefix = trimmed
        }
        let directory = dirPart.isEmpty ? base : (PathInput.resolve(dirPart, relativeTo: base, home: home) ?? base)
        let folders = await folderNames(in: directory)
        let showHidden = includeHidden || prefix.hasPrefix(".")
        let matches = folders.filter { name in
            (showHidden || !name.hasPrefix(".")) &&
                (prefix.isEmpty || name.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil)
        }
        return matches.prefix(limit).map { PathCompletion(name: $0, text: dirPart + $0 + "/") }
    }

    /// Folder names (and symlinks, which may point to folders) in Finder order. Cached.
    private func folderNames(in directory: URL) async -> [String] {
        let key = directory.path(percentEncoded: false)
        if let hit = cache[key], ContinuousClock.now - hit.time < ttl { return hit.folders }
        let lister = self.lister
        let items: [FileItem] = await runOnListingQueue { (try? lister.listAll(directory)) ?? [] }
        let names = items.filter { $0.isFolder || $0.kind == .symlink }.map(\.name)
        let sorted = NameCollation.sortedIndices(of: names).map { names[Int($0)] }
        cache[key] = (.now, sorted)
        if cache.count > 64 { cache.removeAll() }
        return sorted
    }
}
