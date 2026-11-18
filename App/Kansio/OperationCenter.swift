import AppKit
import FileSystemKit

/// All running copy/move operations, app-wide, and the File Operations panel that shows them.
///
/// Non-blocking: windows stay fully usable while operations run. The panel appears when an
/// operation takes longer than `showDelay` (quick ones never flash it) or right away when an item
/// fails — the failing row then offers Retry / Skip / Stop while the engine waits.
@MainActor
final class OperationCenter {
    static let shared = OperationCenter()

    final class Record {
        let id = UUID()
        let title: String
        var progress = OperationProgress()
        var failure: (failure: ItemFailure, answer: CheckedContinuation<FailureDecision, Never>)?
        var task: Task<Void, Never>?
        /// Pause / resume (P3-4); nil for operations that can't pause (Compress, Extract).
        let gate: PauseGate?
        var isPaused: Bool { gate?.isPaused ?? false }
        /// Questions open right now (a conflict sheet, an error row): the clock stops meanwhile.
        var waits = 0
        /// Speed and time left, on active time (data moving: not preparing, paused or waiting for an answer).
        var estimator = TransferEstimator()
        private(set) var remaining: Double?
        private var activeTime: Duration = .zero
        private var activeSince: ContinuousClock.Instant?
        private var dataStarted = false
        /// Speed (bytes/s) at each percent of progress — the panel's graph (Explorer's copy dialog).
        private(set) var speeds = [Double?](repeating: nil, count: 100)

        init(title: String, gate: PauseGate? = nil) {
            self.title = title
            self.gate = gate
        }

        var isWaiting: Bool { waits > 0 || failure != nil }

        /// Starts or stops the active-time clock to match the state.
        func updateClock(now: ContinuousClock.Instant = .now) {
            let running = dataStarted && !isPaused && !isWaiting
            if running, activeSince == nil {
                activeSince = now
            } else if !running, let since = activeSince {
                activeTime += now - since
                activeSince = nil
            }
        }

        func activeSeconds(now: ContinuousClock.Instant = .now) -> Double {
            let total = activeTime + (activeSince.map { now - $0 } ?? .zero)
            return Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        }

        func record(_ progress: OperationProgress, now: ContinuousClock.Instant = .now) {
            self.progress = progress
            guard !progress.isPreparing else { return }
            if !dataStarted { dataStarted = true }
            updateClock(now: now)
            guard activeSince != nil else { return } // paused / waiting: nothing to learn from
            estimator.add(time: activeSeconds(now: now), bytes: progress.completedBytes, items: progress.completedItems)
            remaining = estimator.remaining(totalBytes: progress.totalBytes, totalItems: progress.totalItems)
            if let speed = estimator.bytesPerSecond {
                speeds[min(99, max(0, Int(progress.fraction * 100)))] = speed
            }
        }
    }

    private(set) var records: [Record] = []
    /// Measurement hook: labels main-thread work for hitch traces.
    var traceNote: ((String) -> Void)?
    /// How long an operation runs before the panel appears.
    var showDelay: Duration = .milliseconds(500)
    /// Measurements/self-test turn this off to exercise the real copy path.
    var allowClone = true
    private lazy var panel = OperationsPanel(center: self)

    var isPanelVisible: Bool { panel.window?.isVisible == true }
    /// The panel's rows (self-test).
    var panelRows: [OperationRow] { panel.rowViews }

    /// Starts an operation; `completion` runs on the main actor with the result.
    @discardableResult
    func start(_ kind: OperationResult.Kind, sources: [URL], destination: URL, trasher: any Trasher,
               prompter: ConflictPrompter, completion: @escaping @MainActor (OperationResult) -> Void) -> UUID {
        let verb = kind == .copy ? "Copying" : "Moving"
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let gate = PauseGate()
        let record = Record(title: "\(verb) \(what) to “\(destination.lastPathComponent)”", gate: gate)
        records.append(record)
        let id = record.id

        let policy = ConflictPolicy { conflict in // "apply to all" per operation; the clock stops while asking
            await OperationCenter.shared.beginWait(id)
            let answer = await prompter.ask(conflict)
            await OperationCenter.shared.endWait(id)
            return answer
        }
        var engine = CopyEngine(kind: kind, sources: sources, destination: destination, trasher: trasher, resolver: policy.resolver)
        engine.allowClone = allowClone
        engine.pauseGate = gate
        engine.errorHandler = { failure in await OperationCenter.shared.ask(id, failure) }
        let onProgress: @Sendable (OperationProgress) -> Void = { progress in
            Task { @MainActor in OperationCenter.shared.update(id, progress) }
        }
        record.task = Task {
            let result = await engine.run(progress: onProgress)
            self.finish(id)
            completion(result)
        }
        Task {
            try? await Task.sleep(for: showDelay)
            if records.contains(where: { $0.id == id }) { traceNote?("show"); panel.show() }
        }
        panel.reload()
        return id
    }

    /// Starts any other long operation (P2-3: Compress, Extract) as a row in the panel: `work` reports progress and
    /// is cancelled (Task cancellation) by the row's Stop button. `completion` runs on the main actor.
    @discardableResult
    func start<Result: Sendable>(title: String, work: @escaping @Sendable (_ progress: @escaping @Sendable (OperationProgress) -> Void) async -> Result,
                                 completion: @escaping @MainActor (Result) -> Void) -> UUID {
        let record = Record(title: title)
        records.append(record)
        let id = record.id
        let onProgress: @Sendable (OperationProgress) -> Void = { progress in
            Task { @MainActor in OperationCenter.shared.update(id, progress) }
        }
        record.task = Task {
            let result = await work(onProgress)
            self.finish(id)
            completion(result)
        }
        Task {
            try? await Task.sleep(for: showDelay)
            if records.contains(where: { $0.id == id }) { traceNote?("show"); panel.show() }
        }
        panel.reload()
        return id
    }

    func cancel(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        // A pending error question counts as "stop".
        if let pending = record.failure { record.failure = nil; pending.answer.resume(returning: .stop) }
        record.task?.cancel()
        record.gate?.resume() // a paused operation wakes up to stop
    }

    /// Pause / resume (P3-4): a paused copy stops between files and inside a large one, holding nothing on screen.
    func setPaused(_ id: UUID, _ paused: Bool) {
        guard let record = records.first(where: { $0.id == id }), let gate = record.gate, paused != gate.isPaused else { return }
        if paused { gate.pause() } else { gate.resume() }
        record.updateClock()
        panel.update(record)
    }

    func togglePause(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        setPaused(id, !record.isPaused)
    }

    func record(_ id: UUID) -> Record? { records.first { $0.id == id } }

    private func beginWait(_ id: UUID) {
        guard let record = record(id) else { return }
        record.waits += 1
        record.updateClock()
        panel.update(record)
    }

    private func endWait(_ id: UUID) {
        guard let record = record(id) else { return }
        record.waits = max(0, record.waits - 1)
        record.updateClock()
        panel.update(record)
    }

    func cancelAll() { records.map(\.id).forEach(cancel) }

    func showPanel() { panel.show() }

    // MARK: Engine callbacks

    /// Progress updates applied to the panel (measurement).
    private(set) var progressUpdates = 0

    private func update(_ id: UUID, _ progress: OperationProgress) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        progressUpdates += 1
        traceNote?("update \(progress.isPreparing ? "preparing" : "\(progress.completedItems)")")
        record.record(progress)
        panel.update(record)
    }

    private func ask(_ id: UUID, _ failure: ItemFailure) async -> FailureDecision {
        guard let record = records.first(where: { $0.id == id }) else { return .skip }
        return await withCheckedContinuation { continuation in
            record.failure = (failure, continuation)
            record.updateClock()
            panel.show()
            panel.reload()
        }
    }

    /// The user's answer to a failing row (Retry / Skip / Stop).
    func answer(_ id: UUID, _ decision: FailureDecision) {
        guard let record = records.first(where: { $0.id == id }), let pending = record.failure else { return }
        record.failure = nil
        record.updateClock()
        pending.answer.resume(returning: decision)
        panel.reload()
    }

    private func finish(_ id: UUID) {
        FreeSpace.invalidate() // the operation changed what's used on disk
        records.removeAll { $0.id == id }
        panel.reload()
        if records.isEmpty { panel.hideSoon() }
    }
}

/// The File Operations panel: one row per operation.
@MainActor
final class OperationsPanel: NSObject {
    private unowned let center: OperationCenter
    private(set) var window: NSPanel?
    private let stack = FlippedView()
    private var rows: [UUID: OperationRow] = [:]
    private var hideTask: Task<Void, Never>?
    static let width: CGFloat = 440

    init(center: OperationCenter) { self.center = center }

    /// Rows currently shown (self-test).
    var rowViews: [OperationRow] { center.records.compactMap { rows[$0.id] } }

    func show() {
        hideTask?.cancel()
        let window = self.window ?? makeWindow()
        reload()
        if !window.isVisible {
            if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0 is BrowserWindow }) {
                let f = main.frame
                window.setFrameTopLeftPoint(NSPoint(x: f.maxX - Self.width - 20, y: f.minY + window.frame.height + 20))
            }
            window.orderFront(nil) // never takes focus from the user's window
        }
    }

    func hideSoon() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, center.records.isEmpty else { return }
            window?.orderOut(nil)
        }
    }

    func update(_ record: OperationCenter.Record) {
        rows[record.id]?.show(record)
    }

    func reload() {
        let ids = Set(center.records.map(\.id))
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        var y: CGFloat = 8
        for record in center.records {
            let row = rows[record.id] ?? {
                let row = OperationRow(record: record, center: center)
                stack.addSubview(row)
                rows[record.id] = row
                return row
            }()
            row.show(record)
            row.frame = NSRect(x: 0, y: y, width: Self.width, height: row.preferredHeight)
            y += row.preferredHeight
        }
        guard let window else { return }
        let height = max(80, min(y + 8, 420))
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(y + 8, height))
        var frame = window.frame
        let content = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "File Operations"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        panel.contentView?.addSubview(scroll)
        window = panel
        return panel
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One operation: title, progress bar, speed graph, details, speed and time left, Pause / Cancel — or, when an item
/// failed, the error with Retry / Skip / Stop.
@MainActor
final class OperationRow: NSView {
    let id: UUID
    private unowned let center: OperationCenter
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    /// Speed and time left ("45 MB/s · About 2 min left"), "Paused", "Waiting for your answer…".
    let rateLabel = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let graph = SpeedGraphView()
    let cancelButton: NSButton
    let pauseButton: NSButton
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    /// macOS privacy protection refused (P1-9): opens the Full Disk Access window; Retry after granting.
    let accessButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private(set) var hasFailure = false
    private var isPaused = false
    private static let baseHeight: CGFloat = 124
    var preferredHeight: CGFloat { hasFailure ? Self.baseHeight + 56 : Self.baseHeight }

    init(record: OperationCenter.Record, center: OperationCenter) {
        id = record.id
        self.center = center
        cancelButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!,
                                target: nil, action: nil)
        pauseButton = NSButton(image: NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Pause")!,
                               target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: OperationsPanel.width, height: Self.baseHeight))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        for label in [detailLabel, rateLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        rateLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        for button in [cancelButton, pauseButton] {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
        }
        cancelButton.setAccessibilityLabel("Cancel \(record.title)")
        cancelButton.toolTip = "Stop"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.isHidden = record.gate == nil
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for (button, action) in [(retryButton, #selector(retryClicked)), (skipButton, #selector(skipClicked)), (stopButton, #selector(stopClicked)),
                                 (accessButton, #selector(accessClicked))] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        retryButton.keyEquivalent = "\r"
        [titleLabel, bar, graph, detailLabel, rateLabel, pauseButton, cancelButton, errorLabel, retryButton, skipButton, stopButton, accessButton]
            .forEach(addSubview)
        updatePauseButton(paused: false, title: record.title)
        layoutViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ record: OperationCenter.Record) {
        titleLabel.stringValue = record.title
        let p = record.progress
        if p.isPreparing {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            detailLabel.stringValue = "Preparing… \(p.totalItems.formatted()) items found"
            rateLabel.stringValue = record.isPaused ? "Paused" : ""
        } else {
            bar.isIndeterminate = false
            bar.doubleValue = p.fraction
            let bytes = "\(Formatters.size.string(fromByteCount: p.completedBytes)) of \(Formatters.size.string(fromByteCount: p.totalBytes))"
            detailLabel.stringValue = "\(bytes) · \(p.completedItems.formatted()) of \(p.totalItems.formatted()) items"
                + (p.currentName.isEmpty ? "" : " · \(p.currentName)")
            rateLabel.stringValue = Self.rateText(record)
        }
        bar.alphaValue = record.isPaused ? 0.45 : 1
        graph.update(speeds: record.speeds, fraction: p.isPreparing ? 0 : p.fraction, paused: record.isPaused)
        if record.isPaused != isPaused { updatePauseButton(paused: record.isPaused, title: record.title) }
        let failed = record.failure != nil
        if let failure = record.failure {
            errorLabel.stringValue = "Couldn’t copy “\(failure.failure.url.lastPathComponent)”: \(failure.failure.error.reason)."
            errorLabel.toolTip = failure.failure.url.path(percentEncoded: false)
        }
        accessButton.isHidden = !(record.failure?.failure.error.isPrivacyDenied ?? false)
        if failed != hasFailure {
            hasFailure = failed
            layoutViews()
        }
    }

    /// "45.2 MB/s · 1,200 files/s · About 2 min left" — or why nothing is moving.
    static func rateText(_ record: OperationCenter.Record) -> String {
        if record.isPaused { return "Paused" }
        if record.isWaiting { return "Waiting for your answer…" }
        var parts: [String] = []
        if let speed = record.estimator.bytesPerSecond {
            parts.append("\(Formatters.size.string(fromByteCount: Int64(speed)))/s")
        }
        // Small files: the file rate says more than bytes.
        if let files = record.estimator.itemsPerSecond, files >= 10 {
            parts.append("\(Int(files.rounded()).formatted()) files/s")
        }
        if let remaining = record.remaining {
            parts.append(timeLeft(remaining))
        } else if record.progress.fraction < 1 {
            parts.append("Estimating time left…")
        }
        return parts.joined(separator: " · ")
    }

    /// "About 2 min left" (Explorer and Finder round like this; seconds only in the last minute).
    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 5 { return "Less than 5 seconds left" }
        if seconds < 60 { return "About \(Int((seconds / 5).rounded()) * 5) seconds left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "About 1 minute left" : "About \(minutes) minutes left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "About \(hours) h left" : "About \(hours) h \(rest) min left"
    }

    private func updatePauseButton(paused: Bool, title: String) {
        isPaused = paused
        let name = paused ? "play.circle.fill" : "pause.circle.fill"
        pauseButton.image = NSImage(systemSymbolName: name, accessibilityDescription: paused ? "Resume" : "Pause")
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        pauseButton.setAccessibilityLabel("\(paused ? "Resume" : "Pause") \(title)")
    }

    private func layoutViews() {
        let w = bounds.width
        titleLabel.frame = NSRect(x: 16, y: 8, width: w - 84, height: 18)
        pauseButton.frame = NSRect(x: w - 62, y: 20, width: 22, height: 22)
        cancelButton.frame = NSRect(x: w - 36, y: 20, width: 22, height: 22)
        bar.frame = NSRect(x: 16, y: 28, width: w - 84, height: 12)
        graph.frame = NSRect(x: 16, y: 46, width: w - 84, height: 36)
        detailLabel.frame = NSRect(x: 16, y: 86, width: w - 32, height: 16)
        rateLabel.frame = NSRect(x: 16, y: 102, width: w - 32, height: 16)
        let errorY = Self.baseHeight - 2
        errorLabel.frame = NSRect(x: 16, y: errorY, width: w - 32, height: 28)
        let buttonY = errorY + 28
        stopButton.frame = NSRect(x: w - 16 - 64, y: buttonY, width: 64, height: 22)
        skipButton.frame = NSRect(x: w - 16 - 64 * 2 - 8, y: buttonY, width: 64, height: 22)
        retryButton.frame = NSRect(x: w - 16 - 64 * 3 - 16, y: buttonY, width: 64, height: 22)
        accessButton.frame = NSRect(x: 16, y: buttonY, width: 110, height: 22)
        [errorLabel, retryButton, skipButton, stopButton].forEach { $0.isHidden = !hasFailure }
        if !hasFailure { accessButton.isHidden = true }
        frame.size.height = preferredHeight
    }

    @objc func cancelClicked() { center.cancel(id) }
    @objc func pauseClicked() { center.togglePause(id) }
    @objc func retryClicked() { center.answer(id, .retry) }
    @objc func skipClicked() { center.answer(id, .skip) }
    @objc func stopClicked() { center.answer(id, .stop) }
    @objc func accessClicked() { FullDiskAccessWindowController.shared.show() }
}

/// Speed against progress (Explorer's copy graph): x = percent done, y = speed, one area per operation. A single
/// series in the accent colour — a 2-point line over a light fill, a hairline baseline, no grid. Hovering shows the
/// speed at that point (a crosshair and a label in the secondary text colour).
@MainActor
final class SpeedGraphView: NSView {
    private(set) var speeds: [Double?] = []
    private var fraction = 0.0
    private var paused = false
    private var hoverX: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Speed graph")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    func update(speeds: [Double?], fraction: Double, paused: Bool) {
        guard speeds != self.speeds || fraction != self.fraction || paused != self.paused else { return }
        self.speeds = speeds
        self.fraction = fraction
        self.paused = paused
        if let latest = speeds.compactMap({ $0 }).last {
            setAccessibilityValue("\(Formatters.size.string(fromByteCount: Int64(latest)))/s at \(Int(fraction * 100)) %")
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hoverX = convert(event.locationInWindow, from: nil).x; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hoverX = nil; needsDisplay = true }

    /// Points of the curve: each percent with a known speed (gaps carry the last one on).
    private func points(in rect: NSRect, top: Double) -> [NSPoint] {
        var points: [NSPoint] = []
        var last: Double?
        let upTo = min(speeds.count, Int(fraction * 100) + 1)
        for i in 0..<upTo {
            guard let value = speeds[i] ?? last else { continue }
            last = value
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(max(1, speeds.count - 1))
            points.append(NSPoint(x: x, y: rect.minY + rect.height * CGFloat(min(1, value / top))))
        }
        return points
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 1, dy: 2)
        NSColor.separatorColor.setFill()
        NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1).fill() // baseline
        let known = speeds.compactMap { $0 }
        guard let peak = known.max(), peak > 0 else { return }
        let top = peak * 1.15 // headroom above the peak
        let curve = points(in: plot, top: top)
        guard let first = curve.first, let last = curve.last else { return }
        let accent = paused ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor
        let area = NSBezierPath()
        area.move(to: NSPoint(x: first.x, y: plot.minY))
        curve.forEach(area.line)
        area.line(to: NSPoint(x: last.x, y: plot.minY))
        area.close()
        accent.withAlphaComponent(0.18).setFill()
        area.fill()
        let line = NSBezierPath()
        line.move(to: first)
        curve.dropFirst().forEach(line.line)
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        accent.setStroke()
        line.stroke()

        // Hover: the speed at that point.
        guard let hoverX, hoverX >= plot.minX, hoverX <= last.x else { return }
        let index = min(speeds.count - 1, max(0, Int(((hoverX - plot.minX) / plot.width * CGFloat(speeds.count - 1)).rounded())))
        guard let value = speeds[...index].last(where: { $0 != nil }) ?? nil else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSRect(x: hoverX.rounded(), y: plot.minY, width: 1, height: plot.height).fill()
        let text = "\(Formatters.size.string(fromByteCount: Int64(value)))/s at \(index) %" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attributes)
        let x = hoverX + 4 + size.width > plot.maxX ? hoverX - 4 - size.width : hoverX + 4
        text.draw(at: NSPoint(x: x, y: plot.maxY - size.height), withAttributes: attributes)
    }
}
