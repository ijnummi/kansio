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

    /// Folders macOS guards with a privacy prompt on first access (Desktop, Documents, Downloads; other apps'
    /// data, macOS 14+; iCloud Drive and cloud-storage providers). A prompt also *blocks* the call that raised it
    /// until it's answered, so background work must never be the first to touch them.
    public static func protectedFolders(home: String = NSHomeDirectory()) -> [String] {
        let home = FolderTree.normalized(home)
        return ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers",
                "Library/Mobile Documents", "Library/CloudStorage",
                // Media libraries (the TV app's blocks even `find` from a terminal).
                "Movies/TV", "Music/Music", "Pictures/Photos Library.photoslibrary"].map { home + "/" + $0 }
    }

    /// What automatic work (folder sizes) must not enter while browsing `realPath`: nothing with Full Disk
    /// Access; otherwise every protected folder except one being browsed (its listing worked, so access was
    /// already granted). Blocking (checks Full Disk Access); call off the main thread.
    public static func automaticSkips(browsing realPath: String, home: String = NSHomeDirectory()) -> Set<String> {
        if hasFullDiskAccess(home: home) { return [] }
        let path = FolderTree.normalized(realPath)
        return Set(protectedFolders(home: home).filter { path != $0 && !path.hasPrefix($0 + "/") })
    }
}
