import AppKit
import FileSystemKit

/// The tab strip in the title-bar row (Explorer / Chrome layout, chosen 2026-11-16): one tab per
/// folder, "+" after the last, then ⌄ (the most used folders; one opens in a new tab). Top-down the window reads "which tab → where in it": the row below
/// (Back/Forward/Up, path, search) belongs to the selected tab.
///
/// Click selects; ✕ or a middle-click closes; drag a tab sideways to reorder; right-click for
/// Close Tab / Close Other Tabs / Move Tab to New Window. Files dragged over a tab switch to it
/// after a moment, and can be dropped on it (into that tab's folder). Empty space drags the window.
@MainActor
final class TabStripView: NSView {
    struct Tab: Equatable {
        var title: String
        var path: String
        var isSelected: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onMoveToNewWindow: ((Int) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// The ⌄ button: show the most used folders menu under it.
    var onMostUsed: ((NSButton) -> Void)?
    /// A drop on tab `index` (files dragged onto it).
    var dropTarget: ((Int) -> FileListViewController?)?

    private(set) var tabs: [Tab] = []
    private var items: [TabItemView] = []
    private let plusButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!, target: nil, action: nil)
    let mostUsedButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Most Used Folders")!,
                                  target: nil, action: nil)
    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true // nothing drawn outside the title row
        plusButton.bezelStyle = .accessoryBarAction
        plusButton.isBordered = false
        plusButton.target = self
        plusButton.action = #selector(plusClicked(_:))
        plusButton.toolTip = "New Tab (⌘T)"
        addSubview(plusButton)
        mostUsedButton.bezelStyle = .accessoryBarAction
        mostUsedButton.isBordered = false
        mostUsedButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        mostUsedButton.target = self
        mostUsedButton.action = #selector(mostUsedClicked(_:))
        mostUsedButton.toolTip = "Most Used Folders"
        mostUsedButton.setAccessibilityLabel("Most Used Folders")
        addSubview(mostUsedButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ tabs: [Tab]) {
        guard tabs != self.tabs else { return }
        self.tabs = tabs
        while items.count < tabs.count {
            let item = TabItemView(strip: self)
            items.append(item)
            addSubview(item, positioned: .below, relativeTo: plusButton)
        }
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            items[i].configure(tab, index: i)
            items[i].showsSeparator = !tab.isSelected && i + 1 < tabs.count && !tabs[i + 1].isSelected
        }
        needsLayout = true
    }

    /// Tab widths: share the row, between 90 and 220 points.
    override func layout() {
        super.layout()
        let plusWidth: CGFloat = 28, moreWidth: CGFloat = 18
        let available = max(0, bounds.width - plusWidth - moreWidth - 6)
        let width = tabs.isEmpty ? 0 : min(220, max(90, (available / CGFloat(tabs.count)).rounded(.down)))
        let height = min(Self.height, bounds.height)
        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + 1
        }
        let plusX = min(x + 2, max(0, bounds.width - plusWidth - moreWidth))
        plusButton.frame = NSRect(x: plusX, y: (height - 24) / 2, width: plusWidth, height: 24)
        mostUsedButton.frame = NSRect(x: plusX + plusWidth, y: (height - 24) / 2, width: moreWidth, height: 24)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The tab frames, for reordering by drag.
    fileprivate func index(at x: CGFloat) -> Int {
        guard let width = items.first?.frame.width, width > 0 else { return 0 }
        return min(max(Int(x / (width + 1)), 0), items.count - 1)
    }

    fileprivate func itemDragged(_ item: TabItemView, toX x: CGFloat) {
        guard let from = items.firstIndex(of: item) else { return }
        let to = index(at: x)
        guard to != from else { return }
        onMove?(from, to)
    }

    @objc private func plusClicked(_ sender: Any?) { onNewTab?() }
    @objc private func mostUsedClicked(_ sender: Any?) { onMostUsed?(mostUsedButton) }

    /// Self-test: the tab views.
    var itemViews: [NSView] { items }
}

/// One tab: folder icon, name, ✕ (on hover and for the selected tab).
@MainActor
private final class TabItemView: NSView {
    private unowned let strip: TabStripView
    private var tab = TabStripView.Tab(title: "", path: "", isSelected: false)
    private var index = 0
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; updateClose() } } }
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!, target: nil, action: nil)
    private var dragStartX: CGFloat?
    /// A thin line at the right edge (between two unselected tabs, as in Explorer).
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    private var springTimer: Timer?
    private static let icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        clipsToBounds = true
        close.bezelStyle = .accessoryBarAction
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.target = self
        close.action = #selector(closeClicked(_:))
        close.toolTip = "Close Tab (⌘W)"
        addSubview(close)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        registerForDraggedTypes(FileDrop.draggedTypes)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ tab: TabStripView.Tab, index: Int) {
        self.index = index
        guard tab != self.tab else { return }
        self.tab = tab
        toolTip = tab.path
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(tab.isSelected ? 1 : 0)
        updateClose()
        needsDisplay = true
    }

    private func updateClose() { close.isHidden = !(tab.isSelected || hovering) }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: bounds.width - 24, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // A rounded tab, open at the bottom (it continues into the row below). Label-colour fills read the same
        // in light and dark mode: the selected tab stands out, hovering hints.
        // A pill entirely inside the tab's bounds, centred in the title row like the traffic lights (the toolbar
        // centres the strip vertically, so a shape reaching for the row's edge can't line up with it — and since
        // macOS 14 views don't clip, anything drawn outside would show). Label-colour fills work in light and dark.
        let shape = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: max(0, bounds.width - 4), height: max(0, bounds.height - 4)),
                                 xRadius: 7, yRadius: 7)
        if tab.isSelected {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            shape.fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            shape.fill()
        } else if showsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.width - 1, y: (bounds.height - 16) / 2, width: 1, height: 16).fill()
        }
        let iconRect = NSRect(x: 11, y: ((bounds.height - 14) / 2).rounded(), width: 16, height: 14)
        if let icon = Self.icon {
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                NSColor.systemBlue.withAlphaComponent(self.tab.isSelected ? 1 : 0.7).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: tab.isSelected ? .medium : .regular)
        let color: NSColor = tab.isSelected ? .labelColor : .secondaryLabelColor
        // Vertically centred on the font's line height (not a fixed 16 pt).
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textRect = NSRect(x: 33, y: ((bounds.height - lineHeight) / 2).rounded(), width: max(0, bounds.width - 33 - 28), height: lineHeight)
        (tab.title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartX = convert(event.locationInWindow, from: nil).x
        strip.onSelect?(index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartX != nil else { return }
        strip.itemDragged(self, toX: strip.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragStartX = nil }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { strip.onClose?(index) } // middle-click closes (Explorer, browsers)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            menuItem.target = self
        }
        item("Close Tab", #selector(closeClicked(_:)))
        if strip.tabs.count > 1 {
            item("Close Other Tabs", #selector(closeOthers(_:)))
            menu.addItem(.separator())
            item("Move Tab to New Window", #selector(moveToNewWindow(_:)))
        }
        return menu
    }

    @objc private func closeClicked(_ sender: Any?) { strip.onClose?(index) }
    @objc private func closeOthers(_ sender: Any?) { strip.onCloseOthers?(index) }
    @objc private func moveToNewWindow(_ sender: Any?) { strip.onMoveToNewWindow?(index) }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool {
        strip.onSelect?(index)
        return true
    }

    // MARK: Files dragged onto a tab: switch to it after a moment; drop = into its folder

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        springTimer?.invalidate()
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.strip.onSelect?(self.index) } }
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let list = strip.dropTarget?(index) else { return [] }
        return FileDrop.operation(for: sender, destination: list.folder, volumes: list.mountedVolumes)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        springTimer?.invalidate()
        springTimer = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        springTimer?.invalidate()
        guard let list = strip.dropTarget?(index) else { return false }
        let operation = FileDrop.operation(for: sender, destination: list.folder, volumes: list.mountedVolumes)
        return !operation.isEmpty && FileDrop.perform(sender, destination: list.folder, operation: operation, list: list)
    }
}

/// Hosts the tabs' list views; only the selected one is shown (switching = hide one, show another).
@MainActor
final class TabContainerViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func show(_ list: FileListViewController, hiding others: [FileListViewController]) {
        if list.parent !== self {
            addChild(list)
            list.view.frame = view.bounds
            list.view.autoresizingMask = [.width, .height]
            view.addSubview(list.view)
        }
        for other in others where other !== list { other.view.isHidden = true }
        list.view.isHidden = false
    }

    func remove(_ list: FileListViewController) {
        list.view.removeFromSuperview()
        list.removeFromParent()
    }
}
