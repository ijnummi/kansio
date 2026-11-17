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
        init(title: String) { self.title = title }
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
        let record = Record(title: "\(verb) \(what) to “\(destination.lastPathComponent)”")
        records.append(record)
        let id = record.id

        let policy = ConflictPolicy { conflict in await prompter.ask(conflict) } // "apply to all" per operation
        var engine = CopyEngine(kind: kind, sources: sources, destination: destination, trasher: trasher, resolver: policy.resolver)
        engine.allowClone = allowClone
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
        record.progress = progress
        panel.update(record)
    }

    private func ask(_ id: UUID, _ failure: ItemFailure) async -> FailureDecision {
        guard let record = records.first(where: { $0.id == id }) else { return .skip }
        return await withCheckedContinuation { continuation in
            record.failure = (failure, continuation)
            panel.show()
            panel.reload()
        }
    }

    /// The user's answer to a failing row (Retry / Skip / Stop).
    func answer(_ id: UUID, _ decision: FailureDecision) {
        guard let record = records.first(where: { $0.id == id }), let pending = record.failure else { return }
        record.failure = nil
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

/// One operation: title, progress bar, details, Cancel — or, when an item failed, the error with
/// Retry / Skip / Stop.
@MainActor
final class OperationRow: NSView {
    let id: UUID
    private unowned let center: OperationCenter
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let cancelButton: NSButton
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    /// macOS privacy protection refused (P1-9): opens the Full Disk Access window; Retry after granting.
    let accessButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private(set) var hasFailure = false
    var preferredHeight: CGFloat { hasFailure ? 118 : 66 }

    init(record: OperationCenter.Record, center: OperationCenter) {
        id = record.id
        self.center = center
        cancelButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!,
                                target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: OperationsPanel.width, height: 66))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.setAccessibilityLabel("Cancel \(record.title)")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
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
        [titleLabel, detailLabel, bar, cancelButton, errorLabel, retryButton, skipButton, stopButton, accessButton].forEach(addSubview)
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
            detailLabel.stringValue = "Preparing… \(p.totalItems) items found"
        } else {
            bar.isIndeterminate = false
            bar.doubleValue = p.fraction
            let bytes = "\(Formatters.size.string(fromByteCount: p.completedBytes)) of \(Formatters.size.string(fromByteCount: p.totalBytes))"
            detailLabel.stringValue = "\(bytes) · \(p.completedItems) of \(p.totalItems) items" + (p.currentName.isEmpty ? "" : " · \(p.currentName)")
        }
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

    private func layoutViews() {
        let w = bounds.width
        titleLabel.frame = NSRect(x: 16, y: 8, width: w - 60, height: 18)
        cancelButton.frame = NSRect(x: w - 36, y: 20, width: 22, height: 22)
        bar.frame = NSRect(x: 16, y: 28, width: w - 60, height: 12)
        detailLabel.frame = NSRect(x: 16, y: 42, width: w - 60, height: 16)
        errorLabel.frame = NSRect(x: 16, y: 62, width: w - 32, height: 28)
        let buttonY: CGFloat = 90
        stopButton.frame = NSRect(x: w - 16 - 64, y: buttonY, width: 64, height: 22)
        skipButton.frame = NSRect(x: w - 16 - 64 * 2 - 8, y: buttonY, width: 64, height: 22)
        retryButton.frame = NSRect(x: w - 16 - 64 * 3 - 16, y: buttonY, width: 64, height: 22)
        accessButton.frame = NSRect(x: 16, y: buttonY, width: 110, height: 22)
        [errorLabel, retryButton, skipButton, stopButton].forEach { $0.isHidden = !hasFailure }
        if !hasFailure { accessButton.isHidden = true }
        frame.size.height = preferredHeight
    }

    @objc func cancelClicked() { center.cancel(id) }
    @objc func retryClicked() { center.answer(id, .retry) }
    @objc func skipClicked() { center.answer(id, .skip) }
    @objc func stopClicked() { center.answer(id, .stop) }
    @objc func accessClicked() { FullDiskAccessWindowController.shared.show() }
}
