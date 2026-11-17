import AppKit
import FileSystemKit
import SwiftUI

/// Settings (⌘,): a low-traffic window, so SwiftUI is fine here (the file list stays AppKit).
/// It edits `ViewSettings` — the single source of truth — so every change applies live in every
/// window through the same notification the header menu and View menu use.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(model: SettingsModel.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// File ▸ Close Tab / Close Window (⌘W, ⇧⌘W) close Settings while it's the key window.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func closeWindowAndTabs(_ sender: Any?) { window?.performClose(sender) }
}

/// `ViewSettings` for SwiftUI. Reads and writes go straight through; a change made anywhere else
/// (⇧⌘., the header menu, another window) is published so the window updates too.
/// (`ObservableObject` rather than `@Observable`: no macro plugin needed with the Command Line Tools.)
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let settings = ViewSettings.shared
    /// The pane shown in the window (the sidebar's selection; nil only while the list clears it).
    @Published var pane: SettingsPane? = .general

    private init() {
        NotificationCenter.default.addObserver(forName: .viewSettingsDidChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    var showHidden: Bool {
        get { settings.showHidden }
        set { settings.showHidden = newValue }
    }

    var showStatusBar: Bool {
        get { settings.showStatusBar }
        set { settings.showStatusBar = newValue }
    }

    var sortField: FileSort.Field {
        get { settings.sort.field }
        set { settings.sort = FileSort(field: newValue, ascending: settings.sort.ascending) }
    }

    var sortAscending: Bool {
        get { settings.sort.ascending }
        set { settings.sort = FileSort(field: settings.sort.field, ascending: newValue) }
    }

    func isShown(_ field: FileSort.Field) -> Bool { settings.columns.first { $0.field == field }?.hidden == false }

    func setShown(_ field: FileSort.Field, _ shown: Bool) {
        guard field != .name, let index = settings.columns.firstIndex(where: { $0.field == field }) else { return }
        settings.columns[index].hidden = !shown
    }

    func resetColumns() { settings.resetColumns() }

    func restoreDefaultFavorites() { FavoritesStore.shared.restoreDefaults() }

    var folderSizes: Bool {
        get { settings.folderSizes }
        set { settings.folderSizes = newValue }
    }

    var folderSizesOnNetwork: Bool {
        get { settings.folderSizesOnNetwork }
        set { settings.folderSizesOnNetwork = newValue }
    }

    var treeExpandToCurrent: Bool {
        get { settings.treeExpandToCurrent }
        set { settings.treeExpandToCurrent = newValue }
    }

    var treeExpandOnNetwork: Bool {
        get { settings.treeExpandOnNetwork }
        set { settings.treeExpandOnNetwork = newValue }
    }

    var treeCheckNetwork: Bool {
        get { settings.treeCheckNetwork }
        set { settings.treeCheckNetwork = newValue }
    }

    var treeKeyDelay: Double {
        get { Double(settings.treeKeyDelay) }
        set { settings.treeKeyDelay = Int(newValue.rounded()) }
    }

    /// The columns in menu order (Name first; it can't be hidden).
    static let columnOrder = FileListViewController.columnMenuOrder
}

/// The window's panes, listed in the sidebar (System Settings style).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, fileList, folderSizes, navigationPane, privacy
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .fileList: "File List"
        case .folderSizes: "Folder Sizes"
        case .navigationPane: "Navigation Pane"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .fileList: "list.bullet"
        case .folderSizes: "chart.bar.doc.horizontal"
        case .navigationPane: "sidebar.left"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let pane = model.pane ?? .general
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.pane) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
        } detail: {
            Form {
                switch pane {
                case .general: GeneralPane(model: model)
                case .fileList: FileListPane(model: model)
                case .folderSizes: FolderSizesPane(model: model)
                case .navigationPane: NavigationPanePane(model: model)
                case .privacy: PrivacyPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: Panes

/// A section's explanation: secondary, leading-aligned (a grouped form's footer is trailing-aligned by default).
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Show hidden files", isOn: $model.showHidden)
        } header: {
            Text("Files")
        } footer: {
            Footnote("Also View ▸ Show Hidden Files (⇧⌘.). Applies to every folder and window.")
        }
        Section("Window") {
            Toggle("Show status bar", isOn: $model.showStatusBar)
        }
    }
}

private struct FileListPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Sorting") {
            Picker("Sort by", selection: $model.sortField) {
                ForEach(SettingsModel.columnOrder, id: \.self) { field in
                    Text(FileListViewController.columnTitle(field)).tag(field)
                }
            }
            Picker("Order", selection: $model.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        }
        Section {
            ForEach(SettingsModel.columnOrder, id: \.self) { field in
                Toggle(FileListViewController.columnTitle(field), isOn: Binding(
                    get: { model.isShown(field) },
                    set: { model.setShown(field, $0) }))
                .disabled(field == .name)
            }
            LabeledContent("Widths, order and visibility") {
                Button("Reset Columns") { model.resetColumns() }
            }
        } header: {
            Text("Columns")
        } footer: {
            Footnote("Also from the menu on the list's column headers. Name can't be hidden.")
        }
    }
}

private struct FolderSizesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Calculate folder sizes", isOn: $model.folderSizes)
            Toggle("Also on network volumes", isOn: $model.folderSizesOnNetwork)
                .disabled(!model.folderSizes)
        } footer: {
            Footnote("Counted in the background (symlinks never followed, hard links once) and kept up to date. Without Full Disk Access, protected folders (Desktop, Documents, Downloads…) are left out.")
        }
    }
}

private struct NavigationPanePane: View {
    @ObservedObject var model: SettingsModel

    /// Choices for the arrow-key delay, plus the current value if it was set to something else.
    private var delays: [Double] {
        let choices: [Double] = [0, 100, 250, 500, 1000, 2000]
        return choices.contains(model.treeKeyDelay) ? choices : (choices + [model.treeKeyDelay]).sorted()
    }

    private static func delayTitle(_ milliseconds: Double) -> String {
        let ms = Int(milliseconds)
        return switch ms {
        case 0: "Immediately"
        case 1000: "After 1 second"
        case _ where ms % 1000 == 0: "After \(ms / 1000) seconds"
        default: "After \(ms) ms"
        }
    }

    var body: some View {
        Section {
            Toggle("Expand to the open folder", isOn: $model.treeExpandToCurrent)
            Picker("Open a folder selected with the arrow keys", selection: $model.treeKeyDelay) {
                ForEach(delays, id: \.self) { delay in
                    Text(Self.delayTitle(delay)).tag(delay)
                }
            }
        } header: {
            Text("Folders")
        } footer: {
            Footnote("A pause lets you move through several folders with ↑ and ↓ without listing each one.")
        }
        Section {
            Toggle("Expand to the open folder on network volumes", isOn: $model.treeExpandOnNetwork)
                .disabled(!model.treeExpandToCurrent)
            Toggle("Check network folders for subfolders", isOn: $model.treeCheckNetwork)
        } header: {
            Text("Network Volumes")
        } footer: {
            Footnote("Network folders otherwise always show a disclosure triangle; checking reads each visible folder over the network.")
        }
        Section("Favorites") {
            LabeledContent("Desktop, Documents, Downloads and Applications") {
                Button("Restore Defaults") { model.restoreDefaultFavorites() }
            }
        }
    }
}

private struct PrivacyPane: View {
    @ObservedObject var access = FullDiskAccessModel.shared

    var body: some View {
        Section {
            LabeledContent {
                Button("Full Disk Access…") { FullDiskAccessWindowController.shared.show() }
            } label: {
                Text("Full Disk Access")
                switch access.granted {
                case .some(true): Text("Allowed").foregroundStyle(.green)
                case .some(false): Text("Not allowed")
                case nil: Text("Checking…")
                }
            }
        } footer: {
            Footnote("Lets Kansio open every folder without asking for each protected one, and include them in folder sizes.")
        }
        .task { await access.refresh() }
    }
}
