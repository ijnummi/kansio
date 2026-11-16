import Foundation

/// Reference implementation using `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)`.
///
/// Used as the correctness oracle in tests, as the benchmark baseline, and as the
/// fallback for volumes without `getattrlistbulk`. It cannot stream: Foundation
/// returns the whole directory at once, so it delivers a single batch.
public struct FoundationDirectoryLister: DirectoryLister {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey, .isPackageKey,
        .isAliasFileKey, .totalFileSizeKey, .contentModificationDateKey, .creationDateKey,
        .fileIdentifierKey,
    ]
    static let keySet = Set(keys)

    public init() {}

    public func list(_ directory: URL, onBatch: ([FileItem]) -> Bool) throws(FileSystemError) {
        let path = directory.path(percentEncoded: false)
        let state = Signposts.listing.beginInterval("contentsOfDirectory", "\(path, privacy: .private)")
        defer { Signposts.listing.endInterval("contentsOfDirectory", state) }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Self.keys, options: []
            )
        } catch {
            throw FileSystemError(foundation: error, path: path)
        }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            // Values were prefetched by contentsOfDirectory; this doesn't hit the disk again.
            let values = try? url.resourceValues(forKeys: Self.keySet)
            let kind: FileItem.Kind =
                if values?.isSymbolicLink == true { .symlink }
                else if values?.isDirectory == true { .directory }
                else if values?.isRegularFile == true { .file }
                else { .other }
            var flags: FileItem.Flags = []
            if values?.isHidden == true { flags.insert(.hidden) }
            if values?.isPackage == true { flags.insert(.package) }
            // isAliasFile is also true for symlinks; only Finder aliases count as aliases here.
            if values?.isAliasFile == true, kind != .symlink { flags.insert(.alias) }
            items.append(FileItem(
                name: url.lastPathComponent,
                kind: kind,
                flags: flags,
                size: kind == .file ? Int64(values?.totalFileSize ?? 0) : 0,
                modificationDate: values?.contentModificationDate ?? .distantPast,
                creationDate: values?.creationDate ?? .distantPast,
                fileID: values?.fileIdentifier ?? 0
            ))
        }
        _ = onBatch(items)
    }
}
