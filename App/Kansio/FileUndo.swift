import AppKit
import FileSystemKit

extension Notification.Name {
    /// Posted (main thread) after Kansio changed items on disk; `userInfo["urls"]` = [URL].
    /// Views showing those folders update just those items. (Changes made by other apps arrive
    /// with live updates, M13.)
    static let kansioFilesChanged = Notification.Name("KansioFilesChanged")
}

/// App-wide Undo for file operations (like Finder/Explorer: one history, not per window).
///
/// UndoManager needs the redo action registered *while* the undo runs, synchronously, but file
/// work is async. So the same `UndoStep` is registered in both directions immediately and the
/// actual work is queued on `UndoPerformer` (serial: a redo never overtakes its undo). Trash
/// locations learned along the way go into the step's `TrashSlot`s.
@MainActor
final class FileUndo {
    static let shared = FileUndo()

    let manager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        manager.groupsByEvent = false // one registration = one undoable action
        return manager
    }()
    private let performer = UndoPerformer()
    /// The list that reports undo problems (the frontmost window's).
    var reporter: () -> FileListViewController? = {
        (NSApp.keyWindow?.windowController as? MainWindowController)?.fileList
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)?.fileList
    }

    /// Registers a finished operation so Edit ▸ Undo reverses it.
    func register(_ step: UndoStep, trasher: any Trasher) {
        guard !step.changes.isEmpty else { return }
        registerUndo(step, trasher: trasher)
    }

    private func registerUndo(_ step: UndoStep, trasher: any Trasher) {
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerRedo(step, trasher: trasher)
                target.run(step.inverse, trasher: trasher, verb: "undo")
            }
        }
        manager.setActionName(step.actionName)
        manager.endUndoGrouping()
    }

    private func registerRedo(_ step: UndoStep, trasher: any Trasher) {
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerUndo(step, trasher: trasher)
                target.run(step, trasher: trasher, verb: "redo")
            }
        }
        manager.setActionName(step.actionName)
    }

    private func run(_ step: UndoStep, trasher: any Trasher, verb: String) {
        let performer = self.performer
        Task {
            let errors = await performer.perform(step, trasher: trasher)
            NotificationCenter.default.post(name: .kansioFilesChanged, object: nil, userInfo: ["urls": step.affectedURLs])
            if let first = errors.first {
                let more = errors.count > 1 ? " (+\(errors.count - 1) more)" : ""
                reporter()?.showMessage("Couldn’t \(verb) \(step.actionName.lowercased()) for “\(first.url.lastPathComponent)”: \(first.error.reason)\(more).")
            }
            finished?(errors)
        }
    }

    /// Self-test hook: called after each undo/redo finished.
    var finished: (([(url: URL, error: FileSystemError)]) -> Void)?
}
