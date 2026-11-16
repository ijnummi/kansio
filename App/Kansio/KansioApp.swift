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
        let controller = MainWindowController(initialFolder: startFolder)
        LaunchTrace.mark("window controller created")
        windowController = controller
        if let mode = options.measurement {
            measurement = MeasurementRunner(mode: mode, window: controller)
        }
        controller.showWindow(nil)
        LaunchTrace.mark("showWindow")
        if let fixtures = options.selfTestFixtures {
            selfTest = SelfTest(window: controller, fixtures: fixtures)
            Task { await self.selfTest?.run() }
        }
        NSApp.activate()
        LaunchTrace.mark("activate")
        IconCache.shared.prewarm()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Command-line options (used by the measurement harness; normal launches pass none).
struct LaunchOptions {
    var initialFolder: URL?
    var measurement: MeasurementRunner.Mode?
    var selfTestFixtures: URL?

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
            case "--self-test":
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                    initialFolder = url
                    selfTestFixtures = url
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
