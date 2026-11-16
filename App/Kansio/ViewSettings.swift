import Foundation
import FileSystemKit

/// The one global view setting (Explorer-style). Stored in the app's UserDefaults,
/// never in the folders themselves (no `.DS_Store`).
@MainActor
final class ViewSettings {
    static let shared = ViewSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let sort = "view.sort"
        static let showHidden = "view.showHidden"
    }

    var sort: FileSort {
        didSet { defaults.set(try? JSONEncoder().encode(sort), forKey: Key.sort) }
    }

    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: Key.showHidden) }
    }

    private init() {
        sort = defaults.data(forKey: Key.sort).flatMap { try? JSONDecoder().decode(FileSort.self, from: $0) } ?? .default
        showHidden = defaults.bool(forKey: Key.showHidden)
    }
}
