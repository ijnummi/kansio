import AppKit
import FileSystemKit

/// Explorer-style status bar under the list: "1,234 items" · "3 items selected  12.3 MB" ·
/// "45.6 GB available". Updated synchronously on every selection change (cheap); the size of
/// very large selections and the free space are computed off the main thread.
@MainActor
final class StatusBarView: NSView {
    static let height: CGFloat = 24
    let countLabel = NSTextField(labelWithString: "")
    let selectionLabel = NSTextField(labelWithString: "")
    let spaceLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [countLabel, selectionLabel, spaceLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        spaceLabel.alignment = .right
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
        layoutLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutLabels()
    }

    private func layoutLabels() {
        let y = (bounds.height - 16) / 2, w = bounds.width
        countLabel.frame = NSRect(x: 12, y: y, width: min(200, w * 0.3), height: 16)
        selectionLabel.frame = NSRect(x: countLabel.frame.maxX + 16, y: y, width: max(0, w * 0.45), height: 16)
        spaceLabel.frame = NSRect(x: max(0, w - 12 - 180), y: y, width: 180, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { false }
}

/// Free space per volume, read off-main (can be slow on network volumes) and cached briefly.
enum FreeSpace {
    @MainActor private static var cache: [String: (time: ContinuousClock.Instant, bytes: Int64?)] = [:]
    @MainActor private static var inflight: Set<String> = []

    /// The cached value if fresh; otherwise nil and `fetch` calls back when known.
    @MainActor static func available(for folder: URL, refresh: @escaping @MainActor (Int64?) -> Void) -> Int64?? {
        let key = folder.path(percentEncoded: false)
        if let hit = cache[key], ContinuousClock.now - hit.time < .seconds(10) { return .some(hit.bytes) }
        guard inflight.insert(key).inserted else { return nil } // one fetch per folder at a time
        Task {
            defer { inflight.remove(key) }
            let value: Int64?? = await runWithTimeout(.seconds(2)) {
                let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
            }
            let bytes = value ?? nil
            cache[key] = (.now, bytes)
            refresh(bytes)
        }
        return nil
    }

    static func invalidate() { Task { @MainActor in cache.removeAll() } }

    /// `work` off the main thread (listing queue); nil if it takes longer than `timeout`
    /// (the work itself can't be interrupted — a hung network volume — but we stop waiting).
    private static func runWithTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        await runWithDeadline(timeout, work).fast
    }
}
