import AppKit
import FileSystemKit
import Synchronization

/// P2-3: the archive engines as Settings ▸ Archives chooses them, and the quick look into an archive that decides
/// whether "Extract as" is offered (not for an archive whose only top-level item is a folder).
@MainActor
final class ArchiveService {
    static let shared = ArchiveService()

    /// The bundled 7-Zip (`Contents/MacOS/7zz`); `KANSIO_7ZZ` overrides (e.g. `swift run` without a bundle).
    let sevenZipURL: URL? = {
        if let env = ProcessInfo.processInfo.environment["KANSIO_7ZZ"], FileManager.default.isExecutableFile(atPath: env) {
            return URL(filePath: env)
        }
        return Bundle.main.url(forAuxiliaryExecutable: "7zz")
    }()

    /// The chosen engine first, the other as the fallback (missing ones left out).
    var engines: [any ArchiveEngine] {
        let sevenZip: (any ArchiveEngine)? = sevenZipURL.map { SevenZipEngine(executable: $0) }
        let system: (any ArchiveEngine)? = LibArchiveEngine.isAvailable ? LibArchiveEngine() : nil
        let ordered = ViewSettings.shared.archiveEngine == .sevenZip ? [sevenZip, system] : [system, sevenZip]
        return ordered.compactMap { $0 }
    }

    func operations(trasher: any Trasher, resolver: @escaping CopyEngine.Resolver = CopyEngine.skipConflicts) -> ArchiveOperations {
        ArchiveOperations(engines: engines, trasher: trasher, resolver: resolver)
    }

    // MARK: Peek

    private let peeks = PeekCache()

    /// Starts reading `url`'s listing in the background (when the selection becomes this archive), so the context
    /// menu usually has the answer before it opens. tar formats aren't read (they'd be decompressed in full).
    func prefetch(_ url: URL, size: Int64, modified: Date) {
        guard !ArchiveNames.isStreamed(url.lastPathComponent) else { return }
        let key = PeekCache.Key(path: url.path(percentEncoded: false), size: size, modified: modified)
        let operations = self.operations(trasher: TrashService.shared.trasher)
        peeks.start(key) {
            guard let entries = try? operations.listWithFallback(url, cancel: CancellationFlag()) else { return nil }
            let layout = ArchiveLayout(entries)
            return !layout.isEncrypted && layout.singleTopFolder != nil
        }
    }

    /// True if the archive's only top-level item is a folder; nil if unknown (a tar format, unreadable, or not
    /// known within `wait` — the menu then offers both). Waits on the main thread only while a peek is running.
    func isSingleFolder(_ url: URL, size: Int64, modified: Date, wait: Duration = .milliseconds(100)) -> Bool? {
        guard !ArchiveNames.isStreamed(url.lastPathComponent) else { return nil }
        let key = PeekCache.Key(path: url.path(percentEncoded: false), size: size, modified: modified)
        if !peeks.isKnownOrRunning(key) { prefetch(url, size: size, modified: modified) }
        return peeks.result(key, wait: wait)
    }
}

/// Peek results by archive (path, size, date: a changed archive is read again). Thread-safe.
final class PeekCache: Sendable {
    struct Key: Hashable, Sendable {
        var path: String
        var size: Int64
        var modified: Date
    }

    private enum State {
        case running(DispatchGroup)
        case done(Bool?)
    }

    private let states = Mutex<[Key: State]>([:])
    private static let queue = DispatchQueue(label: "kansio.archive-peek", qos: .userInitiated, attributes: .concurrent)

    func isKnownOrRunning(_ key: Key) -> Bool { states.withLock { $0[key] != nil } }

    func start(_ key: Key, _ work: @escaping @Sendable () -> Bool?) {
        let group = DispatchGroup()
        let started: Bool = states.withLock { states in
            guard states[key] == nil else { return false }
            if states.count > 200 { states.removeAll() } // a small cache: selections come and go
            states[key] = .running(group)
            return true
        }
        guard started else { return }
        group.enter()
        Self.queue.async { [self] in
            let result = work()
            states.withLock { $0[key] = .done(result) }
            group.leave()
        }
    }

    func result(_ key: Key, wait: Duration) -> Bool? {
        let state = states.withLock { $0[key] }
        switch state {
        case .done(let result): return result
        case .running(let group):
            let ms = Int(wait.components.seconds * 1000 + wait.components.attoseconds / 1_000_000_000_000_000)
            guard group.wait(timeout: .now() + .milliseconds(ms)) == .success else { return nil }
            if case .done(let result) = states.withLock({ $0[key] }) { return result }
            return nil
        case nil: return nil
        }
    }
}
