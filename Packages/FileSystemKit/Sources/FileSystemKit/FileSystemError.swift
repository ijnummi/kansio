import Foundation

/// Errors surfaced to the UI. Always carries the path so messages can be shown inline.
public struct FileSystemError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: Sendable, Equatable {
        case notFound
        case permissionDenied
        case notADirectory
        case timedOut
        case posix(Int32)
        case other(String)
    }

    public var code: Code
    public var path: String
    /// The errno behind it, when there was one.
    public var posixCode: Int32?

    public init(_ code: Code, path: String) {
        self.code = code
        self.path = path
    }

    /// Same error = same code and path (the errno is detail).
    public static func == (a: FileSystemError, b: FileSystemError) -> Bool { a.code == b.code && a.path == b.path }

    /// macOS privacy protection said no (EPERM: Desktop, Documents, another app's data … without a grant), as
    /// opposed to the folder's own permissions (EACCES). Full Disk Access or Privacy settings fix it.
    public var isPrivacyDenied: Bool { code == .permissionDenied && posixCode == EPERM }

    public init(errno err: Int32, path: String) {
        let code: Code = switch err {
        case ENOENT: .notFound
        case EACCES, EPERM: .permissionDenied
        case ENOTDIR: .notADirectory
        case ETIMEDOUT: .timedOut
        default: .posix(err)
        }
        self.init(code, path: path)
        posixCode = err
    }

    init(foundation error: any Error, path: String) {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(ns.code), path: path)
        } else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(underlying.code), path: path)
        } else if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: self.init(.notFound, path: path)
            case NSFileReadNoPermissionError: self.init(.permissionDenied, path: path)
            default: self.init(.other(ns.localizedDescription), path: path)
            }
        } else {
            self.init(.other(ns.localizedDescription), path: path)
        }
    }

    /// The reason alone, without the path ("Permission denied") — for places that already name the item.
    public var reason: String {
        switch code {
        case .notFound: "It no longer exists"
        case .permissionDenied: "Permission denied"
        case .notADirectory: "Not a folder"
        case .timedOut: "Timed out"
        case .posix(let e): String(cString: strerror(e))
        case .other(let message): message
        }
    }

    public var description: String {
        switch code {
        case .notFound: "No such file or folder: \(path)"
        case .permissionDenied: "Permission denied: \(path)"
        case .notADirectory: "Not a folder: \(path)"
        case .timedOut: "Timed out: \(path)"
        case .posix(let e): "\(String(cString: strerror(e))): \(path)"
        case .other(let message): "\(message): \(path)"
        }
    }
}
