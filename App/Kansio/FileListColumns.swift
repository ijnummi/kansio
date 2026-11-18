import AppKit
import FileSystemKit

/// Columns and the global view setting (M16): one column layout (order, widths, which are shown),
/// one sort and one hidden-files state for every folder. The list writes user changes (header
/// drag, resize, the header's right-click menu) into `ViewSettings`; `ViewSettings` notifies, and
/// every list applies the setting — one code path for local and remote changes.
extension FileListViewController {
    static func columnTitle(_ field: FileSort.Field) -> String {
        switch field {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .kind: "Type"
        case .fileExtension: "Extension"
        case .size: "Size"
        }
    }

    /// Creates the columns in the saved order and applies the saved layout.
    func setUpColumns() {
        for column in settings.columns {
            let field = column.field
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            tableColumn.title = Self.columnTitle(field)
            tableColumn.minWidth = ViewSettings.minimumWidth(field)
            tableColumn.maxWidth = 4000
            tableColumn.headerCell.alignment = field == .size ? .right : .left
            // Explorer: names A→Z first; dates and sizes newest/largest first.
            let ascending = field == .name || field == .kind || field == .fileExtension
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: ascending)
            tableView.addTableColumn(tableColumn)
        }
        applyColumnSettings()
        tableView.headerView = FileListHeaderView(frame: tableView.headerView?.frame ?? NSRect(x: 0, y: 0, width: 0, height: 28))
        let menu = NSMenu(title: "Columns")
        menu.delegate = columnMenuDelegate
        tableView.headerView?.menu = menu
        columnMenuDelegate.list = self

        let center = NotificationCenter.default
        for name in [NSTableView.columnDidMoveNotification, NSTableView.columnDidResizeNotification] {
            center.addObserver(forName: name, object: tableView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.columnsChangedInTable() }
            }
        }
        center.addObserver(forName: .viewSettingsDidChange, object: nil, queue: nil) { [weak self] note in
            let key = (note.userInfo?["key"] as? String).flatMap(ViewSettings.Key.init(rawValue:))
            MainActor.assumeIsolated { if let key { self?.viewSettingChanged(key) } }
        }
    }

    /// The table's current layout, in display order.
    var columnLayout: [ViewSettings.Column] {
        tableView.tableColumns.compactMap { column in
            FileSort.Field(rawValue: column.identifier.rawValue).map {
                ViewSettings.Column(field: $0, width: Double(column.width), hidden: column.isHidden)
            }
        }
    }

    /// Makes the table match `settings.columns` (no-op when it already does).
    func applyColumnSettings() {
        let wanted = settings.columns
        guard columnLayout != wanted else { return }
        isApplyingColumns = true
        defer { isApplyingColumns = false }
        if isShowingTrash { removeTrashColumns() } // they're put back after Name below
        defer { if isShowingTrash { addTrashColumns() } }
        for (index, setting) in wanted.enumerated() {
            let current = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(setting.field.rawValue))
            guard current >= 0 else { continue }
            if current != index { tableView.moveColumn(current, toColumn: index) }
            let column = tableView.tableColumns[index]
            if column.isHidden != setting.hidden { column.isHidden = setting.hidden }
            if Double(column.width) != setting.width { column.width = CGFloat(setting.width) }
        }
    }

    /// The user dragged or resized a column: that's the new global layout.
    private func columnsChangedInTable() {
        guard !isApplyingColumns else { return }
        let layout = columnLayout
        if layout != settings.columns { settings.columns = layout }
    }

    private func viewSettingChanged(_ key: ViewSettings.Key) {
        switch key {
        case .columns:
            applyColumnSettings()
        case .sort:
            let descriptor = NSSortDescriptor(key: settings.sort.field.rawValue, ascending: settings.sort.ascending)
            if tableView.sortDescriptors.first.map({ $0.key != descriptor.key || $0.ascending != descriptor.ascending }) ?? true {
                tableView.sortDescriptors = [descriptor]
            }
            resort()
        case .showHidden:
            resort()
            updateStatusBar()
            folderSizesModelChanged() // hidden folders shown now get sizes
        case .showStatusBar:
            applyStatusBarVisibility()
        case .treeExpandToCurrent, .treeExpandOnNetwork, .treeCheckNetwork, .treeKeyDelay:
            break // the navigation pane's
        case .archiveEngine, .archiveFormat, .archiveLevel:
            break // read when Compress/Extract runs (the menu's names are built when it opens)
        case .folderSizes, .folderSizesOnNetwork:
            folderSizeSettingChanged()
        case .networkTrashFolders:
            break // TrashService's
        case .listTextSize, .listDensity:
            applyListMetrics()
        case .usageTopCount, .usageOpenWeight, .usageTabWeight, .usageDwell:
            break // the most used folders menu's
        }
    }

    // MARK: Zoom (text size, row density)

    /// Applies the list's zoom: row height, fonts and icon size. The row at the top stays at the top; no reload
    /// (the visible cells just redraw).
    func applyListMetrics() {
        let metrics = ListMetrics.current
        let visible = tableView.visibleRect
        let anchor = tableView.numberOfRows > 0 ? max(0, tableView.row(at: NSPoint(x: visible.minX, y: visible.minY))) : -1
        let fraction = anchor >= 0 && tableView.rowHeight > 0
            ? (visible.minY - tableView.rect(ofRow: anchor).minY) / tableView.rowHeight : 0
        if tableView.rowHeight != metrics.rowHeight { tableView.rowHeight = metrics.rowHeight }
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as FileCellView in rowView.subviews { cell.needsDisplay = true }
        }
        if anchor >= 0, anchor < tableView.numberOfRows {
            let y = tableView.rect(ofRow: anchor).minY + fraction * metrics.rowHeight
            tableView.scroll(NSPoint(x: visible.minX, y: max(0, y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        layoutRenameEditor()
    }

    // MARK: Actions (header menu, View ▸ Columns)

    /// Shows or hides the column in `sender.representedObject` (a `FileSort.Field` raw value).
    @objc func toggleColumn(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let field = FileSort.Field(rawValue: raw),
              field != .name, let index = settings.columns.firstIndex(where: { $0.field == field }) else { return }
        settings.columns[index].hidden.toggle()
    }

    @objc func resetColumns(_ sender: Any?) { settings.resetColumns() }

    /// Checkmark and enabled state for a column item (Name can't be hidden).
    func validateColumnItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let field = FileSort.Field(rawValue: raw) else { return false }
        item.state = settings.columns.first { $0.field == field }?.hidden == false ? .on : .off
        return field != .name
    }

    /// "Name ✓, Date Modified ✓, …, Reset Columns": the header's right-click menu and View ▸ Columns.
    /// Columns in menu order (Name first; it can't be hidden).
    static let columnMenuOrder: [FileSort.Field] = [.name, .dateModified, .dateCreated, .kind, .fileExtension, .size]

    static func columnMenuItems(target: AnyObject?) -> [NSMenuItem] {
        var items = columnMenuOrder.map { field in
            let item = NSMenuItem(title: columnTitle(field), action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.representedObject = field.rawValue
            item.target = target
            return item
        }
        items.append(.separator())
        let reset = NSMenuItem(title: "Reset Columns", action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = target
        items.append(reset)
        return items
    }
}

/// Fills the header's right-click menu when it opens.
@MainActor
final class ColumnMenuDelegate: NSObject, NSMenuDelegate {
    weak var list: FileListViewController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        FileListViewController.columnMenuItems(target: list).forEach(menu.addItem)
    }
}

/// Explorer: every click on a column header sorts, so clicking twice quickly reverses the order.
/// `NSTableHeaderView` treats the second click inside the double-click interval (`clickCount` 2, 4, …)
/// as a double-click and doesn't sort — sorting then only worked when clicking slowly. Pass every
/// click on as a single click. (Nothing uses header double-clicks: no auto-fit on divider double-click.)
@MainActor
final class FileListHeaderView: NSTableHeaderView {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount > 1,
              let single = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                              timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                              eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure)
        else { return super.mouseDown(with: event) }
        super.mouseDown(with: single)
    }
}

