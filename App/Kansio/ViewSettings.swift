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
        case folderSizes = "list.folderSizes"
        case folderSizesOnNetwork = "list.folderSizesOnNetwork"
        case networkTrashFolders = "trash.networkVolumeFolders"
        case archiveEngine = "archive.engine"
        case openArchivesAsFolders = "archive.openAsFolders"
        case terminalApp = "apps.terminal"
        case editorApp = "apps.editor"
        case archiveFormat = "archive.format"
        case archiveLevel = "archive.level"
        case listTextSize = "list.textSize"
        case listDensity = "list.density"
        case usageTopCount = "usage.topCount"
        case usageOpenWeight = "usage.openWeight"
        case usageTabWeight = "usage.tabWeight"
        case usageDwell = "usage.dwellSeconds"
    }

    /// One list column: shown or not, its width. `ViewSettings.columns` is in display order.
    struct Column: Codable, Equatable {
        var field: FileSort.Field
        var width: Double
        var hidden: Bool
    }

    /// Default layout: Name, Date Modified, Type, Size shown; Date Created and Extension available.
    static let defaultColumns: [Column] = [
        Column(field: .name, width: 300, hidden: false),
        Column(field: .dateModified, width: 150, hidden: false),
        Column(field: .kind, width: 150, hidden: false),
        Column(field: .size, width: 90, hidden: false),
        Column(field: .dateCreated, width: 150, hidden: true),
        Column(field: .fileExtension, width: 80, hidden: true),
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

    /// P1-6: compute folder sizes in the background (local volumes; network only with the second switch).
    var folderSizes: Bool {
        didSet { guard folderSizes != oldValue else { return }; save(folderSizes, .folderSizes) }
    }
    var folderSizesOnNetwork: Bool {
        didSet { guard folderSizesOnNetwork != oldValue else { return }; save(folderSizesOnNetwork, .folderSizesOnNetwork) }
    }

    /// P2-1: network volumes have no Trash. Off (default): Move to Trash asks, then deletes immediately (like Finder).
    /// On: items go to a `.Trashes/<uid>` folder Kansio keeps at the top of the network volume.
    var networkTrashFolders: Bool {
        didSet { guard networkTrashFolders != oldValue else { return }; save(networkTrashFolders, .networkTrashFolders) }
    }

    /// P3-5: opening (double-click, Enter) an archive browses it as a read-only folder instead of opening it in an app.
    var openArchivesAsFolders: Bool {
        didSet { guard openArchivesAsFolders != oldValue else { return }; save(openArchivesAsFolders, .openArchivesAsFolders) }
    }

    /// P3-6: the app Open in Terminal uses (Terminal unless another was chosen) and the editor (none until chosen:
    /// the first Open in Editor asks).
    var terminalApp: AppChoice {
        didSet { guard terminalApp != oldValue else { return }; save(try? JSONEncoder().encode(terminalApp), .terminalApp) }
    }
    var editorApp: AppChoice? {
        didSet { guard editorApp != oldValue else { return }; save(editorApp.flatMap { try? JSONEncoder().encode($0) }, .editorApp) }
    }

    /// P2-3: which engine compresses and extracts (the other one is the fallback for archives the first can't open).
    enum ArchiveEngineChoice: String, CaseIterable {
        case sevenZip = "7zip"
        case system = "libarchive"
        var title: String { self == .sevenZip ? "7-Zip (bundled)" : "macOS (libarchive)" }
    }
    var archiveEngine: ArchiveEngineChoice {
        didSet { guard archiveEngine != oldValue else { return }; save(archiveEngine.rawValue, .archiveEngine) }
    }
    /// What Compress writes (7z by default).
    var archiveFormat: ArchiveFormat {
        didSet { guard archiveFormat != oldValue else { return }; save(archiveFormat.rawValue, .archiveFormat) }
    }
    var archiveLevel: ArchiveLevel {
        didSet { guard archiveLevel != oldValue else { return }; save(archiveLevel.rawValue, .archiveLevel) }
    }

    /// List zoom: the text size of the file list (⌘+ / ⌘− / ⌘0 step through `textSizes`); rows and icons follow.
    static let textSizes = [11, 12, 13, 14, 15, 16, 18, 20]
    static let defaultTextSize = 13
    var listTextSize: Int {
        didSet {
            let clean = Self.nearestTextSize(listTextSize)
            if clean != listTextSize { listTextSize = clean; return }
            guard listTextSize != oldValue else { return }
            save(listTextSize, .listTextSize)
        }
    }
    static func nearestTextSize(_ size: Int) -> Int {
        textSizes.min { abs($0 - size) < abs($1 - size) } ?? defaultTextSize
    }
    /// One step bigger (+1) or smaller (−1); false at the end of the range.
    @discardableResult
    func stepTextSize(_ direction: Int) -> Bool {
        guard let index = Self.textSizes.firstIndex(of: listTextSize) else { listTextSize = Self.defaultTextSize; return true }
        let next = index + direction
        guard Self.textSizes.indices.contains(next) else { return false }
        listTextSize = Self.textSizes[next]
        return true
    }

    /// Space around each row's text.
    enum Density: String, CaseIterable {
        case compact, standard, comfortable
        var title: String { rawValue.capitalized }
        /// Points added to the text's line height.
        var padding: Double {
            switch self {
            case .compact: 2
            case .standard: 6
            case .comfortable: 12
            }
        }
    }
    var listDensity: Density {
        didSet { guard listDensity != oldValue else { return }; save(listDensity.rawValue, .listDensity) }
    }

    /// The most used folders menu (next to the tab strip): how many it shows, what a use is worth, and how long a
    /// folder must stay open to count (passing through doesn't).
    enum Importance: String, CaseIterable {
        case off, low, medium, high
        var weight: Double {
            switch self {
            case .off: 0
            case .low: 1
            case .medium: 2
            case .high: 4
            }
        }
        var title: String {
            switch self {
            case .off: "Not counted"
            case .low: "Low (×1)"
            case .medium: "Medium (×2)"
            case .high: "High (×4)"
            }
        }
    }
    static let usageTopCounts = [5, 10, 15, 20, 30]
    static let usageDwellChoices = [1, 2, 3, 5, 10]
    var usageTopCount: Int {
        didSet {
            let clean = min(max(usageTopCount, 1), 50)
            if clean != usageTopCount { usageTopCount = clean; return }
            guard usageTopCount != oldValue else { return }
            save(usageTopCount, .usageTopCount)
        }
    }
    var usageOpenWeight: Importance {
        didSet { guard usageOpenWeight != oldValue else { return }; save(usageOpenWeight.rawValue, .usageOpenWeight) }
    }
    var usageTabWeight: Importance {
        didSet { guard usageTabWeight != oldValue else { return }; save(usageTabWeight.rawValue, .usageTabWeight) }
    }
    /// Seconds a folder must stay shown before it counts.
    var usageDwell: Int {
        didSet {
            let clean = min(max(usageDwell, 0), 60)
            if clean != usageDwell { usageDwell = clean; return }
            guard usageDwell != oldValue else { return }
            save(usageDwell, .usageDwell)
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
        folderSizes = defaults.object(forKey: Key.folderSizes.rawValue) as? Bool ?? true
        folderSizesOnNetwork = defaults.bool(forKey: Key.folderSizesOnNetwork.rawValue)
        networkTrashFolders = defaults.bool(forKey: Key.networkTrashFolders.rawValue)
        openArchivesAsFolders = defaults.object(forKey: Key.openArchivesAsFolders.rawValue) as? Bool ?? true
        terminalApp = defaults.data(forKey: Key.terminalApp.rawValue).flatMap { try? JSONDecoder().decode(AppChoice.self, from: $0) } ?? .terminal
        editorApp = defaults.data(forKey: Key.editorApp.rawValue).flatMap { try? JSONDecoder().decode(AppChoice.self, from: $0) }
        archiveEngine = defaults.string(forKey: Key.archiveEngine.rawValue).flatMap(ArchiveEngineChoice.init(rawValue:)) ?? .sevenZip
        archiveFormat = defaults.string(forKey: Key.archiveFormat.rawValue).flatMap(ArchiveFormat.init(rawValue:)) ?? .sevenZip
        archiveLevel = defaults.string(forKey: Key.archiveLevel.rawValue).flatMap(ArchiveLevel.init(rawValue:)) ?? .normal
        listTextSize = Self.nearestTextSize(defaults.object(forKey: Key.listTextSize.rawValue) as? Int ?? Self.defaultTextSize)
        listDensity = defaults.string(forKey: Key.listDensity.rawValue).flatMap(Density.init(rawValue:)) ?? .standard
        usageTopCount = min(max(defaults.object(forKey: Key.usageTopCount.rawValue) as? Int ?? 10, 1), 50)
        usageOpenWeight = defaults.string(forKey: Key.usageOpenWeight.rawValue).flatMap(Importance.init(rawValue:)) ?? .high
        usageTabWeight = defaults.string(forKey: Key.usageTabWeight.rawValue).flatMap(Importance.init(rawValue:)) ?? .medium
        usageDwell = min(max(defaults.object(forKey: Key.usageDwell.rawValue) as? Int ?? 3, 0), 60)
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
        case .fileExtension: 50
        case .size: 50
        }
    }

    private func save(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: self, userInfo: ["key": key.rawValue])
    }
}
