import AppKit
import FileSystemKit

/// M14: the status bar's contents.
extension FileListViewController {
    /// Selections up to this size are summed right away (well under a millisecond); bigger ones off-main.
    static let inlineSumLimit = 50_000

    func updateStatusBar() {
        guard isViewLoaded, !statusBar.isHidden else { return }
        statusVersion += 1
        let version = statusVersion
        let number = Formatters.count

        // Left: items (and how many are hidden).
        if let error = state.error {
            statusBar.countLabel.stringValue = error.code == .permissionDenied ? "No permission" : "Unavailable"
        } else if let search {
            let n = rows.count
            let found = "\(number.string(from: NSNumber(value: n)) ?? "\(n)") found for “\(search.query)”"
            statusBar.countLabel.stringValue = search.walkDone ? found + " (with subfolders)" : found + " — searching subfolders…"
        } else if isLoading && rows.isEmpty {
            statusBar.countLabel.stringValue = "Loading…"
        } else {
            let n = rows.count
            var text = "\(number.string(from: NSNumber(value: n)) ?? "\(n)") \(n == 1 ? "item" : "items")"
            let hidden = contents.items.count - n
            if !ViewSettings.shared.showHidden && hidden > 0 { text += " (\(hidden) hidden)" }
            if isLoading { text += " …" }
            statusBar.countLabel.stringValue = text
        }

        // Middle: selection and the size of the selected files (folders have no size here).
        let selection = tableView.selectedRowIndexes
        if selection.isEmpty {
            statusBar.selectionLabel.stringValue = ""
        } else {
            let k = selection.count
            let prefix = "\(number.string(from: NSNumber(value: k)) ?? "\(k)") \(k == 1 ? "item" : "items") selected"
            if k <= Self.inlineSumLimit {
                statusBar.selectionLabel.stringValue = prefix + Self.sizeSuffix(Self.selectedBytes(rows, selection, folderSizes))
            } else {
                statusBar.selectionLabel.stringValue = prefix + "  Calculating…"
                let rows = self.rows
                let sizes = folderSizes
                Task.detached(priority: .userInitiated) { [weak self] in
                    let bytes = Self.selectedBytes(rows, selection, sizes)
                    await self?.finishSelectionSum(prefix: prefix, bytes: bytes, version: version)
                }
            }
        }

        // Right: free space on this volume (cached; fetched off-main).
        let shown = folder
        // Inside an archive: the volume the archive is on.
        let volumeFolder = archiveIndex.map { URL(filePath: ($0.archivePath as NSString).deletingLastPathComponent, directoryHint: .isDirectory) } ?? shown
        switch FreeSpace.available(for: volumeFolder, refresh: { [weak self] bytes in
            guard let self, self.folder == shown else { return }
            self.statusBar.spaceLabel.stringValue = Self.spaceText(bytes)
        }) {
        case .some(let bytes): statusBar.spaceLabel.stringValue = Self.spaceText(bytes)
        case .none: break // filled in when known
        }
    }

    private func finishSelectionSum(prefix: String, bytes: Int64?, version: Int) {
        guard version == statusVersion else { return }
        statusBar.selectionLabel.stringValue = prefix + Self.sizeSuffix(bytes)
    }

    /// Total size of the selected files and of selected folders whose size is known (P1-6); nil if none.
    nonisolated static func selectedBytes(_ rows: [FileItem], _ selection: IndexSet, _ folderSizes: [String: Int64] = [:]) -> Int64? {
        var total: Int64 = 0
        var counted = 0
        rows.withUnsafeBufferPointer { rows in
            for i in selection where i < rows.count {
                if rows[i].kind == .file {
                    total += rows[i].size
                    counted += 1
                } else if rows[i].kind == .directory, let size = folderSizes[rows[i].name] {
                    total += size
                    counted += 1
                }
            }
        }
        return counted > 0 ? total : nil
    }

    static func sizeSuffix(_ bytes: Int64?) -> String {
        bytes.map { "  " + Formatters.size.string(fromByteCount: $0) } ?? ""
    }

    static func spaceText(_ bytes: Int64?) -> String {
        bytes.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) available" } ?? ""
    }

    /// ⌘/ (View ▸ Show/Hide Status Bar): one global setting.
    func setStatusBarVisible(_ visible: Bool) {
        ViewSettings.shared.showStatusBar = visible // → viewSettingChanged → applyStatusBarVisibility
    }

    func applyStatusBarVisibility() {
        let visible = ViewSettings.shared.showStatusBar
        statusBar.isHidden = !visible
        let height = visible ? StatusBarView.height : 0
        scrollView.frame = NSRect(x: 0, y: height, width: view.bounds.width, height: view.bounds.height - height)
        if visible { updateStatusBar() }
    }
}
