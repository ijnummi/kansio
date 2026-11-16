import AppKit

@main
enum KansioApp {
    @MainActor
    static func main() {
        LaunchTrace.mark("main()")
        let options = LaunchOptions(arguments: CommandLine.arguments)
        let startFolder = options.initialFolder ?? FileManager.default.homeDirectoryForCurrentUser
        // List the first folder while AppKit starts up (see StartupPrefetch).
        StartupPrefetch.start(startFolder, sort: ViewSettings.shared.sort, showHidden: ViewSettings.shared.showHidden)
        StartupPrefetch.startVolumes()
        let app = NSApplication.shared
        let delegate = AppDelegate(options: options, startFolder: startFolder)
        app.delegate = delegate // NSApplication holds its delegate weakly
        app.setActivationPolicy(.regular)
        app.mainMenu = MainMenu.make()
        LaunchTrace.mark("menu built")
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let startFolder: URL
    private var windowController: MainWindowController?
    private var measurement: MeasurementRunner?
    private var selfTest: SelfTest?

    init(options: LaunchOptions, startFolder: URL) {
        self.options = options
        self.startFolder = startFolder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        let controller = WindowManager.shared.make(at: startFolder)
        LaunchTrace.mark("window controller created")
        windowController = controller
        if let mode = options.measurement {
            measurement = MeasurementRunner(mode: mode, window: controller)
        }
        controller.showWindow(nil)
        LaunchTrace.mark("showWindow")
        if let fixtures = options.selfTestFixtures {
            selfTest = SelfTest(window: controller, fixtures: fixtures, phase: options.selfTestPersisted ? .persisted : .main)
            Task { await self.selfTest?.run() }
        }
        NSApp.activate()
        LaunchTrace.mark("activate")
        IconCache.shared.prewarm()
        // Idle time after launch: create the breadcrumb buttons a deep path needs, off the first navigation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { controller.addressBar.warmUpCrumbs() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showFileOperations(_ sender: Any?) { OperationCenter.shared.showPanel() }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    /// Quitting while files are being copied would leave the operation half done: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = OperationCenter.shared.records.count
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A file operation is still running." : "\(running) file operations are still running."
        alert.informativeText = "If you quit now, they stop. Items already copied stay; the item in progress is removed."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        OperationCenter.shared.cancelAll()
        Task {
            while !OperationCenter.shared.records.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Command-line options (used by the measurement harness; normal launches pass none).
struct LaunchOptions {
    var initialFolder: URL?
    var measurement: MeasurementRunner.Mode?
    var selfTestFixtures: URL?
    /// `--self-test-persisted`: the second launch, checking the view settings the first one saved.
    var selfTestPersisted = false

    init(arguments: [String]) {
        var args = arguments.dropFirst()[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--open":
                if let p = args.popFirst() { initialFolder = URL(filePath: (p as NSString).expandingTildeInPath) }
            case "--measure-launch":
                measurement = .launch
            case "--measure-open":
                if let home = ProcessInfo.processInfo.environment["KANSIO_MEASURE_HOME"] {
                    initialFolder = URL(filePath: home, directoryHint: .isDirectory)
                }
                if let p = args.popFirst() {
                    measurement = .open(URL(filePath: (p as NSString).expandingTildeInPath), repeats: Int(ProcessInfo.processInfo.environment["KANSIO_REPEATS"] ?? "") ?? 7)
                }
            case "--snapshot":
                if let folder = args.popFirst(), let out = args.popFirst() {
                    let url = URL(filePath: (folder as NSString).expandingTildeInPath)
                    initialFolder = url
                    measurement = .snapshot(url, output: URL(filePath: out))
                }
            case "--self-test", "--self-test-persisted":
                selfTestPersisted = arg == "--self-test-persisted"
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = url
                    selfTestFixtures = url
                }
            case "--measure-status":
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = url
                    measurement = .status(url)
                }
            case "--measure-search":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = fixtures.appending(path: "flat-100k", directoryHint: .isDirectory)
                    measurement = .search(fixtures)
                }
            case "--measure-sizes":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = fixtures.appending(path: "flat-1k", directoryHint: .isDirectory)
                    measurement = .sizes(fixtures)
                }
            case "--measure-drag":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = fixtures.appending(path: "flat-10k", directoryHint: .isDirectory)
                    measurement = .drag(fixtures)
                }
            case "--measure-tabs":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = fixtures
                    measurement = .tabs(fixtures)
                }
            case "--measure-tree":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    // Hidden files on (the fixtures live under /var) without touching the user's settings.
                    let suite = "dev.kansio.measure-tree"
                    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                    UserDefaults(suiteName: suite)?.set(true, forKey: "view.showHidden")
                    setenv("KANSIO_DEFAULTS_SUITE", suite, 1)
                    initialFolder = fixtures
                    measurement = .tree(fixtures)
                }
            case "--measure-live":
                if let p = args.popFirst() {
                    let fixtures = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    let scratch = fixtures.appending(path: "scratch-live-\(getpid())", directoryHint: .isDirectory)
                    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    initialFolder = scratch
                    measurement = .live(scratch)
                }
            case "--measure-copy":
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = url.deletingLastPathComponent()
                    measurement = .copy(url)
                }
            case "--measure-scroll":
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath)
                    initialFolder = url
                    let speed = Double(ProcessInfo.processInfo.environment["KANSIO_SCROLL_SPEED"] ?? "") ?? 3000
                    measurement = .scroll(url, pointsPerSecond: speed, duration: .seconds(5))
                }
            default:
                break // ignore unknown (e.g. -NSDocumentRevisionsDebugMode from debuggers)
            }
        }
    }
}

/// KANSIO_TRACE=1: prints launch milestones as ms since the kernel started the process.
@MainActor
enum LaunchTrace {
    static let enabled = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil
    private static let start = processStartTime()
    static func mark(_ label: String) {
        guard enabled, let start else { return }
        print(String(format: "launch %7.1f ms  %@", Date().timeIntervalSince(start) * 1000, label))
    }
}
