import Darwin
import Foundation
import Synchronization

/// The archive engine that runs 7-Zip's command-line program `7zz` (bundled in Kansio.app, built from source by
/// `Tools/fetch-7zip.sh`). Multi-threaded, reads nearly every format.
///
/// Switches used everywhere: `-spd` (names are literal, never wildcards), `-sccUTF-8`/`-scsUTF-8` (console and list
/// files in UTF-8), `-snl` (symlinks stored and extracted as links; 7-Zip refuses links that point outside), and a dummy
/// password so an encrypted archive fails at once instead of waiting for one on stdin.
public struct SevenZipEngine: ArchiveEngine {
    public let executable: URL
    public var name: String { "7-Zip" }

    public init(executable: URL) { self.executable = executable }

    static let noPassword = "-p-kansio-no-password-"

    public func list(_ archive: URL, cancel: CancellationFlag) throws(FileSystemError) -> [ArchiveEntry] {
        let path = archive.path(percentEncoded: false)
        let run = ArchiveProcess.run(executable, ["l", "-slt", "-ba", "-sccUTF-8", Self.noPassword, path], cancel: cancel)
        if run.cancelled { throw archiveCancelled }
        let text = String(decoding: run.stdout, as: UTF8.self)
        if run.status != 0 || run.stderr.contains("ERROR") || text.contains("ERROR:") {
            throw Self.error(run.stderr + text, path: path)
        }
        return Self.parseListing(text)
    }

    /// `7zz l -slt -ba` output: one "Key = value" block per entry, blocks separated by blank lines.
    static func parseListing(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [Substring: Substring] = [:]
        func flush() {
            defer { fields.removeAll(keepingCapacity: true) }
            guard let path = fields["Path"] else { return }
            let attributes = fields["Attributes"] ?? ""
            let unixMode = attributes.split(separator: " ").last ?? ""
            let isFolder = fields["Folder"] == "+" || attributes.split(separator: " ").first?.contains("D") == true
                || unixMode.hasPrefix("d")
            entries.append(ArchiveEntry(path: String(path), isFolder: isFolder, isSymlink: unixMode.hasPrefix("l"),
                                        size: Int64(fields["Size"] ?? "") ?? 0, isEncrypted: fields["Encrypted"] == "+"))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            guard let range = line.range(of: " = ") else {
                if line.hasSuffix(" =") { fields[line.dropLast(2)] = "" }
                continue
            }
            let key = line[..<range.lowerBound]
            if key == "Path", fields["Path"] != nil { flush() } // no blank line between entries
            fields[key] = line[range.upperBound...]
        }
        flush()
        return entries
    }

    public func create(_ archive: URL, base: URL, items: [String], format: ArchiveFormat, level: ArchiveLevel,
                       cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        let path = archive.path(percentEncoded: false)
        // The names go in a UTF-8 list file (no argument-length limit, no switch parsing); never in a browsed folder.
        let listFile = FileManager.default.temporaryDirectory.appending(path: "kansio-7z-list-\(UUID().uuidString).txt")
        do {
            try (items.joined(separator: "\n") + "\n").write(to: listFile, atomically: false, encoding: .utf8)
        } catch {
            throw FileSystemError(foundation: error, path: listFile.path(percentEncoded: false))
        }
        defer { try? FileManager.default.removeItem(at: listFile) }
        var args = ["a", "-t\(format == .sevenZip ? "7z" : "zip")", "-mx=\(level.number)", "-snl", "-spd", "-sse",
                    "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-scsUTF-8"]
        if format == .zip { args.append("-mcu=on") } // UTF-8 names (Windows and Finder read them correctly)
        args += [path, "@" + listFile.path(percentEncoded: false)]
        let run = ArchiveProcess.run(executable, args, cwd: base, cancel: cancel, progress: progress)
        if run.cancelled { throw archiveCancelled }
        if run.status != 0 { throw Self.error(run.stderr, path: path) }
    }

    public func extract(_ archive: URL, into folder: URL, cancel: CancellationFlag,
                        progress: @escaping @Sendable (Double) -> Void) throws(FileSystemError) {
        let path = archive.path(percentEncoded: false)
        // -aou: two entries with the same name inside one archive both survive ("name_1").
        let args = ["x", "-o" + folder.path(percentEncoded: false), "-aou", "-snl", "-spd", "-bsp1", "-bso0", "-bse2",
                    "-sccUTF-8", Self.noPassword, path]
        let run = ArchiveProcess.run(executable, args, cancel: cancel, progress: progress)
        if run.cancelled { throw archiveCancelled }
        if run.status != 0 { throw Self.error(run.stderr, path: path) }
    }

    /// 7-Zip's message turned into ours (password, unsupported, or its first ERROR line).
    static func error(_ output: String, path: String) -> FileSystemError {
        if output.contains("Wrong password") || output.contains("encrypted") { return ArchiveError.encrypted(path) }
        if output.contains("Cannot open the file as archive") || output.contains("Can not open the file as archive")
            || output.contains("Unsupported") {
            return ArchiveError.unreadable(path, "unsupported or damaged")
        }
        if output.contains("No space left") || output.contains("errno=28") { return FileSystemError(errno: ENOSPC, path: path) }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let detail = lines.first { !$0.hasPrefix("ERROR") && !$0.hasPrefix("ERRORS") && !$0.hasPrefix("7-Zip") }
            ?? lines.first ?? "7-Zip failed"
        return FileSystemError(.other(String(detail.prefix(200))), path: path)
    }
}

/// Runs a helper program: collects stdout/stderr, reports "NN%" progress from stdout, and kills it when cancelled.
enum ArchiveProcess {
    struct Run {
        var status: Int32 = -1
        var stdout = Data()
        var stderr = ""
        var cancelled = false
    }

    static func run(_ executable: URL, _ args: [String], cwd: URL? = nil, cancel: CancellationFlag,
                    progress: (@Sendable (Double) -> Void)? = nil) -> Run {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = Mutex((stdout: Data(), stderr: Data()))
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let progress, let percent = lastPercent(data) {
                progress(Double(percent) / 100)
            } else if progress == nil {
                collected.withLock { $0.stdout.append(data) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.withLock { $0.stderr.append(data) } }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        var result = Run()
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            result.stderr = "Can’t run \(executable.lastPathComponent): \(error.localizedDescription)"
            return result
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if cancel.isCancelled && !result.cancelled {
                result.cancelled = true
                process.terminate() // SIGTERM; 7-Zip removes its own temporary file
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [pid = process.processIdentifier] in
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Whatever arrived after the last callback.
        let restOut = (try? out.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? err.fileHandleForReading.readToEnd()) ?? nil
        collected.withLock {
            if progress == nil, let restOut { $0.stdout.append(restOut) }
            if let restErr { $0.stderr.append(restErr) }
            result.stdout = $0.stdout
            result.stderr = String(decoding: $0.stderr, as: UTF8.self)
        }
        result.status = process.terminationStatus
        if cancel.isCancelled { result.cancelled = true }
        return result
    }

    /// The last "NN%" in a chunk of 7-Zip's progress output.
    static func lastPercent(_ data: Data) -> Int? {
        var last: Int?
        var number = 0, digits = 0
        for byte in data {
            if byte >= 0x30 && byte <= 0x39 {
                number = digits == 0 ? Int(byte - 0x30) : number * 10 + Int(byte - 0x30)
                digits += 1
            } else {
                if byte == 0x25 /* % */ && digits > 0 && digits <= 3 && number <= 100 { last = number }
                digits = 0
            }
        }
        return last
    }
}
