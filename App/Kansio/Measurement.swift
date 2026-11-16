import AppKit
import Darwin
import FileSystemKit

/// Measures main-thread run loop iterations: from waking up to going back to sleep,
/// *including* AppKit layout/drawing and the Core Animation commit (which run as
/// before-waiting observers). Anything over 16 ms drops a frame at 60 Hz.
///
/// Two observers bracket each iteration: one runs first after waking (lowest order),
/// one runs last before sleeping (highest order, after CA's commit observer).
@MainActor
final class HitchMonitor {
    private(set) var maxBusy: Duration = .zero
    private(set) var hitchCount = 0
    private var wokeAt: ContinuousClock.Instant?
    private var observers: [CFRunLoopObserver] = []
    private var atIterationEnd: [@MainActor (ContinuousClock.Instant) -> Void] = []
    private var notes: [String] = []
    private let trace = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wokeAt = .now }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.iterationEnded() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func reset() { maxBusy = .zero; hitchCount = 0 }

    /// Runs `body` with the time at which the current iteration finished (rows drawn and committed).
    func whenIterationEnds(_ body: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        atIterationEnd.append(body)
    }

    /// Labels the current iteration in hitch traces (KANSIO_TRACE=1).
    func note(_ text: String) { if trace { notes.append(text) } }

    private func iterationEnded() {
        let now = ContinuousClock.now
        if let wokeAt {
            let busy = now - wokeAt
            maxBusy = max(maxBusy, busy)
            if busy > .milliseconds(16) {
                hitchCount += 1
                if trace { print("hitch: \(ms(busy)) ms [\(notes.joined(separator: ", "))]") }
            }
        }
        wokeAt = nil
        notes.removeAll()
        let pending = atIterationEnd
        atIterationEnd.removeAll()
        for body in pending { body(now) }
    }
}

/// Runs a scripted measurement in the real app, prints results to stdout, then quits.
///
///   Kansio --measure-launch            process start → home rows drawn / fully listed
///   Kansio --measure-open <folder>     home → folder, 7×: first rows drawn / full list drawn
@MainActor
final class MeasurementRunner {
    enum Mode {
        case launch
        case open(URL, repeats: Int)
        /// Render the visible part of the list to a PNG once the folder is listed, then quit.
        case snapshot(URL, output: URL)
        /// Scroll through `URL` at a constant speed, one step per display frame, and report
        /// late frames (a frame is "dropped" when the next callback comes > 1.5 frames later).
        case scroll(URL, pointsPerSecond: CGFloat, duration: Duration)
    }

    private let mode: Mode
    private let fileList: FileListViewController
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let hitches = HitchMonitor()
    private var firstRows: [Duration] = []
    private var complete: [Duration] = []
    private var maxApply: Duration = .zero
    private var maxHitch: Duration = .zero
    private var hitchCount = 0
    private var runs = 0
    private var inTarget = false
    private var sawFirstForGeneration = -1

    init(mode: Mode, window: MainWindowController) {
        self.mode = mode
        fileList = window.fileList
        hitches.start()
        fileList.onDisplay = { [weak self] event in self?.handle(event) }
    }

    private var scrollDriver: ScrollDriver?

    private func handle(_ event: FileListViewController.DisplayEvent) {
        hitches.note("apply \(event.rowCount) rows: \(ms(event.mainThreadApply)) ms")
        let isFirst = sawFirstForGeneration != event.generation
        sawFirstForGeneration = event.generation
        hitches.whenIterationEnds { [weak self] drawnAt in self?.drawn(event, isFirst: isFirst, at: drawnAt) }
    }

    private func drawn(_ event: FileListViewController.DisplayEvent, isFirst: Bool, at drawnAt: ContinuousClock.Instant) {
        switch mode {
        case .snapshot(_, let output):
            guard event.isComplete else { return }
            // Give per-file icons (loaded off-main) a moment to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    do {
                        guard let window = self.fileList.view.window else { return self.finish("no window") }
                        try WindowSnapshot.render(window, to: output)
                        let state = self.fileList.state
                        print("snapshot=\(output.path(percentEncoded: false)) rows=\(event.rowCount) status=\"\(state.summary)\" error=\"\(state.error?.description ?? "")\"")
                        self.finish(nil)
                    } catch {
                        self.finish("\(error)")
                    }
                }
            }

        case .scroll(_, let speed, let duration):
            guard event.isComplete, scrollDriver == nil else { return }
            hitches.reset()
            let driver = ScrollDriver(view: fileList.view, speed: speed, duration: duration) { [weak self] step in
                self?.fileList.scrollForMeasurement(by: step)
            } completion: { [weak self] intervals in
                self?.reportScroll(intervals)
            }
            scrollDriver = driver
            // Start after launch-time work (window activation, menus, input services) has settled,
            // so the numbers describe scrolling, not app startup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    self.hitches.reset()
                    driver.start()
                }
            }

        case .launch:
            guard let start = processStartTime() else { return finish("could not read process start time") }
            // Convert "drawn" to wall-clock to compare with the kernel's process start time.
            let sinceLaunch = Duration.seconds(Date().timeIntervalSince(start)) - (ContinuousClock.now - drawnAt)
            if isFirst { print("launch_to_first_rows_ms=\(ms(sinceLaunch)) rows=\(event.rowCount)") }
            if event.isComplete {
                print("launch_to_complete_ms=\(ms(sinceLaunch)) rows=\(event.rowCount) max_main_thread_busy_ms=\(ms(hitches.maxBusy))")
                finish(nil)
            }

        case .open(let target, let repeats):
            guard inTarget else {
                guard event.isComplete else { return }
                // Home is loaded; go to the target on the next run loop turn.
                inTarget = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.hitches.reset()
                        self.fileList.navigate(to: target)
                    }
                }
                return
            }
            let elapsed = drawnAt - event.navigationStart
            maxApply = max(maxApply, event.mainThreadApply)
            if isFirst { firstRows.append(elapsed) }
            guard event.isComplete else { return }
            complete.append(elapsed)
            maxHitch = max(maxHitch, hitches.maxBusy)
            hitchCount += hitches.hitchCount
            runs += 1
            inTarget = false
            if runs == repeats { return report(target) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.fileList.navigate(to: self.home) } }
        }
    }

    private func reportScroll(_ intervals: [Double]) {
        guard intervals.count > 10 else { return finish("too few frames") }
        let sorted = intervals.sorted()
        let frame = sorted[sorted.count / 2] // nominal frame interval (8.3 ms at 120 Hz, 16.7 at 60 Hz)
        let dropped = intervals.filter { $0 > frame * 1.5 }.count
        func f(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
            print("dropped frames at:", intervals.enumerated().filter { $0.element > frame * 1.5 }.map { "#\($0.offset) \(f($0.element)) ms" })
        }
        print("scroll_frames=\(intervals.count) nominal_frame_ms=\(f(frame)) p99_ms=\(f(sorted[sorted.count * 99 / 100])) max_ms=\(f(sorted.last!)) dropped=\(dropped) (\(String(format: "%.2f", Double(dropped) * 100 / Double(intervals.count)))%) max_main_thread_busy_ms=\(ms(hitches.maxBusy))")
        finish(nil)
    }

    private func report(_ target: URL) {
        // The first run includes cold caches (icons, formatters, LaunchServices).
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        print("folder=\(target.path(percentEncoded: false)) runs=\(runs) rows=\(fileList.state.itemCount)")
        print("first_rows_ms median=\(ms(median(firstRows))) first_run=\(ms(firstRows[0])) all=\(firstRows.map(ms))")
        print("complete_ms   median=\(ms(median(complete))) first_run=\(ms(complete[0])) all=\(complete.map(ms))")
        print("max_main_thread_apply_ms=\(ms(maxApply)) max_main_thread_busy_ms=\(ms(maxHitch)) hitches_over_16ms=\(hitchCount)")
        finish(nil)
    }

    private func finish(_ error: String?) {
        if let error { print("error: \(error)") }
        fflush(stdout)
        exit(error == nil ? 0 : 1)
    }
}

private func ms(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.1f", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
}

/// When the kernel started this process (includes dyld and framework loading).
func processStartTime() -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

/// Drives a constant-speed scroll from a display link (one step per screen refresh) and
/// records the interval between callbacks. A busy main thread shows up as late callbacks.
@MainActor
final class ScrollDriver: NSObject {
    private let view: NSView
    private let speed: CGFloat
    private let duration: Duration
    private let step: (CGFloat) -> Void
    private let completion: ([Double]) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var started = ContinuousClock.now
    private var intervals: [Double] = []

    init(view: NSView, speed: CGFloat, duration: Duration, step: @escaping (CGFloat) -> Void, completion: @escaping ([Double]) -> Void) {
        self.view = view
        self.speed = speed
        self.duration = duration
        self.step = step
        self.completion = completion
    }

    func start() {
        started = .now
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            let dt = link.timestamp - last
            intervals.append(dt)
            step(speed * CGFloat(dt))
        }
        last = link.timestamp
        if ContinuousClock.now - started >= duration {
            link.invalidate()
            self.link = nil
            completion(intervals)
        }
    }
}

/// Renders a window's tables (header + visible row views, at their on-screen positions) into
/// a PNG (2x) — a screenshot substitute that needs no Screen Recording permission.
/// `cacheDisplay` on the window or a scroll view can't capture NSTableView rows, but it can
/// capture each row view. Title bar, toolbar and vibrancy aren't rendered.
@MainActor
enum WindowSnapshot {
    static func render(_ window: NSWindow, to url: URL) throws {
        guard let content = window.contentView else { return }
        let size = content.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        for table in tables(in: content) {
            guard let scroll = table.enclosingScrollView else { continue }
            let clip = scroll.convert(scroll.bounds, to: nil)
            (table.style == .sourceList ? NSColor.underPageBackgroundColor : NSColor.textBackgroundColor).setFill()
            clip.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
                draw(rowView)
            }
            if let header = table.headerView { draw(header) }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func draw(_ view: NSView) {
        guard let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: r)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(r)
        image.draw(in: view.convert(view.bounds, to: nil))
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
}
