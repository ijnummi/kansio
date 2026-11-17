import Darwin
import Synchronization

/// `renamex_np(RENAME_EXCL)` — a rename that never replaces an existing item — with a fallback for volumes that
/// don't support the flag.
///
/// SMB shares (smbfs) and some other network/FUSE file systems don't advertise `VOL_CAP_INT_RENAME_EXCL`, and the
/// call fails with ENOTSUP ("Operation not supported"). There the fallback checks that the target is free and then
/// does a plain `rename(2)`. Between the check and the rename another client of the share could create the same name,
/// which the rename would then replace; Finder has the same window on SMB. On local volumes the atomic flag is used.
public enum ExclusiveRename {
    /// Renames `from` to `to` unless something exists at `to`. Returns 0 on success, else the errno (EEXIST when the
    /// target is taken, EXDEV across volumes, …).
    public static func rename(_ from: String, _ to: String) -> Int32 {
        if !simulatesUnsupported(from) && !simulatesUnsupported(to) {
            if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
            let err = errno
            guard err == ENOTSUP else { return err }
        }
        var st = stat()
        if lstat(from, &st) != 0 { return errno } // report a missing source as rename would
        if lstat(to, &st) == 0 { return EEXIST }
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }

    // MARK: Testing

    private static let unsupported = Mutex<[String]>([])

    /// Tests and the self-test: renames from or into `folder` behave as on an SMB share (RENAME_EXCL unsupported).
    public static func simulateUnsupported(under folder: String) {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        unsupported.withLock { $0.append(prefix) }
    }

    public static func stopSimulating(under folder: String) {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        unsupported.withLock { $0.removeAll { $0 == prefix } }
    }

    private static func simulatesUnsupported(_ path: String) -> Bool {
        unsupported.withLock { prefixes in prefixes.contains { path.hasPrefix($0) } }
    }
}
