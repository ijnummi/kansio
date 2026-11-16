import Foundation
import Synchronization
import UniformTypeIdentifiers

/// The "Type" column: a localized kind description like Finder's Kind / Explorer's Type
/// ("PDF document", "Folder", "Application"). Looked up once per extension via UTType and
/// cached, so showing it costs a dictionary lookup per visible cell.
public enum FileKind {
    private static let cache = Mutex<[String: String]>([:])

    public static func description(for item: FileItem) -> String {
        switch item.kind {
        case .directory where !item.isPackage:
            return folder
        case .symlink:
            return alias
        case .other:
            return other
        default:
            break
        }
        if item.flags.contains(.alias) { return alias }
        let ext = item.pathExtension
        let isPackage = item.kind == .directory
        let key = isPackage ? "/" + ext : ext // packages and files with the same extension differ
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let value = lookup(ext: ext, isPackage: isPackage)
        cache.withLock { $0[key] = value }
        return value
    }

    static let folder = UTType.folder.localizedDescription ?? "Folder"
    static let alias = UTType.aliasFile.localizedDescription ?? "Alias"
    static let other = "Special File"

    private static func lookup(ext: String, isPackage: Bool) -> String {
        if ext.isEmpty {
            return isPackage ? (UTType.package.localizedDescription ?? "Package") : "Document"
        }
        let conformance: UTType = isPackage ? .package : .data
        if let type = UTType(filenameExtension: ext, conformingTo: conformance), !type.isDynamic,
           let description = type.localizedDescription {
            return description
        }
        return "\(ext.uppercased()) file" // unknown extension, Explorer style
    }
}
