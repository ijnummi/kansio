import Foundation

/// Per-window Back/Forward history, Explorer-style.
///
/// - Visiting a new location pushes the current one onto Back and clears Forward.
/// - Visiting the current location again is a no-op (no duplicate entries).
/// - Each entry remembers what was selected when you left it, so going Back/Forward
///   re-selects it (e.g. the folder you had opened).
/// - Bounded: the oldest entries are dropped beyond `limit`.
public struct NavigationHistory: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var url: URL
        /// Names selected when this location was left (restored on return).
        public var selection: [String]

        public init(url: URL, selection: [String] = []) {
            self.url = url
            self.selection = selection
        }
    }

    public private(set) var back: [Entry] = []      // most recent last
    public private(set) var current: Entry
    public private(set) var forward: [Entry] = []   // next first
    public let limit: Int

    public init(start: URL, limit: Int = 100) {
        current = Entry(url: start)
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Records what is selected at the current location (call before leaving it).
    public mutating func setCurrentSelection(_ names: [String]) {
        current.selection = names
    }

    /// Navigates to a new location. Returns false if it's already the current one.
    @discardableResult
    public mutating func visit(_ url: URL, selection: [String] = []) -> Bool {
        guard !Self.same(url, current.url) else {
            if !selection.isEmpty { current.selection = selection }
            return false
        }
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
        current = Entry(url: url, selection: selection)
        forward.removeAll()
        return true
    }

    /// Steps back `steps` entries (1 = the previous location). Returns the new current entry.
    public mutating func goBack(_ steps: Int = 1) -> Entry? {
        guard steps >= 1, steps <= back.count else { return nil }
        for _ in 0..<steps {
            forward.insert(current, at: 0)
            current = back.removeLast()
        }
        return current
    }

    /// Steps forward `steps` entries. Returns the new current entry.
    public mutating func goForward(_ steps: Int = 1) -> Entry? {
        guard steps >= 1, steps <= forward.count else { return nil }
        for _ in 0..<steps {
            back.append(current)
            current = forward.removeFirst()
        }
        return current
    }

    /// Drops every entry inside `isGone` (e.g. an ejected volume); the current entry is kept.
    public mutating func removeAll(where isGone: (URL) -> Bool) {
        back.removeAll { isGone($0.url) }
        forward.removeAll { isGone($0.url) }
    }

    /// Paths compare without a trailing slash ("/a/b/" == "/a/b").
    static func same(_ a: URL, _ b: URL) -> Bool {
        func norm(_ u: URL) -> String {
            let p = u.standardizedFileURL.path(percentEncoded: false)
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        return norm(a) == norm(b)
    }
}

/// The parent folder of `url` and the name to select in it (Explorer: Up selects where you came from).
/// Nil at the file system root.
public func parentLocation(of url: URL) -> (parent: URL, childName: String)? {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    guard trimmed != "/" else { return nil }
    let child = (trimmed as NSString).lastPathComponent
    let parent = (trimmed as NSString).deletingLastPathComponent
    return (URL(filePath: parent.isEmpty ? "/" : parent, directoryHint: .isDirectory), child)
}
