import CoreFoundation
import Dispatch
import Foundation

/// Finder-compatible name ordering.
///
/// `localizedStandardCompare` is documented as `compare(_:options:[.caseInsensitive,
/// .numeric, .widthInsensitive, .forcedOrdering], locale: .current)`. The result of
/// `sortedIndices` is *exactly* the order that comparator defines.
///
/// How it's fast: CF serializes locale-aware comparisons behind a process-wide lock, so a
/// plain CF sort of 100k names takes ~250 ms on one core. Instead we
/// 1. build ICU sort keys in parallel and sort by them (memcmp, parallel) — this gets the
///    order right for all but a few exotic names (ligatures, mixed-width digit runs);
/// 2. finish with Swift's sort using the exact CF comparator. Swift's sort is run-adaptive,
///    so on nearly-sorted input it costs ~n comparisons instead of n·log n.
/// Without ICU (or for small inputs) step 2 alone runs on the original order.
public enum NameCollation {
    static let flags: CFStringCompareFlags = [
        .compareCaseInsensitive, .compareNumerically, .compareWidthInsensitive, .compareForcedOrdering,
    ]
    /// Below this, ICU setup isn't worth it.
    static let icuThreshold = 2048

    /// Whether the ICU pre-sort is available on this system.
    public static var usesICU: Bool { ICUSortKeys.shared != nil }

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
    public static func sortedIndices(of names: [String], locale: Locale = .current, allowICU: Bool = true) -> [UInt32] {
        let n = names.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        let state = Signposts.sorting.beginInterval("Name collation", "\(n) names")
        defer { Signposts.sorting.endInterval("Name collation", state) }

        let strings = makeCFStrings(names)
        var order: [UInt32]
        if allowICU, n >= icuThreshold, let icu = ICUSortKeys.shared, let pre = icuPreorder(names, icu: icu, locale: locale) {
            order = pre
        } else {
            order = Array(0..<UInt32(n))
        }

        let cfLocale = locale as CFLocale
        strings.withUnsafeBufferPointer { strs in
            order.sort { x, y in
                let sx = strs[Int(x)]
                let r = CFStringCompareWithOptionsAndLocale(
                    sx, strs[Int(y)], CFRange(location: 0, length: CFStringGetLength(sx)), flags, cfLocale)
                return r == .compareLessThan || (r == .compareEqualTo && x < y)
            }
        }
        return order
    }

    // MARK: ICU pre-sort

    private static func icuPreorder(_ names: [String], icu: ICUSortKeys, locale: Locale) -> [UInt32]? {
        let n = names.count
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 1024))

        // 1. Keys per chunk (one collator per thread), then concatenated into one buffer.
        let parts = ChunkResults<(bytes: [UInt8], ends: [Int])>(count: chunks)
        names.withUnsafeBufferPointer { input in
            let inBox = Box(input)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                guard let collator = icu.makeCollator(locale: locale) else { return }
                let range = (c * n / chunks)..<((c + 1) * n / chunks)
                var bytes: [UInt8] = []
                bytes.reserveCapacity(range.count * 32)
                var ends: [Int] = []
                ends.reserveCapacity(range.count)
                for i in range {
                    collator.appendKey(for: inBox.value[i], to: &bytes)
                    ends.append(bytes.count)
                }
                parts.set(c, (bytes, ends))
            }
        }
        var keyBytes: [UInt8] = []
        var offsets: [Int] = [0]
        offsets.reserveCapacity(n + 1)
        for c in 0..<chunks {
            guard let part = parts.values[c] else { return nil } // collator failed to open
            let base = keyBytes.count
            keyBytes.append(contentsOf: part.bytes)
            for end in part.ends { offsets.append(base + end) }
        }

        // 2. Parallel sort by key.
        return keyBytes.withUnsafeBufferPointer { keys in
            offsets.withUnsafeBufferPointer { offs in
                let comparator = KeyComparator(keys: keys.baseAddress!, offsets: offs.baseAddress!)
                return parallelSort(count: n, chunks: chunks, less: comparator.less)
            }
        }
    }

    /// Parallel chunk sort + parallel pairwise merges. `less` must be thread-safe.
    static func parallelSort(count n: Int, chunks: Int, less: @escaping @Sendable (UInt32, UInt32) -> Bool) -> [UInt32] {
        var bounds = (0...chunks).map { $0 * n / chunks }
        let a = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        let b = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        defer { a.deallocate(); b.deallocate() }
        for i in 0..<n { a[i] = UInt32(i) }

        let sortBounds = bounds
        let aBox = Box(a)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var chunk = UnsafeMutableBufferPointer(start: aBox.value + sortBounds[c], count: sortBounds[c + 1] - sortBounds[c])
            chunk.sort(by: less)
        }

        var src = a, dst = b
        while bounds.count > 2 {
            let current = bounds
            let last = current.count - 1
            let srcBox = Box(src), dstBox = Box(dst)
            DispatchQueue.concurrentPerform(iterations: (last + 1) / 2) { p in
                let s = srcBox.value, d = dstBox.value
                let lo = current[2 * p], mid = current[min(2 * p + 1, last)], hi = current[min(2 * p + 2, last)]
                var i = lo, j = mid, k = lo
                while i < mid && j < hi {
                    if less(s[j], s[i]) { d[k] = s[j]; j += 1 } else { d[k] = s[i]; i += 1 }
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

    /// Builds native CFStrings (much faster to collate than bridged Swift strings), in parallel.
    private static func makeCFStrings(_ names: [String]) -> [CFString] {
        let n = names.count
        let out = UnsafeMutablePointer<CFString?>.allocate(capacity: n)
        out.initialize(repeating: nil, count: n)
        defer { out.deinitialize(count: n); out.deallocate() }
        let outBox = Box(out)
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 4096))
        names.withUnsafeBufferPointer { input in
            let inBox = Box(input)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                for i in (c * n / chunks)..<((c + 1) * n / chunks) {
                    var name = inBox.value[i]
                    outBox.value[i] = name.withUTF8 { utf8 in
                        CFStringCreateWithBytes(nil, utf8.baseAddress, utf8.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
                    }
                }
            }
        }
        return (0..<n).map { out[$0] ?? ("" as CFString) }
    }
}

/// Compares ICU sort keys stored back to back in one buffer.
private struct KeyComparator: @unchecked Sendable {
    let keys: UnsafePointer<UInt8>
    let offsets: UnsafePointer<Int>

    @inline(__always)
    func less(_ x: UInt32, _ y: UInt32) -> Bool {
        let ox = offsets[Int(x)], lx = offsets[Int(x) + 1] - ox
        let oy = offsets[Int(y)], ly = offsets[Int(y) + 1] - oy
        let r = memcmp(keys + ox, keys + oy, min(lx, ly))
        if r != 0 { return r < 0 }
        if lx != ly { return lx < ly }
        return x < y
    }
}

/// A value handed to `concurrentPerform` workers, each of which touches a disjoint range.
struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Per-chunk results written by concurrent workers (each writes only its own slot).
final class ChunkResults<T>: @unchecked Sendable {
    private(set) var values: [T?]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: T) { lock.lock(); values[index] = value; lock.unlock() }
}
