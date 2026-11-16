import Darwin
import Foundation

/// ICU collation sort keys from the system `libicucore`, loaded at runtime.
///
/// Why: CoreFoundation serializes locale-aware comparisons behind a process-wide lock,
/// so sorting 100k names with `localizedStandardCompare` can't use more than one core
/// (~250 ms). ICU sort keys are plain byte strings: built in parallel with one collator
/// per thread, compared with `memcmp`.
///
/// ICU's ordering is *close to* but not identical with CF's (CF special-cases e.g. the
/// "ﬁ" ligature and full-width digits next to ASCII digits), so callers use the ICU order
/// only as a pre-sort and finish with an exact CF pass (see `NameCollation`).
///
/// The SDK ships no ICU headers and ICU isn't a documented macOS API, so the few C functions
/// are looked up with `dlsym`. If anything is missing, `ICUSortKeys.shared` is nil and the
/// caller uses CF alone — the app never fails to launch because of this.
struct ICUSortKeys: @unchecked Sendable {
    private typealias Open = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    private typealias Close = @convention(c) (OpaquePointer?) -> Void
    private typealias SetAttribute = @convention(c) (OpaquePointer?, Int32, Int32, UnsafeMutablePointer<Int32>?) -> Void
    private typealias GetSortKey = @convention(c) (OpaquePointer?, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32

    private let open: Open
    private let close: Close
    private let setAttribute: SetAttribute
    private let getSortKey: GetSortKey

    static let shared: ICUSortKeys? = ICUSortKeys()

    private init?() {
        guard let lib = dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW | RTLD_LOCAL),
              let o = dlsym(lib, "ucol_open"), let c = dlsym(lib, "ucol_close"),
              let s = dlsym(lib, "ucol_setAttribute"), let k = dlsym(lib, "ucol_getSortKey")
        else { return nil }
        open = unsafeBitCast(o, to: Open.self)
        close = unsafeBitCast(c, to: Close.self)
        setAttribute = unsafeBitCast(s, to: SetAttribute.self)
        getSortKey = unsafeBitCast(k, to: GetSortKey.self)
    }

    // ucol.h constants
    private static let attrNormalization: Int32 = 4, attrStrength: Int32 = 5, attrNumeric: Int32 = 7
    private static let secondary: Int32 = 1, on: Int32 = 17

    /// A collator configured like `localizedStandardCompare`: secondary strength
    /// (ignores case and width, keeps accents), numeric ordering, normalization on.
    /// Not thread-safe: one per thread.
    final class Collator {
        fileprivate let icu: ICUSortKeys
        fileprivate let handle: OpaquePointer
        private var utf16: [UInt16] = []
        private var buffer = [UInt8](repeating: 0, count: 512)

        fileprivate init?(icu: ICUSortKeys, collatorID: String) {
            var status: Int32 = 0
            guard let h = icu.open(collatorID, &status), status <= 0 else { return nil }
            icu.setAttribute(h, ICUSortKeys.attrStrength, ICUSortKeys.secondary, &status)
            icu.setAttribute(h, ICUSortKeys.attrNumeric, ICUSortKeys.on, &status)
            icu.setAttribute(h, ICUSortKeys.attrNormalization, ICUSortKeys.on, &status)
            guard status <= 0 else { icu.close(h); return nil }
            self.icu = icu
            handle = h
        }

        deinit { icu.close(handle) }

        /// Appends the sort key for `string` (without its trailing NUL) to `out`.
        func appendKey(for string: String, to out: inout [UInt8]) {
            utf16.removeAll(keepingCapacity: true)
            utf16.append(contentsOf: string.utf16)
            var length = Int(icu.getSortKey(handle, utf16, Int32(utf16.count), &buffer, Int32(buffer.count)))
            if length > buffer.count {
                buffer = [UInt8](repeating: 0, count: length)
                length = Int(icu.getSortKey(handle, utf16, Int32(utf16.count), &buffer, Int32(buffer.count)))
            }
            out.append(contentsOf: buffer[0..<max(0, length - 1)])
        }
    }

    func makeCollator(locale: Locale) -> Collator? {
        let id = (CFLocaleGetValue(locale as CFLocale, .collatorIdentifier) as? String) ?? locale.identifier
        return Collator(icu: self, collatorID: id)
    }
}
