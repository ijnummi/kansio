import Darwin
import Foundation

/// A folder in the navigation-pane tree. A class: the outline view keys rows by object identity,
/// so a node keeps its identity (and its expansion) across renames and re-listings.
///
/// Not thread-safe: owned by one actor (the app uses it on the main actor). Listing happens
/// elsewhere (`FolderTreeIO`); results are applied with `FolderTree.apply`.
public final class TreeNode {
    public enum Kind: Sendable, Equatable {
        case home, volume
        case folder
        /// Symlink to a folder: shown with a badge, expands under its own (logical) path.
        case link
    }

    public let kind: Kind
    public private(set) var name: String
    public private(set) var fileID: UInt64
    public private(set) var isHidden: Bool
    public private(set) weak var parent: TreeNode?
    /// Roots only: their location and display title.
    private let rootURL: URL?
    public let title: String
    /// Everything below a network volume root.
    public let isNetwork: Bool

    /// Every listed subfolder, hidden ones included, in Finder order; nil until listed.
    public fileprivate(set) var allChildren: [TreeNode]?
    /// The subfolders shown (hidden ones only when hidden files are shown).
    public fileprivate(set) var children: [TreeNode] = []
    /// Result of the background "has a subfolder?" check; nil = unknown.
    public var hasSubfolders: Bool?
    /// The resolved path of the listed folder (FSEvents reports real paths).
    public fileprivate(set) var realPath: String?
    /// The last listing failed (permission denied, timeout…): shown as an inline error.
    public var listingError: String?
    public fileprivate(set) var isExpanded = false
    public fileprivate(set) var expandedAutomatically = false

    fileprivate init(root url: URL, title: String, kind: Kind, isNetwork: Bool) {
        self.kind = kind
        self.name = url.lastPathComponent
        self.fileID = 0
        self.isHidden = false
        self.rootURL = url
        self.title = title
        self.isNetwork = isNetwork
    }

    fileprivate init(item: FileItem, parent: TreeNode) {
        kind = item.kind == .symlink ? .link : .folder
        name = item.name
        fileID = item.fileID
        isHidden = item.isHidden
        self.parent = parent
        rootURL = nil
        title = item.name
        isNetwork = parent.isNetwork
    }

    public var isRoot: Bool { rootURL != nil }
    public var isListed: Bool { allChildren != nil }
    /// The logical location (through links, like the file list).
    public var url: URL {
        if let rootURL { return rootURL }
        guard let parent else { return URL(filePath: "/" + name, directoryHint: .isDirectory) }
        return parent.url.appending(path: name, directoryHint: .isDirectory)
    }
    public var path: String { FolderTree.normalized(url.path(percentEncoded: false)) }
    public var displayName: String { isRoot ? title : name }
    public var depth: Int { parent.map { $0.depth + 1 } ?? 0 }
    /// Root first, self last.
    public var ancestry: [TreeNode] { (parent?.ancestry ?? []) + [self] }

    /// Whether the row shows a disclosure triangle.
    /// - Listed: only if it has shown subfolders.
    /// - Links: always (the target may be a dead mount — no background check).
    /// - Network volumes: optimistic unless `checkNetwork` (then like local).
    /// - Local: only once the check found a subfolder (no flicker from "maybe" to "no").
    public func showsDisclosure(checkNetwork: Bool) -> Bool {
        if isListed { return !children.isEmpty }
        if kind == .link || (isRoot && listingError == nil) { return true }
        if isNetwork && !checkNetwork { return hasSubfolders ?? true }
        return hasSubfolders ?? false
    }

    /// Whether the background subfolder check should run for this (unlisted) node.
    public func needsSubfolderCheck(checkNetwork: Bool) -> Bool {
        !isListed && hasSubfolders == nil && kind == .folder && (!isNetwork || checkNetwork)
    }

    fileprivate func update(from item: FileItem) {
        name = item.name
        fileID = item.fileID
        isHidden = item.isHidden
    }
}

/// The navigation-pane folder tree (P1-1): roots (Home, volumes), lazily listed children, the
/// automatic reveal's bookkeeping, and minimal row operations for every change.
public final class FolderTree {
    public struct RootSpec: Sendable, Equatable {
        public let url: URL
        public let title: String
        public let kind: TreeNode.Kind
        public let isNetwork: Bool
        public init(url: URL, title: String, kind: TreeNode.Kind, isNetwork: Bool) {
            self.url = url
            self.title = title
            self.kind = kind
            self.isNetwork = isNetwork
        }
    }

    /// The change to one node's shown children: apply `plan` to the old rows.
    public struct ChildrenChange {
        public let parent: TreeNode
        public let plan: TreeDiff.Plan
        /// Kept nodes whose name changed (their rows need redrawing).
        public let renamed: [TreeNode]
        /// Nodes that left the tree (their own subtrees went with them).
        public let removed: [TreeNode]
    }

    public private(set) var roots: [TreeNode] = []
    public private(set) var showHidden: Bool
    private var listedByRealPath: [String: [ObjectIdentifier: TreeNode]] = [:]
    private var autoExpanded: [ObjectIdentifier: TreeNode] = [:]

    public init(showHidden: Bool = false) {
        self.showHidden = showHidden
    }

    // MARK: Roots

    /// Replaces the roots, keeping the node (and its expansion) of every root whose URL is unchanged.
    /// Returns the roots that went away.
    @discardableResult
    public func setRoots(_ specs: [RootSpec]) -> [TreeNode] {
        let old = roots
        roots = specs.map { spec in
            old.first { $0.url == spec.url && $0.kind == spec.kind && $0.title == spec.title }
                ?? TreeNode(root: spec.url, title: spec.title, kind: spec.kind, isNetwork: spec.isNetwork)
        }
        let removed = old.filter { o in !roots.contains { $0 === o } }
        removed.forEach(forget)
        return removed
    }

    // MARK: Listing results

    /// Applies a listing of `node`'s folder: `items` are its folder-like entries (folders and links to
    /// folders, packages excluded) in Finder order (`FolderTreeIO.listFolders`). Existing nodes are
    /// kept by inode (a rename keeps the node), so expansion survives.
    public func apply(_ items: [FileItem], realPath: String?, to node: TreeNode) -> ChildrenChange {
        let oldShown = node.children
        let oldAll = node.allChildren ?? []
        var byID: [UInt64: TreeNode] = [:]
        var byName: [String: TreeNode] = [:]
        for child in oldAll {
            if child.fileID != 0 { byID[child.fileID] = child }
            byName[child.name] = child
        }
        var renamed: [TreeNode] = []
        var used = Set<ObjectIdentifier>()
        let newAll: [TreeNode] = items.map { item in
            let kind: TreeNode.Kind = item.kind == .symlink ? .link : .folder
            let match = (item.fileID != 0 ? byID[item.fileID] : nil) ?? byName[item.name]
            if let match, match.kind == kind, !used.contains(ObjectIdentifier(match)) {
                used.insert(ObjectIdentifier(match))
                if match.name != item.name || match.isHidden != item.isHidden {
                    if match.name != item.name { renamed.append(match) }
                    match.update(from: item)
                }
                return match
            }
            return TreeNode(item: item, parent: node)
        }
        let removed = oldAll.filter { !used.contains(ObjectIdentifier($0)) }
        removed.forEach(forget)
        node.allChildren = newAll
        node.children = visible(newAll)
        node.hasSubfolders = !node.children.isEmpty
        node.listingError = nil
        register(node, realPath: realPath)
        return ChildrenChange(parent: node, plan: TreeDiff.plan(old: oldShown, new: node.children),
                              renamed: renamed, removed: removed)
    }

    /// Hidden folders shown or not: one change per listed node whose shown children differ.
    /// Unlisted nodes forget their subfolder check (the answer depends on the setting).
    public func setShowHidden(_ show: Bool) -> [ChildrenChange] {
        guard show != showHidden else { return [] }
        showHidden = show
        var changes: [ChildrenChange] = []
        func visit(_ node: TreeNode) {
            guard let all = node.allChildren else {
                if node.kind == .folder { node.hasSubfolders = nil }
                return
            }
            let old = node.children
            node.children = visible(all)
            node.hasSubfolders = !node.children.isEmpty
            let hiddenGone = old.filter { o in !node.children.contains { $0 === o } }
            if old.count != node.children.count || !hiddenGone.isEmpty {
                changes.append(ChildrenChange(parent: node, plan: TreeDiff.plan(old: old, new: node.children),
                                              renamed: [], removed: []))
            }
            all.forEach(visit) // hidden subtrees keep their listing for when they come back
        }
        roots.forEach(visit)
        return changes
    }

    /// The listing of `node` failed: no children, an inline error.
    public func listingFailed(_ node: TreeNode, message: String) {
        node.listingError = message
    }

    private func visible(_ nodes: [TreeNode]) -> [TreeNode] {
        showHidden ? nodes : nodes.filter { !$0.isHidden }
    }

    // MARK: Reveal

    /// The most specific root containing `url` and the folder names below it ("~/a/b" → Home, ["a", "b"]).
    public func revealTarget(for url: URL) -> (root: TreeNode, names: [String])? {
        let path = Self.normalized(url.path(percentEncoded: false))
        var best: (root: TreeNode, length: Int)?
        for root in roots {
            let rootPath = root.path
            let inside = rootPath == "/" ? path.hasPrefix("/") : (path == rootPath || path.hasPrefix(rootPath + "/"))
            if inside, rootPath.count > (best?.length ?? -1) { best = (root, rootPath.count) }
        }
        guard let best else { return nil }
        let rest = path.dropFirst(best.root.path == "/" ? 1 : best.root.path.count)
        return (best.root, rest.split(separator: "/").map(String.init))
    }

    /// A shown child by name (canonically equivalent names match, like the file list).
    public func child(of node: TreeNode, named name: String) -> TreeNode? {
        node.children.first { $0.name == name }
    }

    /// The deepest node on the way to `url` that's currently visible (all ancestors expanded),
    /// and whether it is `url` itself.
    public func deepestVisible(toward url: URL) -> (node: TreeNode, isTarget: Bool)? {
        guard let (root, names) = revealTarget(for: url) else { return nil }
        var node = root
        for (i, name) in names.enumerated() {
            guard node.isExpanded, let child = child(of: node, named: name) else { return (node, false) }
            node = child
            if i == names.count - 1 { return (node, true) }
        }
        return (node, true)
    }

    // MARK: Expansion bookkeeping

    /// `automatically`: opened by the reveal (collapses again when left); otherwise by hand (stays).
    public func didExpand(_ node: TreeNode, automatically: Bool) {
        let id = ObjectIdentifier(node)
        if node.isExpanded && !automatically {
            node.expandedAutomatically = false // the user took it over
            autoExpanded[id] = nil
            return
        }
        guard !node.isExpanded else { return }
        node.isExpanded = true
        node.expandedAutomatically = automatically
        if automatically { autoExpanded[id] = node } else { autoExpanded[id] = nil }
    }

    public func didCollapse(_ node: TreeNode) {
        node.isExpanded = false
        node.expandedAutomatically = false
        autoExpanded[ObjectIdentifier(node)] = nil
    }

    /// Branches the reveal opened that aren't on `path` any more — deepest first, so collapsing them
    /// in order never collapses a parent before its child.
    public func autoExpandedToCollapse(keeping path: [TreeNode]) -> [TreeNode] {
        let keep = Set(path.map(ObjectIdentifier.init))
        return autoExpanded.values.filter { !keep.contains(ObjectIdentifier($0)) && $0.isExpanded }
            .sorted { $0.depth > $1.depth }
    }

    // MARK: Watching

    /// Listed nodes whose folder is `realPath` (several when links lead to the same folder).
    public func listedNodes(atRealPath realPath: String) -> [TreeNode] {
        listedByRealPath[Self.normalized(realPath)].map { Array($0.values) } ?? []
    }

    /// Listed nodes at or below `realPath` (FSEvents "must rescan" for a subtree).
    public func listedNodes(underRealPath realPath: String) -> [TreeNode] {
        let base = Self.normalized(realPath)
        let prefix = base == "/" ? "/" : base + "/"
        return listedByRealPath.filter { $0.key == base || $0.key.hasPrefix(prefix) }.flatMap(\.value.values)
    }

    /// Every listed real path (what the watcher cares about).
    public var listedRealPaths: Set<String> { Set(listedByRealPath.keys) }

    private func register(_ node: TreeNode, realPath: String?) {
        if let old = node.realPath { listedByRealPath[old]?[ObjectIdentifier(node)] = nil }
        if let old = node.realPath, listedByRealPath[old]?.isEmpty == true { listedByRealPath[old] = nil }
        guard let realPath else { node.realPath = nil; return }
        let path = Self.normalized(realPath)
        node.realPath = path
        listedByRealPath[path, default: [:]][ObjectIdentifier(node)] = node
    }

    /// A node left the tree: drop it and its listed descendants from the indexes.
    private func forget(_ node: TreeNode) {
        if let path = node.realPath {
            listedByRealPath[path]?[ObjectIdentifier(node)] = nil
            if listedByRealPath[path]?.isEmpty == true { listedByRealPath[path] = nil }
        }
        autoExpanded[ObjectIdentifier(node)] = nil
        node.allChildren?.forEach(forget)
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Row operations that turn one list of nodes into another, in the order an outline view applies
/// them: remove (old indexes, one batch), then moves among the kept rows (renames that change the
/// order), then insert (new indexes, one batch). Kept nodes are never removed and re-inserted,
/// so their expansion survives.
public enum TreeDiff {
    public struct Plan: Equatable {
        public var removed = IndexSet()
        public var moves: [Move] = []
        public var inserted = IndexSet()
        public var isEmpty: Bool { removed.isEmpty && moves.isEmpty && inserted.isEmpty }
    }

    public struct Move: Equatable {
        public let from: Int
        public let to: Int
    }

    public static func plan(old: [TreeNode], new: [TreeNode]) -> Plan {
        var plan = Plan()
        let newIDs = Set(new.map(ObjectIdentifier.init))
        let oldIDs = Set(old.map(ObjectIdentifier.init))
        for (i, node) in old.enumerated() where !newIDs.contains(ObjectIdentifier(node)) { plan.removed.insert(i) }
        var kept = old.filter { newIDs.contains(ObjectIdentifier($0)) }
        let target = new.filter { oldIDs.contains(ObjectIdentifier($0)) }
        if kept.count == target.count, !zip(kept, target).allSatisfy({ $0 === $1 }) {
            // Rows whose relative order is unchanged (longest increasing run of target positions)
            // stay; each other row moves once, to just after its new predecessor.
            var targetIndex: [ObjectIdentifier: Int] = [:]
            for (i, node) in target.enumerated() { targetIndex[ObjectIdentifier(node)] = i }
            let stable = longestIncreasing(kept.map { targetIndex[ObjectIdentifier($0)]! })
            for (i, node) in target.enumerated() where !stable.contains(i) {
                guard let from = kept.firstIndex(where: { $0 === node }) else { continue }
                kept.remove(at: from)
                let to = i == 0 ? 0 : (kept.firstIndex(where: { $0 === target[i - 1] }).map { $0 + 1 } ?? 0)
                kept.insert(node, at: to)
                plan.moves.append(Move(from: from, to: to))
            }
        }
        for (i, node) in new.enumerated() where !oldIDs.contains(ObjectIdentifier(node)) { plan.inserted.insert(i) }
        return plan
    }

    /// The values of one longest strictly increasing subsequence (patience sorting, O(n log n)).
    static func longestIncreasing(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = [] // index into values of the smallest tail for each length
        var previous = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var result = Set<Int>()
        var i = tails.last ?? -1
        while i >= 0 { result.insert(values[i]); i = previous[i] }
        return result
    }

    /// Applies a plan to an array the way the outline view will (used by tests).
    public static func apply<T>(_ plan: Plan, to old: [T], new: [T]) -> [T] {
        var rows = old
        for i in plan.removed.reversed() { rows.remove(at: i) }
        for move in plan.moves { rows.insert(rows.remove(at: move.from), at: move.to) }
        for i in plan.inserted { rows.insert(new[i], at: i) }
        return rows
    }
}
