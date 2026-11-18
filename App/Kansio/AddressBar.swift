import AppKit
import FileSystemKit

/// Explorer-style address bar, shown under the toolbar for the whole window width.
///
/// Breadcrumb mode: one button per path segment (the volume first). Clicking empty space in
/// the bar, or ⌘L / ⇧⌘G, switches to edit mode: a text field with the full path selected.
/// While typing, folder completions are listed off the main thread. Enter navigates; a file
/// path opens its folder with the file selected; a bad path shows an inline error and stays
/// in edit mode (never a modal). Esc closes the suggestions, then cancels editing.
@MainActor
final class AddressBarController: NSTitlebarAccessoryViewController, NSTextFieldDelegate, NSSearchFieldDelegate {
    /// Navigate to a folder, selecting the given names in it.
    var onNavigate: ((URL, [String]) -> Void)?
    /// Editing ended (committed or cancelled): give focus back to the list.
    var onFinishEditing: (() -> Void)?
    /// Whether hidden folders are offered as completions.
    var includeHidden: () -> Bool = { false }
    /// Search (P1-5): the text changed (empty = end); Return / Esc in the field.
    var onSearch: ((String) -> Void)?
    var onSearchReturn: (() -> Void)?
    var onSearchEscape: (() -> Void)?
    /// The search field got focus: a good moment to prepare the search index.
    var onSearchFocus: (() -> Void)?
    var searchField: NSSearchField { bar.search }

    private(set) var folder = URL(filePath: "/", directoryHint: .isDirectory)
    var volumes: [Volume] = [] { didSet { if volumes != oldValue { rebuildCrumbs() } } }

    let field = NSTextField()
    private let bar = AddressBarView()
    private let crumbs = NSView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let popup = CompletionPopup()
    private let completer = PathCompleter()
    private var completionTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var isCommitting = false
    private(set) var isEditing = false

    static let height: CGFloat = 34

    override func loadView() {
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: Self.height)
        bar.onClickEmptyArea = { [weak self] in self?.beginEditing() }
        bar.setAccessibilityElement(false)

        crumbs.autoresizingMask = [.width, .height]
        bar.box.addSubview(crumbs)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.isHidden = true
        field.setAccessibilityLabel("Address")
        bar.box.addSubview(field)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.alignment = .right
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        bar.box.addSubview(errorLabel)

        popup.onPick = { [weak self] completion in self?.accept(completion, thenNavigate: true) }

        bar.search.delegate = self
        bar.search.target = self
        bar.search.action = #selector(searchFieldAction(_:)) // the ⓧ button clears
        bar.search.sendsSearchStringImmediately = true
        bar.search.setAccessibilityLabel("Search this folder and its subfolders")
        updateSearchPlaceholder()

        bar.onLayout = { [weak self] in self?.layoutContents() }
        view = bar
        layoutAttribute = .bottom
        fullScreenMinHeight = Self.height
    }

    // MARK: Breadcrumb mode

    func show(folder: URL) {
        guard folder != self.folder || segments.isEmpty else { return }
        self.folder = folder
        rebuildCrumbs()
        updateSearchPlaceholder()
    }

    // MARK: Search field (P1-5)

    /// Back / Forward / Up at the start of the row (they act on the selected tab, like the path).
    func setLeadingButtons(_ buttons: [NSButton]) {
        _ = view
        bar.leadingButtons.forEach { $0.removeFromSuperview() }
        bar.leadingButtons = buttons
        buttons.forEach { bar.addSubview($0) }
        bar.needsLayout = true
    }

    /// The selected tab changed: show its search text (without searching again).
    func setSearchText(_ text: String) {
        _ = view
        if bar.search.stringValue != text { bar.search.stringValue = text }
    }

    /// ⌘F.
    func focusSearch() {
        onSearchFocus?()
        view.window?.makeFirstResponder(bar.search)
        bar.search.currentEditor()?.selectAll(nil)
    }

    /// The search ended elsewhere (navigation): empty the field without reporting it.
    func clearSearch() {
        if !bar.search.stringValue.isEmpty { bar.search.stringValue = "" }
    }

    private func updateSearchPlaceholder() {
        bar.search.placeholderString = "Search “\(TrashService.title(for: folder))”"
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) { onSearch?(sender.stringValue) }

    /// Segments for the current folder. Buttons and separators are pooled and re-titled, not
    /// recreated: navigation updates the bar without allocating views (keeps the navigation
    /// frame cheap).
    private var segments: [Breadcrumb] = []
    private var buttonPool: [NSButton] = []
    private var separatorPool: [NSImageView] = []
    private lazy var overflowButton: NSButton = {
        let button = NSButton(title: "…", target: self, action: #selector(showOverflow(_:)))
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.setAccessibilityLabel("More folders")
        crumbs.addSubview(button)
        return button
    }()
    private static let chevron = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!
    private var hiddenSegmentCount = 0

    /// Creates (hidden) breadcrumb buttons up front, in idle time, so navigating to a deeper folder
    /// for the first time doesn't create and measure new buttons in that frame.
    func warmUpCrumbs(_ count: Int = 14) {
        growPools(to: count)
        layoutContents()
    }

    private func growPools(to count: Int) {
        while buttonPool.count < count {
            let button = NSButton(title: "", target: self, action: #selector(crumbClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: NSFont.systemFontSize)
            button.lineBreakMode = .byTruncatingMiddle
            button.isHidden = true
            crumbs.addSubview(button)
            buttonPool.append(button)
        }
        while separatorPool.count < count {
            let separator = NSImageView(image: Self.chevron)
            separator.contentTintColor = .tertiaryLabelColor
            separator.setAccessibilityElement(false)
            separator.isHidden = true
            crumbs.addSubview(separator)
            separatorPool.append(separator)
        }
    }

    private func rebuildCrumbs() {
        // The Trash shows every Trash folder together: one crumb, not the path of ~/.Trash.
        segments = TrashService.shared.isTrash(folder) ? [Breadcrumb(title: "Trash", url: folder)]
            : Breadcrumbs.segments(for: folder, volumes: volumes)
        growPools(to: segments.count)
        for (i, crumb) in segments.enumerated() {
            let button = buttonPool[i]
            if button.title != crumb.title { button.title = crumb.title }
            button.tag = i
            button.toolTip = crumb.url.path(percentEncoded: false)
        }
        layoutContents()
    }

    /// Lays the segments out from the right (the current folder always visible). Segments that
    /// don't fit collapse into a leading "…" button whose menu lists them.
    private func layoutContents() {
        let box = bar.box.bounds
        let inner = box.safelyInset(dx: 6, dy: 0)
        let errorWidth = min(224, inner.width / 2)
        field.frame = NSRect(x: inner.minX, y: (box.height - 18) / 2,
                             width: max(0, inner.width - (errorLabel.isHidden ? 0 : errorWidth + 6)), height: 18)
        errorLabel.frame = NSRect(x: inner.maxX - errorWidth, y: (box.height - 16) / 2, width: errorWidth, height: 16)

        crumbs.frame = inner
        let separatorWidth: CGFloat = 14, overflowWidth: CGFloat = 28
        let count = segments.count
        let sizes = (0..<count).map { min(buttonPool[$0].intrinsicContentSize.width, 220) }
        var visibleFrom = count
        var used: CGFloat = 0
        for i in stride(from: count - 1, through: 0, by: -1) {
            let needed = sizes[i] + (i < count - 1 ? separatorWidth : 0)
            let reserve: CGFloat = i > 0 ? overflowWidth + separatorWidth : 0
            if used + needed + reserve > inner.width && i < count - 1 { break }
            used += needed
            visibleFrom = i
        }
        hiddenSegmentCount = visibleFrom
        let height = inner.height
        var x: CGFloat = 0
        var separatorIndex = 0
        func placeSeparator() {
            let separator = separatorPool[separatorIndex]
            separatorIndex += 1
            separator.isHidden = false
            separator.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
            x += separatorWidth
        }
        overflowButton.isHidden = visibleFrom == 0
        if visibleFrom > 0 {
            overflowButton.frame = NSRect(x: x, y: (height - 22) / 2, width: overflowWidth, height: 22)
            x += overflowWidth
            placeSeparator()
        }
        for (i, button) in buttonPool.enumerated() {
            guard i >= visibleFrom, i < count else { button.isHidden = true; continue }
            button.isHidden = false
            button.frame = NSRect(x: x, y: (height - 22) / 2, width: max(0, min(sizes[i], inner.width - x)), height: 22)
            x += button.frame.width
            if i < count - 1 { placeSeparator() }
        }
        for separator in separatorPool[separatorIndex...] { separator.isHidden = true }
        bar.crumbsEndX = crumbs.frame.minX + x
    }

    @objc private func crumbClicked(_ sender: NSButton) { navigate(toSegment: sender.tag) }

    private func navigate(toSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        onNavigate?(segments[index].url, [])
    }

    @objc private func showOverflow(_ sender: NSButton) {
        let menu = NSMenu()
        for i in stride(from: hiddenSegmentCount - 1, through: 0, by: -1) {
            let item = menu.addItem(withTitle: segments[i].title, action: #selector(overflowItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func overflowItemClicked(_ sender: NSMenuItem) { navigate(toSegment: sender.tag) }

    /// Clicks the breadcrumb for `path` (self-test).
    func clickCrumbForTesting(path: String) -> Bool {
        guard let index = segments.firstIndex(where: { $0.url.path(percentEncoded: false) == path }) else { return false }
        navigate(toSegment: index)
        return true
    }

    var crumbTitles: [String] { segments.map(\.title) }

    // MARK: Edit mode

    func beginEditing() {
        guard !isEditing else {
            field.currentEditor()?.selectAll(nil)
            return
        }
        isEditing = true
        crumbs.isHidden = true
        field.isHidden = false
        field.stringValue = folder.path(percentEncoded: false)
        clearError()
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func cancelEditing() { endEditing() }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        completionTask?.cancel()
        commitTask?.cancel()
        popup.hide()
        clearError()
        field.isHidden = true
        crumbs.isHidden = false
        onFinishEditing?()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.toolTip = PathInput.resolve(field.stringValue, relativeTo: folder)?.path(percentEncoded: false) ?? message
        errorLabel.isHidden = false
        bar.hasError = true
        layoutContents()
    }

    private func clearError() {
        guard !errorLabel.isHidden || bar.hasError else { return }
        errorLabel.isHidden = true
        bar.hasError = false
        layoutContents()
    }

    var errorMessage: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var suggestionNames: [String] { popup.items.map(\.name) }

    /// Resolves and checks the typed path off the main thread, then navigates or shows an error.
    func commit(_ text: String) {
        popup.hide()
        guard let url = PathInput.resolve(text, relativeTo: folder) else { endEditing(); return }
        // Inside an opened archive (P3-5): its folders aren't on disk; the list checks them against the archive.
        if let (index, inner) = ArchiveBrowser.location(of: url) {
            endEditing()
            if index.items(in: inner) != nil { onNavigate?(url, []) } else if let (parent, name) = parentLocation(of: url) { onNavigate?(parent, [name]) }
            return
        }
        commitTask?.cancel()
        isCommitting = true
        commitTask = Task { [weak self] in
            let target = await PathInput.target(of: url, timeout: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.isCommitting = false
            // Echo what was typed (short, recognisable); the tooltip has the full resolved path.
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch target {
            case .folder:
                self.endEditing()
                self.onNavigate?(url, [])
            case .item:
                self.endEditing()
                if let (parent, name) = parentLocation(of: url) { self.onNavigate?(parent, [name]) }
            case .missing:
                self.showError("Can’t find “\(shown)”.")
            case .noPermission:
                // Go there anyway: the list explains why it can't be shown and offers the fix (P1-9).
                self.endEditing()
                self.onNavigate?(url, [])
            case .failed(let code):
                self.showError("\(String(cString: strerror(code))): “\(shown)”.")
            case nil:
                self.showError("“\(shown)” isn’t responding.")
            }
        }
    }

    private func accept(_ completion: PathCompletion, thenNavigate: Bool) {
        field.stringValue = completion.text
        field.currentEditor()?.moveToEndOfDocument(nil)
        if thenNavigate { commit(completion.text) } else { updateCompletions() }
    }

    private func updateCompletions() {
        completionTask?.cancel()
        let text = field.stringValue
        let base = folder
        let hidden = includeHidden()
        completionTask = Task { [weak self, completer] in
            let results = await completer.completions(for: text, relativeTo: base, includeHidden: hidden)
            guard let self, !Task.isCancelled, self.isEditing, self.field.stringValue == text else { return }
            // Nothing to suggest, or the only suggestion is what's already typed.
            if results.isEmpty || (results.count == 1 && results[0].text == text) {
                self.popup.hide()
            } else {
                self.popup.show(results, below: self.bar.box, width: self.field.frame.width + 12)
            }
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === bar.search { onSearch?(bar.search.stringValue); return }
        clearError()
        updateCompletions()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if obj.object as AnyObject? === bar.search { onSearchFocus?() } // clicked into it
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as AnyObject? === bar.search { return }
        // Focus moved elsewhere (click in the list, Tab…): leave edit mode, as Explorer does.
        if isEditing && !isCommitting && !popup.isTracking { endEditing() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === bar.search {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): onSearchReturn?(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                bar.search.stringValue = ""
                onSearch?("")
                onSearchEscape?()
                return true
            default: return false
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let picked = popup.selected { accept(picked, thenNavigate: true) } else { commit(field.stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if popup.isVisible { popup.hide() } else { endEditing() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard popup.isVisible else { return false }
            popup.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard popup.isVisible else { return false }
            popup.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard popup.isVisible, let first = popup.selected ?? popup.items.first else { return false }
            accept(first, thenNavigate: false)
            return true
        default:
            return false
        }
    }
}

/// The bar's background: a rounded, field-like box; clicks on empty space start editing.
@MainActor
final class AddressBarView: NSView {
    let box = NSView()
    /// Explorer: the search box to the right of the address bar.
    let search = NSSearchField()
    static let searchWidth: CGFloat = 220
    var leadingButtons: [NSButton] = []
    var onClickEmptyArea: (() -> Void)?
    var onLayout: (() -> Void)?
    var crumbsEndX: CGFloat = 0
    var hasError = false { didSet { box.needsDisplay = true; updateBorder() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        addSubview(box)
        search.controlSize = .regular
        addSubview(search)
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let searchWidth = min(Self.searchWidth, max(0, bounds.width / 3))
        var x: CGFloat = 8
        for button in leadingButtons {
            button.frame = NSRect(x: x, y: ((bounds.height - 24) / 2).rounded(), width: 28, height: 24)
            x += 30
        }
        var boxFrame = bounds.safelyInset(dx: 10, dy: 4)
        if !leadingButtons.isEmpty {
            boxFrame.origin.x = x + 4
            boxFrame.size.width = max(0, bounds.width - 10 - boxFrame.minX)
        }
        boxFrame.size.width = max(0, boxFrame.width - searchWidth - 8)
        box.frame = boxFrame
        let height: CGFloat = 26
        search.frame = NSRect(x: boxFrame.maxX + 8, y: ((bounds.height - height) / 2).rounded(), width: searchWidth, height: height)
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            box.layer?.borderColor = (hasError ? NSColor.systemRed : NSColor.separatorColor).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Segment buttons handle their own clicks; anything else in the bar starts editing.
        onClickEmptyArea?()
    }
}

/// The suggestion list under the address field: a borderless child window that never takes
/// key status (typing stays in the field), with a plain table of folder names.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [PathCompletion] = []
    var onPick: ((PathCompletion) -> Void)?
    private var panel: NonKeyPanel?
    private let table = NSTableView()
    private(set) var isTracking = false
    private static let rowHeight: CGFloat = 22

    var isVisible: Bool { panel?.isVisible == true }
    var selected: PathCompletion? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }

    func show(_ items: [PathCompletion], below anchor: NSView, width: CGFloat) {
        self.items = items
        guard let window = anchor.window else { return }
        let panel = self.panel ?? makePanel()
        table.reloadData()
        table.deselectAll(nil)
        let rows = CGFloat(min(items.count, 10))
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let height = rows * Self.rowHeight + 8
        panel.setFrame(NSRect(x: anchorRect.minX, y: anchorRect.minY - height - 2, width: max(width, 260), height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        table.scrollRowToVisible(0)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = max(0, min(items.count - 1, (table.selectedRow < 0 ? (delta > 0 ? -1 : items.count) : table.selectedRow) + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func makePanel() -> NonKeyPanel {
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Suggestions")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
        scroll.frame = background.bounds.safelyInset(dx: 0, dy: 4)
        background.addSubview(scroll)
        column.width = 2000
        self.panel = panel
        return panel
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        onPick?(items[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCellView.nameIdentifier, owner: nil) as? FileCellView
            ?? FileCellView(identifier: FileCellView.nameIdentifier, style: .name)
        cell.zooms = false // the suggestions keep their size (22 pt rows) whatever the list's zoom
        cell.text = items[row].name
        cell.icon = IconCache.shared.icon(for: FileItem(name: items[row].name, kind: .directory))
        return cell
    }
}

/// A panel that never becomes key, so the address field keeps the keyboard.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSRect {
    /// `insetBy` returns `CGRect.null` (origin at infinity) when the rect is smaller than the
    /// inset — e.g. before first layout — and frames built from it produce out-of-range
    /// autoresizing constraints. This clamps to an empty rect instead.
    func safelyInset(dx: CGFloat, dy: CGFloat) -> NSRect {
        NSRect(x: minX + dx, y: minY + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }
}
