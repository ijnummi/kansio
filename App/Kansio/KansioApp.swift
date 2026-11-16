import AppKit

@main
enum KansioApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(options: LaunchOptions(arguments: CommandLine.arguments))
        app.delegate = delegate // NSApplication holds its delegate weakly
        app.setActivationPolicy(.regular)
        app.mainMenu = MainMenu.make()
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var windowController: MainWindowController?
    private var measurement: MeasurementRunner?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let start = options.initialFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let controller = MainWindowController(initialFolder: start)
        windowController = controller
        if let mode = options.measurement {
            measurement = MeasurementRunner(mode: mode, window: controller)
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Command-line options (used by the measurement harness; normal launches pass none).
struct LaunchOptions {
    var initialFolder: URL?
    var measurement: MeasurementRunner.Mode?

    init(arguments: [String]) {
        var args = arguments.dropFirst()[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--open":
                if let p = args.popFirst() { initialFolder = URL(filePath: (p as NSString).expandingTildeInPath) }
            case "--measure-launch":
                measurement = .launch
            case "--measure-open":
                if let p = args.popFirst() {
                    measurement = .open(URL(filePath: (p as NSString).expandingTildeInPath), repeats: 7)
                }
            case "--snapshot":
                if let folder = args.popFirst(), let out = args.popFirst() {
                    let url = URL(filePath: (folder as NSString).expandingTildeInPath)
                    initialFolder = url
                    measurement = .snapshot(url, output: URL(filePath: out))
                }
            case "--measure-redraw":
                if let p = args.popFirst() {
                    let url = URL(filePath: (p as NSString).expandingTildeInPath)
                    initialFolder = url
                    measurement = .redraw(url, pages: Int(ProcessInfo.processInfo.environment["KANSIO_PAGES"] ?? "") ?? 200)
                }
            default:
                break // ignore unknown (e.g. -NSDocumentRevisionsDebugMode from debuggers)
            }
        }
    }
}
