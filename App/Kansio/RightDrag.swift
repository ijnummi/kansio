import AppKit
import FileSystemKit

/// Dragging with the right mouse button (P3-2, Explorer): on release over a folder a menu asks what to do —
/// **Copy Here / Move Here / Create Alias Here / Cancel** — with what a left drag would do in bold.
///
/// macOS has no right-button drag and drop (AppKit's dragging sessions are left-button), so Kansio tracks this one
/// itself: a right-button press on a list row or tree folder that moves more than a few points starts it; a release
/// without moving shows the context menu as before (on release, like Explorer). While dragging, the folder under the
/// pointer — a folder row or the list's background in any Kansio window, a folder in the navigation pane, a tab — is
/// outlined. Other apps aren't drop targets (they can't show the menu); Esc cancels. Copy and Move run through the
/// copy engine like any drop (progress, conflicts, undo); aliases are made by `Aliases.make` (undo trashes them).
@MainActor
enum RightDrag {
    /// A folder the pointer is over.
    struct Target {
        let destination: URL
        /// The list that runs the operation (its window gets the sheets and the messages).
        let list: FileListViewController
        /// The outline drawn around it, in screen coordinates.
        let frame: NSRect
    }

    /// The dragged items, with the paths the checks need computed once (validation runs on every mouse move).
    struct Sources {
        let urls: [URL]
        let paths: [String]
        let parents: Set<String>
        /// False for a tree root (Home, a volume): those can be copied or aliased, never moved.
        let canMove: Bool

        init(_ urls: [URL], canMove: Bool = true) {
            self.urls = urls
            paths = urls.map { FileDrop.normalized($0.path(percentEncoded: false)) }
            parents = Set(paths.map { FileDrop.normalized(($0 as NSString).deletingLastPathComponent) })
            self.canMove = canMove
        }
    }

    /// The choice from the menu.
    enum Choice: Equatable { case copy, move, alias }

    /// How far the pointer moves (points) before a right-button press becomes a drag.
    static let threshold: CGFloat = 4

    /// After a right-button press: the first drag event past the threshold, or nil when the button came up first
    /// (then it was a click: show the context menu).
    static func waitForDrag(in window: NSWindow, from down: NSEvent) -> NSEvent? {
        let start = down.locationInWindow
        while let event = window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp]) {
            if event.type == .rightMouseUp { return nil }
            let p = event.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > threshold { return event }
        }
        return nil
    }

    /// Self-test: called instead of showing the drop menu (the menu, the screen point).
    static var presentMenu: ((NSMenu, NSPoint) -> Void)?
    /// The last drag's outcome (self-test): the target it ended on and the choices offered.
    private(set) static var lastTarget: Target?
    private(set) static var lastMenuTitles: [String] = []

    /// Tracks the drag from `start` until the right button comes up (→ the menu) or Esc (→ nothing).
    static func run(_ sources: Sources, image: NSImage, in window: NSWindow, from start: NSEvent) {
        guard !sources.urls.isEmpty else { return }
        let imageWindow = OverlayWindow(content: NSImageView(image: image), alpha: 0.85)
        let highlight = OverlayWindow(content: HighlightView(), alpha: 1)
        imageWindow.setContentSize(image.size)
        defer {
            imageWindow.orderOut(nil)
            highlight.orderOut(nil)
        }
        var target: Target?
        var screenPoint = NSPoint.zero
        func update(_ event: NSEvent) {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            imageWindow.setFrameOrigin(NSPoint(x: screenPoint.x + 12, y: screenPoint.y - image.size.height - 8))
            imageWindow.orderFront(nil)
            target = Self.target(at: screenPoint, sources: sources, ignoring: [imageWindow.windowNumber, highlight.windowNumber])
            if let target {
                highlight.setFrame(target.frame, display: true)
                highlight.orderFront(nil)
            } else {
                highlight.orderOut(nil)
            }
            // Near the list's top or bottom edge in this window: scroll it.
            if let list = (window.windowController as? MainWindowController)?.fileList {
                let table = list.tableForTesting
                if let clip = table.enclosingScrollView?.contentView, !clip.isHiddenOrHasHiddenAncestor {
                    let p = clip.convert(event.locationInWindow, from: nil)
                    // Just inside or outside the top or bottom edge, within the list's width.
                    if p.x >= clip.bounds.minX, p.x <= clip.bounds.maxX,
                       p.y < clip.bounds.minY + 12 || p.y > clip.bounds.maxY - 12 {
                        table.autoscroll(with: event)
                    }
                }
            }
        }
        update(start)
        while let event = window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp, .keyDown]) {
            switch event.type {
            case .rightMouseDragged:
                update(event)
            case .rightMouseUp:
                update(event)
                imageWindow.orderOut(nil)
                highlight.orderOut(nil)
                lastTarget = target
                if let target { showMenu(for: sources, on: target, at: screenPoint) }
                return
            case .keyDown where event.keyCode == 53: // Esc
                lastTarget = nil
                return
            default:
                break
            }
        }
    }

    /// The Kansio window under `point` (screen), skipping the drag's own overlay windows.
    static func target(at point: NSPoint, sources: Sources, ignoring overlays: Set<Int>) -> Target? {
        var below = 0
        for _ in 0..<8 {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard number > 0 else { return nil }
            if overlays.contains(number) { below = number; continue }
            guard let controller = NSApp.window(withWindowNumber: number)?.windowController as? MainWindowController else { return nil }
            return controller.rightDropTarget(atScreen: point, sources: sources)
        }
        return nil
    }

    /// What dropping `sources` on `destination` allows. Copy and move: never into an item itself or a folder inside
    /// it; moving into the folder the items are already in does nothing. An alias can go anywhere.
    static func choices(_ sources: Sources, into destination: URL, volumes: [Volume]) -> (copy: Bool, move: Bool, preferred: Choice) {
        let check = FileDrop.dropChecks(paths: sources.paths, parents: sources.parents, destination: destination, volumes: volumes)
        let move = sources.canMove && check.move
        return (check.copy, move, move && check.sameVolume ? .move : .copy)
    }

    // MARK: The menu

    private static var handler: MenuHandler?

    static func menu(for sources: Sources, on target: Target) -> NSMenu {
        let choice = choices(sources, into: target.destination, volumes: target.list.mountedVolumes)
        let handler = MenuHandler(sources: sources.urls, target: target)
        Self.handler = handler
        let menu = NSMenu(title: "Drop")
        menu.autoenablesItems = false
        func add(_ title: String, _ kind: Choice?, enabled: Bool) {
            let item = menu.addItem(withTitle: title, action: #selector(MenuHandler.choose(_:)), keyEquivalent: "")
            item.target = handler
            item.isEnabled = enabled
            item.representedObject = kind.map { "\($0)" }
            if kind == choice.preferred, enabled {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
            }
        }
        add("Copy Here", .copy, enabled: choice.copy)
        add("Move Here", .move, enabled: choice.move)
        add("Create Alias Here", .alias, enabled: true)
        menu.addItem(.separator())
        add("Cancel", nil, enabled: true)
        return menu
    }

    private static func showMenu(for sources: Sources, on target: Target, at screenPoint: NSPoint) {
        let menu = menu(for: sources, on: target)
        lastMenuTitles = menu.items.filter { !$0.isSeparatorItem }.map { $0.isEnabled ? $0.title : "(\($0.title))" }
        if let presentMenu { presentMenu(menu, screenPoint); return }
        let view = target.list.view
        guard let window = view.window else { return }
        menu.popUp(positioning: nil, at: view.convert(window.convertPoint(fromScreen: screenPoint), from: nil), in: view)
    }

    /// Carries out a choice (the menu's items; the self-test calls it directly too).
    static func perform(_ choice: Choice, sources: [URL], on target: Target) {
        switch choice {
        case .copy: target.list.runCopyEngine(.copy, sources: sources, into: target.destination, actionName: "Copy")
        case .move: target.list.runCopyEngine(.move, sources: sources, into: target.destination, actionName: "Move")
        case .alias: target.list.createAliases(to: sources, in: target.destination)
        }
    }

    @MainActor
    private final class MenuHandler: NSObject {
        let sources: [URL]
        let target: Target
        init(sources: [URL], target: Target) { self.sources = sources; self.target = target }

        @objc func choose(_ sender: NSMenuItem) {
            defer { RightDrag.handler = nil }
            let choice: Choice? = switch sender.representedObject as? String {
            case "copy": .copy
            case "move": .move
            case "alias": .alias
            default: nil
            }
            if let choice { RightDrag.perform(choice, sources: sources, on: target) }
        }
    }

    // MARK: Drawing

    /// The dragged items' image: a snapshot of `rect` in `view` (the grabbed row), with a count badge for several.
    static func image(of view: NSView, rect: NSRect, count: Int) -> NSImage {
        let rect = rect.intersection(view.visibleRect)
        let snapshot = rect.isEmpty ? nil : view.bitmapImageRepForCachingDisplay(in: rect)
        if let snapshot { view.cacheDisplay(in: rect, to: snapshot) }
        let size = NSSize(width: max(60, rect.width), height: max(20, rect.height))
        return NSImage(size: size, flipped: false) { bounds in
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            snapshot?.draw(in: bounds)
            if count > 1 {
                let text = "\(count)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
                let textSize = text.size(withAttributes: attributes)
                let badge = NSRect(x: bounds.maxX - textSize.width - 14, y: bounds.maxY - 16, width: textSize.width + 12, height: 16)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + (16 - textSize.height) / 2), withAttributes: attributes)
            }
            return true
        }
    }
}

/// A borderless window that never takes the mouse or focus (the drag image, the target outline).
@MainActor
private final class OverlayWindow: NSPanel {
    init(content: NSView, alpha: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        alphaValue = alpha
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        content.autoresizingMask = [.width, .height]
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The outline around the folder under the pointer.
@MainActor
private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        shape.fill()
        NSColor.controlAccentColor.setStroke()
        shape.lineWidth = 2
        shape.stroke()
    }
}

// MARK: Sources and targets in the window

extension MainWindowController {
    /// The folder under `point` (screen) in this window: a tab, a folder row or the list's background, a folder in
    /// the navigation pane. Nil over anything else (and over the Trash).
    func rightDropTarget(atScreen screenPoint: NSPoint, sources: RightDrag.Sources) -> RightDrag.Target? {
        guard let window, window.isVisible else { return nil }
        let point = window.convertPoint(fromScreen: screenPoint)
        let list = fileList
        func screen(_ rect: NSRect, in view: NSView) -> NSRect { window.convertToScreen(view.convert(rect, to: nil)) }
        // Tabs.
        for (i, item) in tabStrip.itemViews.enumerated() where item.window != nil && i < tabs.count {
            guard item.bounds.contains(item.convert(point, from: nil)) else { continue }
            guard !tabs[i].isShowingTrash else { return nil }
            return RightDrag.Target(destination: tabs[i].folder, list: list, frame: screen(item.bounds.insetBy(dx: 2, dy: 2), in: item))
        }
        // The list: a folder row, else the folder shown.
        let table = list.tableForTesting
        if let scroll = table.enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor,
           scroll.bounds.contains(scroll.convert(point, from: nil)) {
            guard !list.isShowingTrash else { return nil }
            let row = table.row(at: table.convert(point, from: nil))
            if let folder = list.folderURL(atRow: row), !sources.paths.contains(FileDrop.normalized(folder.path(percentEncoded: false))) {
                return RightDrag.Target(destination: folder, list: list, frame: screen(table.rect(ofRow: row).intersection(table.visibleRect), in: table))
            }
            return RightDrag.Target(destination: list.folder, list: list, frame: screen(scroll.bounds, in: scroll))
        }
        // The navigation pane.
        let outline = sidebar.outlineView
        if !outline.isHiddenOrHasHiddenAncestor, outline.visibleRect.contains(outline.convert(point, from: nil)) {
            let row = outline.row(at: outline.convert(point, from: nil))
            guard let folder = sidebar.dropFolder(atRow: row) else { return nil }
            return RightDrag.Target(destination: folder, list: list, frame: screen(outline.rect(ofRow: row).intersection(outline.visibleRect), in: outline))
        }
        return nil
    }
}

extension SidebarViewController {
    /// A folder in the navigation pane that takes dropped items (not the Trash, not a missing favorite).
    func dropFolder(atRow row: Int) -> URL? {
        guard row >= 0, !(outlineView.item(atRow: row) is SidebarTrashItem) else { return nil }
        return folderURL(atRow: row)
    }

    /// A right-button drag from the tree: the folder (Home and volumes can be copied or aliased, not moved).
    func beginRightDrag(down: NSEvent, drag: NSEvent) {
        let row = outlineView.row(at: outlineView.convert(down.locationInWindow, from: nil))
        guard let node = outlineView.item(atRow: row) as? TreeNode, let window = view.window else { return }
        let image = RightDrag.image(of: outlineView, rect: outlineView.rect(ofRow: row), count: 1)
        RightDrag.run(RightDrag.Sources([node.url], canMove: node.parent != nil), image: image, in: window, from: drag)
    }
}

extension FileListViewController {
    /// A right-button drag from the list: the clicked row (selected first if it wasn't) and the rest of the selection.
    func beginRightDrag(down: NSEvent, drag: NSEvent) {
        let table = tableForTesting
        let row = table.row(at: table.convert(down.locationInWindow, from: nil))
        guard row >= 0, let window = view.window else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let urls = selectedItems.map(url(of:))
        let rect = table.rect(ofRow: row)
        let image = RightDrag.image(of: table, rect: NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, 300), height: rect.height), count: urls.count)
        RightDrag.run(RightDrag.Sources(urls), image: image, in: window, from: drag)
    }

    /// Create Alias Here: Finder aliases in `destination`, undoable (undo moves them to the Trash).
    func createAliases(to originals: [URL], in destination: URL) {
        Task { [weak self] in
            let outcome = await Aliases.make(to: originals, in: destination)
            guard let self else { return }
            let made = outcome.made.map(\.alias)
            if !made.isEmpty {
                FileUndo.shared.register(UndoStep(made.count == 1 ? "Create Alias" : "Create Aliases", made.map { .created($0, slot: TrashSlot()) }),
                                         trasher: self.trasher)
                self.announce(made)
            }
            let here = Self.standardized(self.folder)
            var added: [FileItem] = []
            for url in made where Self.standardized(url.deletingLastPathComponent()) == here {
                if let item = await Self.readItem(url) { added.append(item) }
            }
            if !added.isEmpty { self.applyLocalChange(adding: added, select: added.map(\.name)) }
            if let failure = outcome.failed.first {
                self.showMessage("Couldn’t make an alias of “\(failure.url.lastPathComponent)”. \(failure.error.description)")
            }
        }
    }
}
