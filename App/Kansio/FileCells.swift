import AppKit

/// Cells are built with frames + autoresizing masks (no Auto Layout) and reused by
/// NSTableView via `makeView(withIdentifier:)`. Configuring one only sets an image
/// and a string: no file system access, no layout passes.
@MainActor
final class NameCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NameCell")

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: FileListViewController.rowHeight))
        identifier = Self.identifier
        // One layer per cell instead of one per subview: far fewer backing stores to allocate and composite.
        wantsLayer = true
        canDrawSubviewsIntoLayer = true

        let icon = NSImageView(frame: NSRect(x: 3, y: (bounds.height - 16) / 2, width: 16, height: 16))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.autoresizingMask = [.minYMargin, .maxYMargin]
        addSubview(icon)
        imageView = icon

        let label = Self.makeLabel(frame: NSRect(x: 24, y: (bounds.height - 17) / 2, width: bounds.width - 26, height: 17))
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func makeLabel(frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.frame = frame
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.cell?.usesSingleLineMode = true
        return label
    }
}

@MainActor
final class TextCellView: NSTableCellView {
    static let dateIdentifier = NSUserInterfaceItemIdentifier("DateCell")
    static let sizeIdentifier = NSUserInterfaceItemIdentifier("SizeCell")
    static let kindIdentifier = NSUserInterfaceItemIdentifier("KindCell")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: FileListViewController.rowHeight))
        self.identifier = identifier
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        let label = NameCellView.makeLabel(frame: NSRect(x: 2, y: (bounds.height - 17) / 2, width: bounds.width - 4, height: 17))
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        label.alignment = alignment
        label.textColor = .secondaryLabelColor
        label.font = identifier == Self.kindIdentifier
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Formatters are expensive to create; make each once. They are only ever called for
/// visible cells.
@MainActor
enum Formatters {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f
    }()

    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return f
    }()

    static let count: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}
