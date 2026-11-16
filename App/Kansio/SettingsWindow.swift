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
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
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
}

/// `ViewSettings` for SwiftUI. Reads and writes go straight through; a change made anywhere else
/// (⇧⌘., the header menu, another window) is published so the window updates too.
/// (`ObservableObject` rather than `@Observable`: no macro plugin needed with the Command Line Tools.)
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let settings = ViewSettings.shared

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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var access = FullDiskAccessModel.shared

    var body: some View {
        Form {
            Section("Files") {
                Toggle("Show hidden files", isOn: $model.showHidden)
                Text("Also View ▸ Show Hidden Files (⇧⌘.). Applies to every folder and window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("List") {
                Picker("Sort by", selection: $model.sortField) {
                    ForEach(SettingsModel.columnOrder, id: \.self) { field in
                        Text(FileListViewController.columnTitle(field)).tag(field)
                    }
                }
                Picker("Order", selection: $model.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                LabeledContent("Columns") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(SettingsModel.columnOrder, id: \.self) { field in
                            Toggle(FileListViewController.columnTitle(field), isOn: Binding(
                                get: { model.isShown(field) },
                                set: { model.setShown(field, $0) }))
                            .disabled(field == .name)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset Columns") { model.resetColumns() }
                }
                Toggle("Calculate folder sizes", isOn: $model.folderSizes)
                Toggle("…also on network volumes", isOn: $model.folderSizesOnNetwork)
                    .disabled(!model.folderSizes)
                Text("Counted in the background (symlinks never followed, hard links once) and kept up to date. Without Full Disk Access, protected folders (Desktop, Documents, Downloads…) are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Navigation Pane") {
                Toggle("Expand to open folder", isOn: $model.treeExpandToCurrent)
                Toggle("…also on network volumes", isOn: $model.treeExpandOnNetwork)
                    .disabled(!model.treeExpandToCurrent)
                Toggle("Check network folders for subfolders", isOn: $model.treeCheckNetwork)
                Text("Network folders otherwise always show a disclosure triangle; checking reads each visible folder over the network.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Favorites")
                    Spacer()
                    Button("Restore Default Favorites") { model.restoreDefaultFavorites() }
                }
                LabeledContent("Arrow keys open a folder after") {
                    HStack {
                        Slider(value: $model.treeKeyDelay, in: 0...1000, step: 50).frame(width: 140)
                        Text(model.treeKeyDelay == 0 ? "at once" : "\(Int(model.treeKeyDelay)) ms")
                            .monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("Window") {
                Toggle("Show status bar", isOn: $model.showStatusBar)
            }
            Section("Privacy") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(access.granted == true ? "Allowed" : access.granted == false ? "Not allowed" : "Checking…")
                            .foregroundStyle(access.granted == true ? .green : .secondary)
                        Button("Full Disk Access…") { FullDiskAccessWindowController.shared.show() }
                    }
                }
                Text("Lets Kansio open every folder without asking for each protected one, and include them in folder sizes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task { await access.refresh() }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
