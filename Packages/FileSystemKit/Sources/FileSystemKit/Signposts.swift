import os

/// `os_signpost` intervals, visible in Instruments ("Points of Interest" / os_signpost).
public enum Signposts {
    public static let listing = OSSignposter(subsystem: "dev.kansio.FileSystemKit", category: "Listing")
    public static let sorting = OSSignposter(subsystem: "dev.kansio.FileSystemKit", category: "Sorting")
    public static let fileOps = OSSignposter(subsystem: "dev.kansio.FileSystemKit", category: "FileOperations")
}
