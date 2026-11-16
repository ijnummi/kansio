import AppKit
import FileSystemKit

/// Asks the user what to do when a copy/move meets an existing item — a sheet on the window
/// (a decision, not an error, so not an inline message). Questions are shown one at a time;
/// several operations can wait in line.
///
/// Files: Replace (default, the old item goes to the Trash) / Keep Both / Skip / Stop.
/// Two folders: Merge (default, clashes inside are asked about one by one) / Keep Both / Skip /
/// Replace / Stop. "Apply to all remaining conflicts" is handled by `ConflictPolicy`.
@MainActor
final class ConflictPrompter {
    typealias Answer = (resolution: ConflictResolution, applyToAll: Bool)

    weak var window: NSWindow?
    /// The alert on screen right now (self-test drives it).
    private(set) var currentAlert: NSAlert?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var busy = false

    init(window: NSWindow?) { self.window = window }

    /// For `ConflictPolicy(ask:)`.
    nonisolated func ask(_ conflict: Conflict) async -> Answer {
        let details = await Self.details(of: conflict)
        return await present(conflict, details: details)
    }

    private func present(_ conflict: Conflict, details: (new: String, existing: String)) async -> Answer {
        // One sheet at a time.
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        guard let window else { return (.skip, false) }

        let folders = conflict.sourceIsFolder && conflict.existingIsFolder
        let name = conflict.existing.lastPathComponent
        let place = conflict.existing.deletingLastPathComponent().lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = folders
            ? "A folder named “\(name)” already exists in “\(place)”."
            : "An item named “\(name)” already exists in “\(place)”."
        alert.informativeText = (folders
            ? "Merge puts the contents into the existing folder; if files inside have the same names, you’ll be asked about each.\n\n"
            : "Replace moves the existing item to the Trash.\n\n")
            + "Existing: \(details.existing)\nNew: \(details.new)"
        let buttons: [(String, ConflictResolution)] = folders
            ? [("Merge", .merge), ("Keep Both", .keepBoth), ("Skip", .skip), ("Replace", .replace), ("Stop", .stop)]
            : [("Replace", .replace), ("Keep Both", .keepBoth), ("Skip", .skip), ("Stop", .stop)]
        for (title, _) in buttons { alert.addButton(withTitle: title) }
        alert.buttons.last?.keyEquivalent = "\u{1b}" // Esc = Stop
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do this for all remaining conflicts"
        alert.suppressionButton?.state = .off

        currentAlert = alert
        defer { currentAlert = nil }
        let response = await alert.beginSheetModal(for: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let resolution = buttons.indices.contains(index) ? buttons[index].1 : .stop
        return (resolution, alert.suppressionButton?.state == .on)
    }

    /// "12 KB, modified 16.11.2026 12.31" for both items (read off-main).
    nonisolated private static func details(of conflict: Conflict) async -> (new: String, existing: String) {
        await Task.detached {
            func describe(_ url: URL) -> String {
                guard let item = try? BulkDirectoryLister.readItem(at: url) else { return "—" }
                let size = item.kind == .directory ? FileKind.description(for: item)
                    : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
                let date = DateFormatter.localizedString(from: item.modificationDate, dateStyle: .short, timeStyle: .short)
                return "\(size), modified \(date)"
            }
            return (describe(conflict.source), describe(conflict.existing))
        }.value
    }

    /// Self-test: answers the sheet on screen as if the user clicked `title`.
    func answer(_ title: String, applyToAll: Bool = false) -> Bool {
        guard let alert = currentAlert, let button = alert.buttons.first(where: { $0.title == title }) else { return false }
        alert.suppressionButton?.state = applyToAll ? .on : .off
        button.performClick(nil)
        return true
    }
}
