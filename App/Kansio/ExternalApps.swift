import AppKit
import FileSystemKit
import UniformTypeIdentifiers

/// Open in Terminal / Open in an editor (P3-6, Explorer 11's "Open in Terminal"). Which apps: Settings ▸ Apps, and
/// only there — no built-in default and no app chooser when opening; an item with no app set opens that pane.
/// The folder (or for the editor, the selected items) is handed to the app the way Finder's "Open With" does —
/// Terminal, iTerm2, Warp, Ghostty… open a window there; editors open the folder as a project.
struct AppChoice: Codable, Hashable, Sendable {
    var path: String
    var name: String

    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

    /// The app at `url`, named as Finder shows it ("iTerm", not "iTerm.app"). Touches the disk: off the main thread.
    nonisolated static func at(_ url: URL) -> AppChoice {
        let path = url.path(percentEncoded: false)
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return AppChoice(path: path, name: name)
    }
}

@MainActor
final class ExternalApps {
    static let shared = ExternalApps()

    enum Kind {
        case terminal, editor
        var title: String { self == .terminal ? "Terminal" : "Editor" }
    }

    /// Terminals and editors looked for (bundle identifiers), in the order they're offered.
    nonisolated static let terminalIDs = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                          "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
    nonisolated static let editorIDs = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
                                        "com.sublimetext.3", "com.barebones.bbedit", "com.panic.Nova", "com.macromates.TextMate",
                                        "com.vscodium", "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
                                        "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.apple.TextEdit"]

    /// The installed ones (LaunchServices; off the main thread).
    nonisolated static func detect() async -> (terminals: [AppChoice], editors: [AppChoice]) {
        await Task.detached(priority: .userInitiated) {
            func find(_ ids: [String]) -> [AppChoice] {
                var seen = Set<String>()
                return ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map(AppChoice.at).filter { seen.insert($0.path).inserted }
            }
            return (find(terminalIDs), find(editorIDs))
        }.value
    }

    private let settings = ViewSettings.shared

    func choice(_ kind: Kind) -> AppChoice? { kind == .terminal ? settings.terminalApp : settings.editorApp }

    /// "Open in iTerm" / "Open in Visual Studio Code" / "Open in Editor…" (none set yet: it opens Settings ▸ Apps).
    func menuTitle(_ kind: Kind) -> String {
        guard let app = choice(kind) else { return "Open in \(kind.title)…" }
        return "Open in \(app.name)"
    }

    /// Self-test: answers the app chooser instead of the open panel.
    var chooserOverride: ((Kind) -> URL?)?

    /// Settings ▸ Apps ▸ Other…: the app chooser (an open panel in Applications, as a sheet on `window`).
    func chooseApp(_ kind: Kind, window: NSWindow?, completion: @escaping @MainActor (AppChoice?) -> Void) {
        let finish: @MainActor (URL?) -> Void = { url in
            guard let url else { completion(nil); return }
            Task {
                let choice = await Task.detached { AppChoice.at(url) }.value
                completion(choice)
            }
        }
        if let chooserOverride { finish(chooserOverride(kind)); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = "Choose"
        panel.message = kind == .terminal ? "Choose the app that Open in Terminal uses:" : "Choose the editor that Open in Editor uses:"
        if let window {
            panel.beginSheetModal(for: window) { finish($0 == .OK ? panel.url : nil) }
        } else {
            finish(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    func setChoice(_ kind: Kind, _ app: AppChoice?) {
        if kind == .terminal { settings.terminalApp = app } else { settings.editorApp = app }
    }

    /// Self-test: called instead of showing Settings ▸ Apps.
    var showSettingsOverride: (() -> Void)?

    /// Opens `urls` in the app set in Settings ▸ Apps; with none set, opens that pane (and says why). Errors are shown
    /// in `list`.
    func open(_ urls: [URL], in kind: Kind, list: FileListViewController) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard let app = choice(kind) else {
            list.showMessage("Choose the \(kind == .terminal ? "terminal" : "editor") to use in Settings ▸ Apps.")
            if let showSettingsOverride { showSettingsOverride(); return }
            SettingsModel.shared.pane = .apps
            SettingsWindowController.shared.show()
            return
        }
        list.opener.open(urls, withApplication: app.url) { [weak list] error in
            guard let error, let list else { return }
            list.showMessage("Couldn’t open in \(app.name): \((error as NSError).localizedDescription)")
        }
    }
}

extension FileListViewController {
    /// What Open in Terminal opens: the one selected folder, else the folder on screen.
    var terminalTarget: URL? {
        guard !isShowingTrash, !isShowingArchive else { return nil }
        if selectedItems.count == 1, let item = selectedItems.first, item.isFolder { return url(of: item) }
        return folder
    }

    /// What Open in Editor opens: the selection, else the folder on screen.
    var editorTargets: [URL] {
        guard !isShowingTrash, !isShowingArchive else { return [] }
        return selectedItems.isEmpty ? [folder] : selectedItems.map(url(of:))
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let target = terminalTarget else { NSSound.beep(); return }
        ExternalApps.shared.open([target], in: .terminal, list: self)
    }

    @objc func openInEditor(_ sender: Any?) {
        let targets = editorTargets
        guard !targets.isEmpty else { NSSound.beep(); return }
        ExternalApps.shared.open(targets, in: .editor, list: self)
    }
}
