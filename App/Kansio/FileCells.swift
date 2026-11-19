import AppKit

/// The file list's zoom (P3 → done 2026-11-18): text size and row density from `ViewSettings`; row height, icon size
/// and fonts follow. Computed once per change (cells read it on every draw).
@MainActor
struct ListMetrics {
    let textSize: Int
    let density: ViewSettings.Density
    let rowHeight: CGFloat
    let iconSize: CGFloat
    /// Name column: where the text starts (after the icon).
    let textInset: CGFloat
    let lineHeight: CGFloat
    let nameFont: NSFont
    /// [style][emphasized]
    fileprivate let attributes: [FileCellView.Style: [Bool: [NSAttributedString.Key: Any]]]

    init(textSize: Int, density: ViewSettings.Density) {
        self.textSize = textSize
        self.density = density
        let size = CGFloat(textSize)
        nameFont = .systemFont(ofSize: size)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        lineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        // Icons: 16 pt up to 14 pt text, then 20 and 24 (the type icons are rasterized up to 48 px).
        iconSize = textSize <= 14 ? 16 : textSize <= 16 ? 20 : 24
        rowHeight = max(lineHeight + CGFloat(density.padding), iconSize + (density == .compact ? 2 : 4)).rounded()
        textInset = 3 + iconSize + 5
        var attributes: [FileCellView.Style: [Bool: [NSAttributedString.Key: Any]]] = [:]
        for style in [FileCellView.Style.name, .secondary, .digits] {
            for emphasized in [false, true] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let color: NSColor = emphasized ? .alternateSelectedControlTextColor : (style == .name ? .labelColor : .secondaryLabelColor)
                attributes[style, default: [:]][emphasized] = [.font: style == .digits ? digits : nameFont,
                                                               .foregroundColor: color, .paragraphStyle: paragraph]
            }
        }
        self.attributes = attributes
    }

    /// 13 pt, standard rows (22 pt): what other tables using the cell (address-bar suggestions) always use.
    static let standard = ListMetrics(textSize: ViewSettings.defaultTextSize, density: .standard)
    private static var cached = standard

    /// The list's metrics for the current settings.
    static var current: ListMetrics {
        let settings = ViewSettings.shared
        if cached.textSize != settings.listTextSize || cached.density != settings.listDensity {
            cached = ListMetrics(textSize: settings.listTextSize, density: settings.listDensity)
        }
        return cached
    }

    func attributes(_ style: FileCellView.Style, alignment: NSTextAlignment, emphasized: Bool) -> [NSAttributedString.Key: Any] {
        var attrs = attributes[style]![emphasized]!
        if alignment != .left {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = alignment
            attrs[.paragraphStyle] = paragraph
        }
        return attrs
    }
}

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
    /// Follows the list's zoom (false: always the standard size, e.g. the address bar's suggestions).
    var zooms = true
    private var metrics: ListMetrics { zooms ? .current : .standard }

    var text: String = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    var iconAlpha: CGFloat = 1 {
        didSet { if iconAlpha != oldValue { needsDisplay = true } }
    }
    /// Secondary text after the name (a search result's location).
    var detail: String = "" {
        didSet { if detail != oldValue { needsDisplay = true } }
    }

    init(identifier: NSUserInterfaceItemIdentifier, style: Style, alignment: NSTextAlignment = .left) {
        self.style = style
        self.alignment = alignment
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ListMetrics.current.rowHeight))
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

    override func draw(_ dirtyRect: NSRect) {
        let metrics = self.metrics
        let emphasized = backgroundStyle == .emphasized
        var textRect = bounds.safelyInset(dx: 2, dy: 0)
        if style == .name {
            if let icon {
                let size = metrics.iconSize
                icon.draw(in: NSRect(x: 3, y: ((bounds.height - size) / 2).rounded(.down), width: size, height: size),
                          from: .zero, operation: .sourceOver, fraction: iconAlpha, respectFlipped: true, hints: nil)
            }
            textRect.origin.x = metrics.textInset
            textRect.size.width = bounds.width - metrics.textInset - 2
        }
        guard !text.isEmpty, textRect.width > 4 else { return }
        let attrs = metrics.attributes(style, alignment: alignment, emphasized: emphasized)
        let lineHeight = metrics.lineHeight
        textRect.origin.y = floor((bounds.height - lineHeight) / 2)
        textRect.size.height = lineHeight
        guard !detail.isEmpty else {
            (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            return
        }
        // "name  — in sub/dir": the name first (truncated only if it alone doesn't fit), the location after it.
        let nameWidth = min(ceil((text as NSString).size(withAttributes: attrs).width), textRect.width)
        var nameRect = textRect
        nameRect.size.width = nameWidth
        (text as NSString).draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        var detailRect = textRect
        detailRect.origin.x += nameWidth + 8
        detailRect.size.width = textRect.maxX - detailRect.minX
        guard detailRect.width > 12 else { return }
        var detailAttrs = attrs
        detailAttrs[.foregroundColor] = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : NSColor.secondaryLabelColor
        ("in " + detail as NSString).draw(with: detailRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: detailAttrs)
    }

    /// Where the cell draws something (the icon and the text as wide as it is), left to right, in its own coordinates:
    /// a press outside it is empty space (the list's selection rectangle starts there).
    func contentSpan() -> ClosedRange<CGFloat>? {
        let metrics = self.metrics
        var start = CGFloat.infinity, end = -CGFloat.infinity
        var textRect = bounds.safelyInset(dx: 2, dy: 0)
        if style == .name {
            if icon != nil { start = 3; end = 3 + metrics.iconSize }
            textRect.origin.x = metrics.textInset
            textRect.size.width = bounds.width - metrics.textInset - 2
        }
        if !text.isEmpty, textRect.width > 4 {
            let attrs = metrics.attributes(style, alignment: alignment, emphasized: false)
            var width = ceil((text as NSString).size(withAttributes: attrs).width)
            if !detail.isEmpty { width += 8 + ceil(("in " + detail as NSString).size(withAttributes: attrs).width) }
            width = min(width, textRect.width)
            let x: CGFloat = switch alignment {
            case .right: textRect.maxX - width
            case .center: textRect.midX - width / 2
            default: textRect.minX
            }
            start = min(start, x)
            end = max(end, x + width)
        }
        return start <= end ? start...end : nil
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { detail.isEmpty ? text : "\(text), in \(detail)" }
    override func accessibilityLabel() -> String? { detail.isEmpty ? text : "\(text), in \(detail)" }
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
