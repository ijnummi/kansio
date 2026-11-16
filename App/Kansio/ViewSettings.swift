import Foundation
import FileSystemKit

extension Notification.Name {
    /// A global view setting changed; `userInfo["key"]` is the `ViewSettings.Key` raw value.
    static let viewSettingsDidChange = Notification.Name("dev.kansio.viewSettingsDidChange")
}

/// The one global view setting (Explorer-style): sort, columns (order, widths, which are shown),
/// hidden files, status bar. Every folder uses it; changing it anywhere changes it everywhere.
/// Stored in the app's UserDefaults, never in the folders themselves (no `.DS_Store`).
///
/// `KANSIO_DEFAULTS_SUITE` stores it in another defaults domain instead (the self-test uses its
/// own domain so it never changes the user's settings).
@MainActor
final class ViewSettings {
    static let shared = ViewSettings()

    enum Key: String {
        case sort = "view.sort"
        case showHidden = "view.showHidden"
        case showStatusBar = "view.showStatusBar"
        case columns = "view.columns"
        case treeExpandToCurrent = "tree.expandToCurrent"
        case treeExpandOnNetwork = "tree.expandOnNetwork"
        case treeCheckNetwork = "tree.checkNetworkSubfolders"
        case treeKeyDelay = "tree.keyDelayMilliseconds"
    }

    /// One list column: shown or not, its width. `ViewSettings.columns` is in display order.
    struct Column: Codable, Equatable {
        var field: FileSort.Field
        var width: Double
        var hidden: Bool
    }

    /// Default layout: Name, Date Modified, Type, Size shown; Date Created available.
    static let defaultColumns: [Column] = [
        Column(field: .name, width: 300, hidden: false),
        Column(field: .dateModified, width: 150, hidden: false),
        Column(field: .kind, width: 150, hidden: false),
        Column(field: .size, width: 90, hidden: false),
        Column(field: .dateCreated, width: 150, hidden: true),
    ]

    let defaults: UserDefaults

    var sort: FileSort {
        didSet { guard sort != oldValue else { return }; save(try? JSONEncoder().encode(sort), .sort) }
    }

    var showHidden: Bool {
        didSet { guard showHidden != oldValue else { return }; save(showHidden, .showHidden) }
    }

    var showStatusBar: Bool {
        didSet { guard showStatusBar != oldValue else { return }; save(showStatusBar, .showStatusBar) }
    }

    /// Navigation pane (P1-1): expand the tree to the current folder.
    var treeExpandToCurrent: Bool {
        didSet { guard treeExpandToCurrent != oldValue else { return }; save(treeExpandToCurrent, .treeExpandToCurrent) }
    }
    /// …also on network volumes (lists every level of the path over the network; 2 s per level).
    var treeExpandOnNetwork: Bool {
        didSet { guard treeExpandOnNetwork != oldValue else { return }; save(treeExpandOnNetwork, .treeExpandOnNetwork) }
    }
    /// Check rows on network volumes for subfolders (otherwise they always show a triangle).
    var treeCheckNetwork: Bool {
        didSet { guard treeCheckNetwork != oldValue else { return }; save(treeCheckNetwork, .treeCheckNetwork) }
    }
    /// Arrow keys in the tree navigate after this pause (0 = at once).
    var treeKeyDelay: Int {
        didSet {
            let clamped = min(max(treeKeyDelay, 0), 2000)
            if clamped != treeKeyDelay { treeKeyDelay = clamped; return }
            guard treeKeyDelay != oldValue else { return }
            save(treeKeyDelay, .treeKeyDelay)
        }
    }

    var columns: [Column] {
        didSet {
            let clean = Self.sanitized(columns)
            if clean != columns { columns = clean; return } // re-enters didSet with the clean value
            guard columns != oldValue else { return }
            save(try? JSONEncoder().encode(columns), .columns)
        }
    }

    private init() {
        let suite = ProcessInfo.processInfo.environment["KANSIO_DEFAULTS_SUITE"]
        let defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        sort = defaults.data(forKey: Key.sort.rawValue).flatMap { try? JSONDecoder().decode(FileSort.self, from: $0) } ?? .default
        showHidden = defaults.bool(forKey: Key.showHidden.rawValue)
        showStatusBar = defaults.object(forKey: Key.showStatusBar.rawValue) as? Bool ?? true
        treeExpandToCurrent = defaults.object(forKey: Key.treeExpandToCurrent.rawValue) as? Bool ?? true
        treeExpandOnNetwork = defaults.bool(forKey: Key.treeExpandOnNetwork.rawValue)
        treeCheckNetwork = defaults.bool(forKey: Key.treeCheckNetwork.rawValue)
        treeKeyDelay = min(max(defaults.object(forKey: Key.treeKeyDelay.rawValue) as? Int ?? 250, 0), 2000)
        columns = Self.sanitized(defaults.data(forKey: Key.columns.rawValue)
            .flatMap { try? JSONDecoder().decode([Column].self, from: $0) } ?? Self.defaultColumns)
        // NSTableView's own column autosave (used before M16) isn't read any more.
        for name in ["FileList", "FileList.v2"] {
            for prefix in ["NSTableView Columns v3 ", "NSTableView Sort Ordering v2 ", "NSTableView Supports v2 "] {
                defaults.removeObject(forKey: prefix + name)
            }
        }
    }

    /// Back to the default columns (order, widths, visibility).
    func resetColumns() { columns = Self.defaultColumns }

    /// Every field exactly once (unknown/duplicate entries dropped, missing ones appended with their
    /// defaults), Name always shown, widths within limits.
    static func sanitized(_ columns: [Column]) -> [Column] {
        var seen = Set<FileSort.Field>()
        var result = columns.filter { seen.insert($0.field).inserted }
        result += defaultColumns.filter { !seen.contains($0.field) }
        for i in result.indices {
            if result[i].field == .name { result[i].hidden = false }
            let limit = minimumWidth(result[i].field)
            if !result[i].width.isFinite || result[i].width < limit { result[i].width = limit }
            result[i].width = min(result[i].width, 4000)
        }
        return result
    }

    static func minimumWidth(_ field: FileSort.Field) -> Double {
        switch field {
        case .name: 120
        case .dateModified, .dateCreated: 80
        case .kind: 60
        case .size: 50
        }
    }

    private func save(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: self, userInfo: ["key": key.rawValue])
    }
}
