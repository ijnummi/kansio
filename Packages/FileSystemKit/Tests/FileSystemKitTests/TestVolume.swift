import Foundation

/// A small APFS disk image mounted for the duration of a test — a second volume for
/// trash and cross-volume tests that never touches the user's real volumes or Trash.
final class TestVolume {
    let image: URL
    let mountPoint: URL

    init(name: String = "KansioTest\(UInt32.random(in: 0...UInt32.max))", sizeMB: Int = 16) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kansio-tests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        image = dir.appending(path: "\(name).dmg")
        mountPoint = dir.appending(path: "mnt-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeMB)m", "-fs", "APFS", "-volname", name, image.path])
        try Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
    }

    deinit {
        _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: mountPoint)
    }

    var url: URL { mountPoint }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TestVolume", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) \(args) failed"])
        }
        return p.terminationStatus
    }
}
