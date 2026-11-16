import Darwin
import Foundation

/// macOS privacy (TCC) facts Kansio needs without ever raising a prompt.
public enum Privacy {
    /// Whether Kansio has Full Disk Access: the TCC database itself is readable only with it, and trying
    /// to open it never prompts (EPERM without access). Blocking but fast; call off the main thread.
    /// A grant usually takes effect only after relaunching the app.
    public static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool {
        let fd = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Folders whose contents belong to other apps (macOS 14+ asks "… would like to access data from other
    /// apps" on first access): automatic work like folder sizes doesn't descend into them without Full Disk Access.
    public static func otherAppsData(home: String = NSHomeDirectory()) -> Set<String> {
        let home = FolderTree.normalized(home)
        return [home + "/Library/Containers", home + "/Library/Group Containers"]
    }
}
