import AppKit
import FileSystemKit

/// Get Info (⌘I): Kansio's own small info window (Explorer's Properties), instead of asking
/// Finder via Apple Events — that would need the Automation permission and bring Finder forward.
///
/// One item: icon, name, kind, size, where, created, modified, permissions, and the target of a
/// link / the original of an alias. Several items: a combined count and total size. Folder sizes
/// are counted off-main (`ItemStatistics`: symlinks never followed, hard links once) while the
/// window shows progress; closing the window cancels the count.
@MainActor
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [InfoWindowController] = []

    let urls: [URL]
    private let items: [FileItem]
    private let cancel = CancellationFlag()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var values: [String: NSTextField] = [:]
    private var factsShown = false, sizeDone = false
    /// Both the facts and the size are in (self-test).
    var isFinished: Bool { factsShown && sizeDone }

    /// Opens an info window for `items` in `folder` (or for the folder itself when `items` is empty).
    @discardableResult
    static func show(items: [FileItem], in folder: URL) -> InfoWindowController {
        let urls = items.isEmpty ? [folder] : items.map { folder.appending(path: $0.name, directoryHint: $0.kind == .directory ? .isDirectory : .notDirectory) }
        let controller = InfoWindowController(urls: urls, items: items)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.load()
        return controller
    }

    /// The value shown for a row ("Size", "Kind", …) — self-test.
    func value(_ row: String) -> String { values[row]?.stringValue ?? "" }
    var titleText: String { titleLabel.stringValue }
    func isShowing(_ row: String) -> Bool {
        guard let value = values[row], let row = value.enclosingGridView?.cell(for: value)?.row else { return false }
        return !row.isHidden
    }
    var isCountCancelled: Bool { cancel.isCancelled }
    /// The window's content as PNG (self-test visual check, no Screen Recording permission needed).
    func writePNG(to url: URL) {
        guard let window, let content = window.contentView else { return }
        try? WindowSnapshot.renderPlain(content, to: url)
    }

    private init(urls: [URL], items: [FileItem]) {
        self.urls = urls
        self.items = items
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = urls.count == 1 ? "“\(urls[0].lastPathComponent)” Info" : "\(urls.count) Items Info"
        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI(in panel: NSPanel) {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isSelectable = true
        let header = NSStackView(views: [iconView, titleLabel])
        header.spacing = 12
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 48), iconView.heightAnchor.constraint(equalToConstant: 48)])

        let rowNames = urls.count == 1 ? ["Kind", "Size", "Where", "Created", "Modified", "Permissions", "Link to"] : ["Contains", "Size", "Where"]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        for name in rowNames {
            let key = NSTextField(labelWithString: name + ":")
            key.textColor = .secondaryLabelColor
            key.alignment = .right
            // Paths stay on one line (middle-truncated, full path in the tooltip); sizes and link targets wrap.
            let wraps = name == "Size" || name == "Link to"
            let value = wraps ? NSTextField(wrappingLabelWithString: "…") : NSTextField(labelWithString: "…")
            value.isSelectable = true
            if wraps { value.preferredMaxLayoutWidth = 250 } else { value.lineBreakMode = .byTruncatingMiddle }
            value.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
            value.setAccessibilityLabel(name)
            values[name] = value
            grid.addRow(with: [key, value])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 380),
        ])
        panel.contentView = content
        if urls.count == 1 { grid.row(at: rowNames.firstIndex(of: "Link to")!).isHidden = true }
    }

    // MARK: Loading (all off the main thread)

    private struct Facts: Sendable {
        var item: FileItem?
        var created: Date?
        var modified: Date?
        var permissions: String?
        var linkTarget: String?
        var icon: SendableReps?
    }

    private func load() {
        let urls = self.urls
        titleLabel.stringValue = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        var location = urls[0].deletingLastPathComponent().path(percentEncoded: false)
        if location.count > 1, location.hasSuffix("/") { location.removeLast() }
        values["Where"]?.stringValue = location
        values["Where"]?.toolTip = location
        Task { [weak self] in
            let facts = await Task.detached { urls.count == 1 ? Self.facts(for: urls[0]) : Facts() }.value
            self?.show(facts)
        }
        let cancel = self.cancel
        let reporter: @Sendable (ItemStatistics.Totals) -> Void = { [weak self] totals in
            Task { @MainActor in self?.showSize(totals, done: false) }
        }
        Task { [weak self] in
            let totals = await ItemStatistics.measure(urls, cancel: cancel, progress: reporter)
            guard !cancel.isCancelled else { return }
            self?.showSize(totals, done: true)
        }
    }

    nonisolated private static func facts(for url: URL) -> Facts {
        var facts = Facts()
        facts.item = try? BulkDirectoryLister.readItem(at: url)
        let path = url.path(percentEncoded: false)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            facts.created = attributes[.creationDate] as? Date
            facts.modified = attributes[.modificationDate] as? Date
            if let mode = attributes[.posixPermissions] as? Int {
                let owner = attributes[.ownerAccountName] as? String ?? "?"
                let group = attributes[.groupOwnerAccountName] as? String ?? "?"
                facts.permissions = "\(Self.modeString(mode)) · \(owner) / \(group)"
            }
        }
        if facts.item?.kind == .symlink {
            facts.linkTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { "\($0)" }
        } else if facts.item?.flags.contains(.alias) == true {
            facts.linkTarget = Aliases.resolveBlocking(url)?.path(percentEncoded: false) ?? "Original can’t be found"
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        facts.icon = SendableReps(reps: [48, 96].compactMap { size in
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            rep.size = NSSize(width: 48, height: 48)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        })
        return facts
    }

    nonisolated private static func modeString(_ mode: Int) -> String {
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }

    private func show(_ facts: Facts) {
        defer { factsShown = true; fitWindow() }
        if let reps = facts.icon {
            let image = NSImage(size: NSSize(width: 48, height: 48))
            reps.reps.forEach { image.addRepresentation($0) }
            iconView.image = image
        } else {
            iconView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
        guard urls.count == 1 else { return }
        let date: (Date?) -> String = { $0.map { DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short) } ?? "—" }
        values["Kind"]?.stringValue = facts.item.map(FileKind.description(for:)) ?? "—"
        values["Created"]?.stringValue = date(facts.created)
        values["Modified"]?.stringValue = date(facts.modified)
        values["Permissions"]?.stringValue = facts.permissions ?? "—"
        if let target = facts.linkTarget, let row = values["Link to"], let grid = row.enclosingGridView {
            row.stringValue = target
            grid.cell(for: row)?.row?.isHidden = false
        }
    }

    private func showSize(_ totals: ItemStatistics.Totals, done: Bool) {
        let bytes = Formatters.size.string(fromByteCount: totals.bytes)
        let exact = Formatters.count.string(from: NSNumber(value: totals.bytes)) ?? "\(totals.bytes)"
        var text = bytes == "\(exact) bytes" ? bytes : "\(bytes) (\(exact) bytes)"
        if !(urls.count == 1 && totals.folders == 0) { // a folder or several items: say how many files
            let files = Formatters.count.string(from: NSNumber(value: totals.files)) ?? "\(totals.files)"
            text += " for \(files) \(totals.files == 1 ? "file" : "files")"
        }
        if !done { text = "Calculating… " + text }
        if totals.unreadable > 0 { text += " — some folders couldn’t be read" }
        values["Size"]?.stringValue = text
        if urls.count > 1 {
            let folders = items.filter { $0.kind == .directory }.count
            let files = urls.count - folders
            values["Contains"]?.stringValue = "\(files) \(files == 1 ? "file" : "files"), \(folders) \(folders == 1 ? "folder" : "folders")"
        }
        if done { sizeDone = true }
        fitWindow()
    }

    /// Grows/shrinks the window to its content (texts change length), keeping the top edge put.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height != content.frame.height else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        cancel.cancel() // stop counting
        Self.open.removeAll { $0 === self }
    }
}

private extension NSView {
    var enclosingGridView: NSGridView? {
        var view: NSView? = superview
        while let v = view { if let grid = v as? NSGridView { return grid }; view = v.superview }
        return nil
    }
}
