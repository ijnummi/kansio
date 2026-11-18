import Foundation

/// How much each folder has been used, for the "most used folders" menu next to the tab strip.
///
/// Each use adds a weight (the app's importance setting for that kind of use: opening a folder, switching to a tab).
/// Scores fade with a half-life (30 days by default), so a folder used heavily last year doesn't stay on top forever
/// (zoxide/frecency style) — but a single visit never outranks a folder used every day. Stored as a small Codable
/// value (the app keeps it in its UserDefaults); bounded to `maxEntries` folders.
public struct FolderUsage: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        /// The score as of `lastUsed` (decayed on read).
        public var score: Double
        public var lastUsed: Date
    }

    public static let defaultHalfLife: TimeInterval = 30 * 24 * 3600
    public static let maxEntries = 300

    private var entries: [String: Entry] = [:]
    public var halfLife: TimeInterval

    public init(halfLife: TimeInterval = FolderUsage.defaultHalfLife) {
        self.halfLife = halfLife
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// The path as stored: no trailing slash (except "/"). Otherwise byte-exact (keys compare with Swift `==`, so
    /// NFC/NFD spellings of one name are one folder).
    public static func key(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `entry`'s score at `date`.
    public func score(_ entry: Entry, at date: Date) -> Double {
        let age = max(0, date.timeIntervalSince(entry.lastUsed))
        return halfLife > 0 ? entry.score * pow(0.5, age / halfLife) : entry.score
    }

    public func score(of path: String, at date: Date) -> Double {
        entries[Self.key(path)].map { score($0, at: date) } ?? 0
    }

    /// One use of `path` worth `weight` (≤ 0: ignored).
    public mutating func record(_ path: String, weight: Double, at date: Date) {
        guard weight > 0, !path.isEmpty else { return }
        let key = Self.key(path)
        let previous = entries[key].map { score($0, at: date) } ?? 0
        entries[key] = Entry(path: key, score: previous + weight, lastUsed: date)
        if entries.count > Self.maxEntries { prune(at: date) }
    }

    /// The `n` highest-scoring folders, best first (ties: the more recently used, then by path).
    public func top(_ n: Int, at date: Date) -> [Entry] {
        guard n > 0 else { return [] }
        return ranked(at: date).prefix(n).map(\.entry)
    }

    public mutating func remove(_ path: String) { entries[Self.key(path)] = nil }

    public mutating func removeAll() { entries.removeAll() }

    private func ranked(at date: Date) -> [(entry: Entry, score: Double)] {
        entries.values.map { ($0, score($0, at: date)) }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.lastUsed != b.entry.lastUsed { return a.entry.lastUsed > b.entry.lastUsed }
            return a.entry.path < b.entry.path
        }
    }

    /// Keeps the best `maxEntries`.
    private mutating func prune(at date: Date) {
        let keep = ranked(at: date).prefix(Self.maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.entry.path, $0.entry) })
    }

    // Stored as a list (smaller and stable to diff).
    private enum CodingKeys: String, CodingKey { case entries, halfLife }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        halfLife = try container.decodeIfPresent(TimeInterval.self, forKey: .halfLife) ?? Self.defaultHalfLife
        let list = try container.decode([Entry].self, forKey: .entries)
        for entry in list where !entry.path.isEmpty && entry.score.isFinite && entry.score > 0 {
            entries[Self.key(entry.path)] = entry
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(halfLife, forKey: .halfLife)
        try container.encode(entries.values.sorted { $0.path < $1.path }, forKey: .entries)
    }
}
