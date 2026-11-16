import Darwin
import Foundation
import Testing

/// A unique scratch directory under the system temp dir, removed when released.
/// Tests must only ever create/modify files inside one of these.
final class TempDir {
    let url: URL

    init(_ label: String = #function) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kansio-tests", directoryHint: .isDirectory)
        let safeLabel = label.filter { $0.isLetter || $0.isNumber }
        url = root.appending(path: "\(safeLabel)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Safety: only ever remove our own scratch directory inside the temp dir.
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let mine = url.resolvingSymlinksInPath().path
        precondition(mine.hasPrefix(temp + "/") && mine.contains("/kansio-tests/"), "refusing to delete \(mine)")
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    @discardableResult
    func file(_ name: String, bytes: Int = 0) throws -> URL {
        let u = url.appending(path: name, directoryHint: .notDirectory)
        try Data(repeating: 0x61, count: bytes).write(to: u)
        return u
    }

    @discardableResult
    func dir(_ name: String) throws -> URL {
        let u = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func symlink(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.appending(path: name).path(percentEncoded: false),
                                                   withDestinationPath: destination)
    }
}
