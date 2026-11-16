import CoreFoundation
import Dispatch
import Foundation

/// Finder-compatible name ordering.
///
/// `localizedStandardCompare` is documented as `compare(_:options:[.caseInsensitive,
/// .numeric, .widthInsensitive, .forcedOrdering], locale: .current)`. We call the
/// CoreFoundation equivalent directly on real `CFString`s (not bridged Swift strings,
/// which go through Objective-C dispatch per character access) and sort in parallel.
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

    /// Indices of `names` in localized standard order: parallel chunk sort + parallel pairwise merge.
    public static func sortedIndices(of names: [String], locale: Locale = .current) -> [UInt32] {
        let n = names.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        let state = Signposts.sorting.beginInterval("Name collation", "\(n) names")
        defer { Signposts.sorting.endInterval("Name collation", state) }

        let strings = makeCFStrings(names)
        let comparator = Comparator(strings: strings, locale: locale as CFLocale)

        let chunkCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 4096))
        var bounds = (0...chunkCount).map { $0 * n / chunkCount }

        let a = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        let b = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        defer { a.deallocate(); b.deallocate() }
        for i in 0..<n { a[i] = UInt32(i) }

        let sortBounds = bounds
        let aBox = Box(a)
        DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
            let lo = sortBounds[c], hi = sortBounds[c + 1]
            var chunk = UnsafeMutableBufferPointer(start: aBox.value + lo, count: hi - lo)
            chunk.sort(by: comparator.less)
        }

        var src = a, dst = b
        while bounds.count > 2 {
            let current = bounds
            let last = current.count - 1
            let srcBox = Box(src), dstBox = Box(dst)
            DispatchQueue.concurrentPerform(iterations: (last + 1) / 2) { p in
                let s = srcBox.value, d = dstBox.value
                let lo = current[2 * p]
                let mid = current[min(2 * p + 1, last)]
                let hi = current[min(2 * p + 2, last)]
                var i = lo, j = mid, k = lo
                while i < mid && j < hi {
                    if comparator.less(s[j], s[i]) { d[k] = s[j]; j += 1 } else { d[k] = s[i]; i += 1 }
                    k += 1
                }
                while i < mid { d[k] = s[i]; i += 1; k += 1 }
                while j < hi { d[k] = s[j]; j += 1; k += 1 }
            }
            bounds = stride(from: 0, to: current.count, by: 2).map { current[$0] }
            if bounds.last != n { bounds.append(n) }
            swap(&src, &dst)
        }
        return Array(UnsafeBufferPointer(start: src, count: n))
    }

    /// Immutable CFStrings + locale; CF immutable objects are thread-safe to read.
    private struct Comparator: @unchecked Sendable {
        let strings: [CFString]
        let locale: CFLocale

        @inline(__always)
        func less(_ x: UInt32, _ y: UInt32) -> Bool {
            let sx = strings[Int(x)]
            let r = CFStringCompareWithOptionsAndLocale(
                sx, strings[Int(y)], CFRange(location: 0, length: CFStringGetLength(sx)), NameCollation.flags, locale)
            return r == .compareLessThan || (r == .compareEqualTo && x < y)
        }
    }

    /// A pointer handed to `concurrentPerform` workers, each of which touches a disjoint range.
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Builds native CFStrings (fast for collation), in parallel.
    private static func makeCFStrings(_ names: [String]) -> [CFString] {
        let n = names.count
        let out = UnsafeMutablePointer<CFString?>.allocate(capacity: n)
        out.initialize(repeating: nil, count: n)
        defer { out.deinitialize(count: n); out.deallocate() }
        let outBox = Box(out)
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 8192))
        names.withUnsafeBufferPointer { input in
            let inBox = Box(input)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                for i in (c * n / chunks)..<((c + 1) * n / chunks) {
                    var name = inBox.value[i]
                    outBox.value[i] = name.withUTF8 { utf8 in
                        CFStringCreateWithBytes(nil, utf8.baseAddress, utf8.count,
                                                CFStringBuiltInEncodings.UTF8.rawValue, false)
                    }
                }
            }
        }
        return (0..<n).map { out[$0] ?? ("" as CFString) }
    }
}
