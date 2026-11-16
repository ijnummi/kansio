import Foundation

/// Rules for names typed by the user (rename, new folder).
public enum FileNames {
    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case containsSlash
        case reserved          // "." or ".."
        case tooLong           // > 255 UTF-8 bytes (APFS/HFS+ limit)

        public var description: String {
            switch self {
            case .empty: "A name can’t be empty."
            case .containsSlash: "A name can’t contain “/”."
            case .reserved: "“.” and “..” are reserved names."
            case .tooLong: "That name is too long (255 bytes at most)."
            }
        }
    }

    /// Validates a user-typed name. Leading/trailing whitespace is allowed (it's legal and
    /// sometimes intended), but a name made only of whitespace counts as empty.
    public static func validate(_ name: String) -> Problem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if name.contains("/") { return .containsSlash }
        if name == "." || name == ".." { return .reserved }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }

    /// Explorer-style numbering: "New folder", "New folder (2)", "New folder (3)"…;
    /// for files the number goes before the extension: "Notes (2).txt".
    public static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        // A leading-dot name (".env") has no extension for this purpose.
        if ext.isEmpty || name.hasPrefix(".") && ns.deletingPathExtension.isEmpty {
            return "\(name) (\(n))"
        }
        return "\(ns.deletingPathExtension) (\(n)).\(ext)"
    }

    /// The part of `name` selected when inline rename starts: everything before the last
    /// extension (Explorer/Finder), or the whole name for folders and dot-names.
    public static func editableRange(of name: String, isFolder: Bool) -> NSRange {
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard !isFolder, !name.hasPrefix(".") || ns.deletingPathExtension.count > 1 else { return full }
        let base = ns.deletingPathExtension as NSString
        guard base.length > 0, base.length < ns.length else { return full }
        return NSRange(location: 0, length: base.length)
    }
}
