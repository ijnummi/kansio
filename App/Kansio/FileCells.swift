import AppKit

/// One cell = one view that draws its own icon and text.
///
/// The first version used an `NSImageView` + `NSTextField` per cell. Creating those is what
/// made the first navigation into a full folder cost an extra ~8 ms (16 new row views × 4
/// cells × 2–3 views each, plus text-field machinery). A drawing cell is ~3× fewer views,
/// no Auto Layout, no field editor, and setting a value is just a string + `needsDisplay`.
///
/// Accessibility: the cell exposes itself as static text with the displayed value (VoiceOver
/// reads it like a label). Selection colours follow `backgroundStyle` like standard cells.
@MainActor
final class FileCellView: NSTableCellView {
    enum Style { case name, secondary, digits }

    static let nameIdentifier = NSUserInterfaceItemIdentifier("NameCell")
    static let dateIdentifier = NSUserInterfaceItemIdentifier("DateCell")
    static let sizeIdentifier = NSUserInterfaceItemIdentifier("SizeCell")
    static let kindIdentifier = NSUserInterfaceItemIdentifier("KindCell")

    private let style: Style
    private let alignment: NSTextAlignment

    var text: String = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    var iconAlpha: CGFloat = 1 {
        didSet { if iconAlpha != oldValue { needsDisplay = true } }
    }

    init(identifier: NSUserInterfaceItemIdentifier, style: Style, alignment: NSTextAlignment = .left) {
        self.style = style
        self.alignment = alignment
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: FileListViewController.rowHeight))
        self.identifier = identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    // MARK: Drawing

    private static let iconSize: CGFloat = 16
    private static let textInset: CGFloat = 24 // name column: after the icon

    private static func attributes(style: Style, alignment: NSTextAlignment, emphasized: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let font: NSFont = style == .digits
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor : (style == .name ? .labelColor : .secondaryLabelColor)
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = backgroundStyle == .emphasized
        var textRect = bounds.insetBy(dx: 2, dy: 0)
        if style == .name {
            if let icon {
                let y = (bounds.height - Self.iconSize) / 2
                icon.draw(in: NSRect(x: 3, y: y, width: Self.iconSize, height: Self.iconSize),
                          from: .zero, operation: .sourceOver, fraction: iconAlpha, respectFlipped: true, hints: nil)
            }
            textRect.origin.x = Self.textInset
            textRect.size.width = bounds.width - Self.textInset - 2
        }
        guard !text.isEmpty, textRect.width > 4 else { return }
        let attrs = Self.attributes(style: style, alignment: alignment, emphasized: emphasized)
        let font = attrs[.font] as! NSFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        textRect.origin.y = floor((bounds.height - lineHeight) / 2)
        textRect.size.height = lineHeight
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityLabel() -> String? { text }
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
