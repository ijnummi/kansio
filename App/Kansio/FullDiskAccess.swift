import AppKit
import FileSystemKit
import SwiftUI

/// P1-9: Full Disk Access onboarding. macOS protects Desktop, Documents, Downloads, iCloud Drive, other apps'
/// data, removable and network volumes: without Full Disk Access each asks once ("Kansio would like to access…"),
/// some places can't be opened at all, and background folder sizes leave them out. This window explains it and
/// opens the right System Settings pane. It shows once on first launch (when access is missing) and later from
/// Kansio ▸ Full Disk Access…, Settings ▸ Privacy, and every "macOS doesn't allow…" error.
@MainActor
final class FullDiskAccessWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FullDiskAccessWindowController()

    private init() {
        let hosting = NSHostingController(rootView: FullDiskAccessView(model: FullDiskAccessModel.shared))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Full Disk Access"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        FullDiskAccessModel.shared.startWatching()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) { FullDiskAccessModel.shared.stopWatching() }

    /// First launch: show once, after the first folder is on screen, if access is missing.
    static func showOnFirstLaunchIfNeeded(defaults: UserDefaults = ViewSettings.shared.defaults) {
        guard !defaults.bool(forKey: shownKey) else { return }
        Task {
            let granted = await Task.detached(priority: .utility) { Privacy.hasFullDiskAccess() }.value
            guard !granted else { return }
            defaults.set(true, forKey: shownKey)
            shared.show()
        }
    }

    static let shownKey = "onboarding.fullDiskAccessShown"
}

/// Whether Kansio has Full Disk Access, re-checked every second while the window is open (the switch is flipped
/// in System Settings, outside Kansio).
@MainActor
final class FullDiskAccessModel: ObservableObject {
    static let shared = FullDiskAccessModel()

    /// nil until checked.
    @Published private(set) var granted: Bool?
    /// Granted while the window was open: a relaunch makes sure every part of Kansio sees it.
    @Published private(set) var grantedNow = false
    private var watch: Task<Void, Never>?

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func refresh() async {
        let now = await Task.detached(priority: .utility) { Privacy.hasFullDiskAccess() }.value
        if granted == false && now { grantedNow = true }
        if granted != now { granted = now }
    }

    func startWatching() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    func openSystemSettings() { NSWorkspace.shared.open(Self.systemSettingsURL) }

    /// Opens a new instance, then quits this one (which asks first if file operations are running).
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct FullDiskAccessView: View {
    @ObservedObject var model: FullDiskAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let Kansio see every folder").font(.title3.weight(.semibold))
                    Text("macOS protects some places: Desktop, Documents, Downloads, iCloud Drive, other apps’ data, external and network volumes. Without Full Disk Access, Kansio has to ask the first time you open each of them, some folders can’t be opened at all, and folder sizes leave protected folders out.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("To allow it:").font(.headline)
                Text("1. Click **Open System Settings**.")
                Text("2. Turn on **Kansio** in the Full Disk Access list. If it isn’t there, click **+** and choose Kansio.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("3. Quit and reopen Kansio.")
            }
            status
            Text("Kansio works without it, too. You can come back here any time: Kansio ▸ Full Disk Access… or Settings ▸ Privacy.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.granted == true ? "Close" : "Not Now") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.cancelAction)
                if model.grantedNow {
                    Button("Relaunch Kansio") { model.relaunch() }
                        .keyboardShortcut(.defaultAction)
                } else if model.granted != true {
                    Button("Open System Settings") { model.openSystemSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var status: some View {
        switch model.granted {
        case .some(true):
            Label(model.grantedNow ? "Allowed. Relaunch Kansio so every window uses it." : "Kansio has Full Disk Access.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(false):
            Label("Kansio doesn’t have Full Disk Access yet.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case nil:
            Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }
}
