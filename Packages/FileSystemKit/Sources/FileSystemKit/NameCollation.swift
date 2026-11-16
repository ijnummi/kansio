import CoreFoundation
import Foundation

/// Finder-compatible name ordering.
///
/// `localizedStandardCompare` is documented as `compare(_:options:[.caseInsensitive,
/// .numeric, .widthInsensitive, .forcedOrdering], locale: .current)`. We call the
/// CoreFoundation equivalent directly on native `CFString`s, which is ~1.6× faster
/// than going through bridged Swift strings.
///
/// Not parallelized on purpose: CF serializes locale-aware comparisons behind a
/// process-wide collator lock, so extra threads only add contention (measured: 12
/// threads ≈ 1 thread). See PERF.md for numbers and the ICU sort-key alternative.
public enum NameCollation {
    static let flags: CFStringCompareFlags = [
        .compareCaseInsensitive, .compareNumerically, .compareWidthInsensitive, .compareForcedOrdering,
    ]

    /// Exact `localizedStandardCompare` semantics, usable for single comparisons (inserts, tests).
    public static func compare(_ a: String, _ b: String, locale: Locale = .current) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering],
                  range: nil, locale: locale)
    }

    /// Returns `rank` where `rank[i]` is the position of `names[i]` in localized standard order.
    /// Names that compare equal (only possible on case-sensitive volumes) keep input order.
    public static func ranks(of names: [String], locale: Locale = .current) -> [UInt32] {
        let order = sortedIndices(of: names, locale: locale)
        var rank = [UInt32](repeating: 0, count: names.count)
        for (position, index) in order.enumerated() { rank[Int(index)] = UInt32(position) }
        return rank
    }

    /// Indices of `names` in localized standard order.
    public static func sortedIndices(of names: [String], locale: Locale = .current) -> [UInt32] {
        let n = names.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        let state = Signposts.sorting.beginInterval("Name collation", "\(n) names")
        defer { Signposts.sorting.endInterval("Name collation", state) }

        let cfLocale = locale as CFLocale
        let strings: [CFString] = names.map { name in
            var name = name
            return name.withUTF8 { utf8 in
                CFStringCreateWithBytes(nil, utf8.baseAddress, utf8.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
            } ?? ("" as CFString)
        }
        var indices = (0..<UInt32(n)).map { $0 }
        strings.withUnsafeBufferPointer { strs in
            indices.sort { x, y in
                let sx = strs[Int(x)]
                let r = CFStringCompareWithOptionsAndLocale(
                    sx, strs[Int(y)], CFRange(location: 0, length: CFStringGetLength(sx)), flags, cfLocale)
                return r == .compareLessThan || (r == .compareEqualTo && x < y)
            }
        }
        return indices
    }
}
