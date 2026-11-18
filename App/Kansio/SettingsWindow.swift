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
    /// Most Used Folders ▸ Reset asks first (no `@State`: its macro plugin isn't in the Command Line Tools).
    @Published var confirmingMostUsedReset = false

    private init() {
        for name in [Notification.Name.viewSettingsDidChange, .folderUsageDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        }
    }

    var listTextSize: Int {
        get { settings.listTextSize }
        set { settings.listTextSize = newValue }
    }

    var listDensity: ViewSettings.Density {
        get { settings.listDensity }
        set { settings.listDensity = newValue }
    }

    var usageTopCount: Int {
        get { settings.usageTopCount }
        set { settings.usageTopCount = newValue }
    }

    var usageOpenWeight: ViewSettings.Importance {
        get { settings.usageOpenWeight }
        set { settings.usageOpenWeight = newValue }
    }

    var usageTabWeight: ViewSettings.Importance {
        get { settings.usageTabWeight }
        set { settings.usageTabWeight = newValue }
    }

    var usageDwell: Int {
        get { settings.usageDwell }
        set { settings.usageDwell = newValue }
    }

    var rememberedFolders: Int { FolderUsageStore.shared.usage.count }

    func resetMostUsed() { FolderUsageStore.shared.reset() }

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

    var openArchivesAsFolders: Bool {
        get { settings.openArchivesAsFolders }
        set { settings.openArchivesAsFolders = newValue }
    }
    var networkTrashFolders: Bool {
        get { settings.networkTrashFolders }
        set { settings.networkTrashFolders = newValue }
    }

    var archiveEngine: ViewSettings.ArchiveEngineChoice {
        get { settings.archiveEngine }
        set { settings.archiveEngine = newValue }
    }

    var archiveFormat: ArchiveFormat {
        get { settings.archiveFormat }
        set { settings.archiveFormat = newValue }
    }

    var archiveLevel: ArchiveLevel {
        get { settings.archiveLevel }
        set { settings.archiveLevel = newValue }
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
    case general, fileList, folderSizes, navigationPane, mostUsed, archives, trash, privacy
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .fileList: "File List"
        case .folderSizes: "Folder Sizes"
        case .navigationPane: "Navigation Pane"
        case .mostUsed: "Most Used Folders"
        case .archives: "Archives"
        case .trash: "Trash"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .fileList: "list.bullet"
        case .folderSizes: "chart.bar.doc.horizontal"
        case .navigationPane: "sidebar.left"
        case .mostUsed: "clock.arrow.circlepath"
        case .archives: "archivebox"
        case .trash: "trash"
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
                case .mostUsed: MostUsedPane(model: model)
                case .archives: ArchivesPane(model: model)
                case .trash: TrashPane(model: model)
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
        Section {
            Picker("Text size", selection: $model.listTextSize) {
                ForEach(ViewSettings.textSizes, id: \.self) { size in
                    Text(size == ViewSettings.defaultTextSize ? "\(size) pt (default)" : "\(size) pt").tag(size)
                }
            }
            Picker("Row density", selection: $model.listDensity) {
                ForEach(ViewSettings.Density.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Size")
        } footer: {
            Footnote("Also View ▸ Make Text Bigger (⌘+), Make Text Smaller (⌘−) and Actual Size (⌘0), or ⌘-scroll over the "
                     + "list. Rows and icons grow with the text; Compact and Comfortable change the space around it.")
        }
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

private struct MostUsedPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Picker("Show", selection: $model.usageTopCount) {
                ForEach(Self.withCurrent(ViewSettings.usageTopCounts, model.usageTopCount), id: \.self) { Text("\($0) folders").tag($0) }
            }
        } header: {
            Text("Menu")
        } footer: {
            Footnote("The ⌄ button after the tabs’ + (and Go ▸ Most Used Folders) lists them; choosing one opens it in a new tab.")
        }
        Section {
            Picker("Opening a folder", selection: $model.usageOpenWeight) {
                ForEach(ViewSettings.Importance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Switching to a tab", selection: $model.usageTabWeight) {
                ForEach(ViewSettings.Importance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Count a folder once it has been open for", selection: $model.usageDwell) {
                ForEach(Self.withCurrent(ViewSettings.usageDwellChoices, model.usageDwell), id: \.self) { seconds in
                    Text(seconds == 1 ? "1 second" : "\(seconds) seconds").tag(seconds)
                }
            }
        } header: {
            Text("What Counts")
        } footer: {
            Footnote("Each use adds its importance to the folder’s score; the highest scores come first. Passing through "
                     + "folders quickly doesn’t count. Scores fade by half every 30 days, so folders you no longer use drift down.")
        }
        Section {
            LabeledContent(model.rememberedFolders == 1 ? "1 folder remembered" : "\(model.rememberedFolders) folders remembered") {
                Button("Reset Most Used Folders…") { model.confirmingMostUsedReset = true }
                    .disabled(model.rememberedFolders == 0)
            }
        }
        .confirmationDialog("Forget the most used folders?", isPresented: $model.confirmingMostUsedReset) {
            Button("Reset", role: .destructive) { model.resetMostUsed() }
        } message: {
            Text("The menu starts empty and fills again as you use folders. No files or folders are changed.")
        }
    }

    /// The choices, plus the current value if it was set to something else.
    private static func withCurrent(_ choices: [Int], _ current: Int) -> [Int] {
        choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

private struct ArchivesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Open archives as folders", isOn: $model.openArchivesAsFolders)
        } header: {
            Text("Browse")
        } footer: {
            Footnote("Double-click a zip, 7z or tar archive to look inside it like a folder (read-only). Opening a file inside "
                     + "extracts just that file to a temporary folder; copying items out extracts them. Off: archives open in "
                     + "the app set for them.")
        }
        Section {
            Picker("Format", selection: $model.archiveFormat) {
                ForEach(ArchiveFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Compression", selection: $model.archiveLevel) {
                Text("Fast").tag(ArchiveLevel.fast)
                Text("Normal").tag(ArchiveLevel.normal)
                Text("Maximum").tag(ArchiveLevel.maximum)
            }
        } header: {
            Text("Compress")
        } footer: {
            Footnote("7z makes smaller archives; zip opens on any computer without extra software. Maximum can take "
                     + "several times longer than Normal for slightly smaller archives. Archives keep names, folders, dates "
                     + "and symlinks, but not Finder tags or other macOS-only metadata.")
        }
        Section {
            Picker("Compress and extract with", selection: $model.archiveEngine) {
                ForEach(ViewSettings.ArchiveEngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Engine")
        } footer: {
            Footnote("7-Zip uses every processor core and reads the most formats. macOS’s own libarchive compresses on one "
                     + "core. If one engine can’t open an archive, Kansio tries the other. Password-protected archives aren’t "
                     + "supported yet.")
        }
    }
}

private struct TrashPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Keep a Trash folder on network volumes", isOn: $model.networkTrashFolders)
        } header: {
            Text("Network Volumes")
        } footer: {
            Footnote("Network volumes have no Trash. Normally Kansio asks, then deletes items there immediately, like Finder. "
                     + "With this on, they go to a .Trashes folder at the top of the network volume instead: Kansio’s Trash shows "
                     + "them and can put them back. Others using the volume can see that folder, and it uses space on the server "
                     + "until the Trash is emptied.")
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
