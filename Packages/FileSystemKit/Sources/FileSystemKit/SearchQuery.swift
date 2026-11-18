import Foundation

/// The search box's query (P3-7): name words plus Explorer-style filters on size and date modified.
///
///     report size:>10MB date:thisweek
///     size:large date:2024-05..2024-06 invoice
///     size:<=4KB date:<7d            (smaller than 4 KB, changed in the last 7 days)
///
/// **size:** `>`, `>=`, `<`, `<=` a size (`10MB`, `1.5 GB`, `512K`, `4096` = bytes; KB/MB/GB/TB are 1000-based like
/// Finder, KiB/MiB/GiB/TiB 1024-based); `a..b` a range; a bare size means "shows as" (`size:10MB` = 9.5–10.5 MB); or
/// Explorer's names — empty, tiny (≤ 16 KB), small (≤ 1 MB), medium (≤ 128 MB), large (≤ 1 GB), huge (≤ 4 GB),
/// gigantic. Only files have a size: folders don't match a size filter.
/// **date:** today, yesterday, thisweek, lastweek, thismonth, lastmonth, thisyear, lastyear; a day, month or year
/// (`2024-05-17`, `2024-05`, `2024`) with `>`, `>=`, `<`, `<=` or as a range (`2024-01..2024-03`); or an age —
/// `date:7d` / `date:<7d` within the last 7 days, `date:>2w` older than two weeks (d, w, m = months, y).
/// Anything that isn't a filter (an unknown `key:` or a value that doesn't parse) stays a name word.
public struct SearchQuery: Equatable, Sendable {
    /// The name part: words that must all appear in the name (folded, any order).
    public var text: String
    public var size: SizeFilter
    public var date: DateFilter

    public init(text: String = "", size: SizeFilter = .any, date: DateFilter = .any) {
        self.text = text
        self.size = size
        self.date = date
    }

    public var hasFilters: Bool { size != .any || date != .any }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !hasFilters }

    // MARK: Parsing and writing

    public static func parse(_ query: String) -> SearchQuery {
        var result = SearchQuery()
        var words: [Substring] = []
        for token in query.split(whereSeparator: \.isWhitespace) {
            let lower = token.lowercased()
            if lower.hasPrefix("size:"), let filter = SizeFilter.parse(lower.dropFirst(5)) {
                result.size = filter
            } else if lower.hasPrefix("date:") || lower.hasPrefix("modified:"), let filter = DateFilter.parse(lower.split(separator: ":", maxSplits: 1).last ?? "") {
                result.date = filter
            } else {
                words.append(token)
            }
        }
        result.text = words.joined(separator: " ")
        return result
    }

    /// The query as text: the words, then the filters (what the filter popover writes into the search box).
    public var formatted: String {
        var parts: [String] = text.isEmpty ? [] : [text]
        if size != .any { parts.append("size:" + size.formatted) }
        if date != .any { parts.append("date:" + date.formatted) }
        return parts.joined(separator: " ")
    }

    // MARK: Matching

    /// The filters with their ranges worked out for `now` (dates) — cheap to apply to every item.
    public func predicate(now: Date = .now, calendar: Calendar = .current) -> Predicate {
        Predicate(bytes: size.range, dates: date.interval(now: now, calendar: calendar), sizeFilter: size != .any)
    }

    public struct Predicate: Sendable {
        let bytes: ClosedRange<Int64>?
        let dates: Range<Date>?
        let sizeFilter: Bool

        public var isEmpty: Bool { !sizeFilter && dates == nil }

        public func matches(_ item: FileItem) -> Bool {
            if sizeFilter {
                guard !item.isFolder, item.kind != .directory, let bytes, bytes.contains(item.size) else { return false }
            }
            if let dates, !dates.contains(item.modificationDate) { return false }
            return true
        }
    }
}

// MARK: Size

public enum SizeUnit: String, CaseIterable, Sendable {
    case bytes = "B", kb = "KB", mb = "MB", gb = "GB", tb = "TB", kib = "KiB", mib = "MiB", gib = "GiB", tib = "TiB"

    public var multiplier: Double {
        switch self {
        case .bytes: 1
        case .kb: 1e3
        case .mb: 1e6
        case .gb: 1e9
        case .tb: 1e12
        case .kib: 1024
        case .mib: 1024 * 1024
        case .gib: 1024 * 1024 * 1024
        case .tib: 1024 * 1024 * 1024 * 1024
        }
    }

    static func parse(_ text: Substring) -> SizeUnit? {
        switch text.lowercased() {
        case "", "b", "byte", "bytes": .bytes
        case "k", "kb": .kb
        case "m", "mb": .mb
        case "g", "gb": .gb
        case "t", "tb": .tb
        case "kib": .kib
        case "mib": .mib
        case "gib": .gib
        case "tib": .tib
        default: nil
        }
    }
}

/// A size as written: a number and a unit ("1.5 GB"), so the popover and the text round-trip exactly.
public struct SizeAmount: Equatable, Sendable {
    public var value: Double
    public var unit: SizeUnit

    public init(_ value: Double, _ unit: SizeUnit) {
        self.value = value
        self.unit = unit
    }

    public var bytes: Int64 { Int64((value * unit.multiplier).rounded()) }

    static func parse(_ text: Substring) -> SizeAmount? {
        let number = text.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !number.isEmpty, let value = Double(number.replacingOccurrences(of: ",", with: ".")), value >= 0,
              let unit = SizeUnit.parse(text.dropFirst(number.count)) else { return nil }
        return SizeAmount(value, unit)
    }

    public var formatted: String {
        let number = value == value.rounded() ? String(Int64(value)) : String(value)
        return number + (unit == .bytes ? "" : unit.rawValue)
    }
}

/// Explorer's size groups.
public enum SizeBucket: String, CaseIterable, Sendable {
    case empty, tiny, small, medium, large, huge, gigantic

    public var range: ClosedRange<Int64> {
        switch self {
        case .empty: 0...0
        case .tiny: 1...16_000
        case .small: 16_001...1_000_000
        case .medium: 1_000_001...128_000_000
        case .large: 128_000_001...1_000_000_000
        case .huge: 1_000_000_001...4_000_000_000
        case .gigantic: 4_000_000_001...Int64.max
        }
    }

    public var title: String {
        switch self {
        case .empty: "Empty (0 KB)"
        case .tiny: "Tiny (up to 16 KB)"
        case .small: "Small (16 KB – 1 MB)"
        case .medium: "Medium (1 – 128 MB)"
        case .large: "Large (128 MB – 1 GB)"
        case .huge: "Huge (1 – 4 GB)"
        case .gigantic: "Gigantic (over 4 GB)"
        }
    }
}

public enum SizeFilter: Equatable, Sendable {
    case any
    case bucket(SizeBucket)
    /// `>` (inclusive false) / `>=`.
    case larger(SizeAmount, inclusive: Bool)
    /// `<` / `<=`.
    case smaller(SizeAmount, inclusive: Bool)
    /// "Shows as" this size: within half a unit.
    case about(SizeAmount)
    case between(SizeAmount, SizeAmount)

    static func parse(_ text: Substring) -> SizeFilter? {
        if let bucket = SizeBucket(rawValue: String(text)) { return .bucket(bucket) }
        for (op, make) in [(">=", { SizeFilter.larger($0, inclusive: true) }), ("<=", { SizeFilter.smaller($0, inclusive: true) }),
                           (">", { SizeFilter.larger($0, inclusive: false) }), ("<", { SizeFilter.smaller($0, inclusive: false) })]
            as [(String, (SizeAmount) -> SizeFilter)] where text.hasPrefix(op) {
            return SizeAmount.parse(text.dropFirst(op.count)).map(make)
        }
        if let range = text.range(of: "..") {
            guard let low = SizeAmount.parse(text[..<range.lowerBound]), let high = SizeAmount.parse(text[range.upperBound...]) else { return nil }
            return .between(low, high)
        }
        return SizeAmount.parse(text).map(SizeFilter.about)
    }

    public var formatted: String {
        switch self {
        case .any: ""
        case .bucket(let bucket): bucket.rawValue
        case .larger(let amount, let inclusive): (inclusive ? ">=" : ">") + amount.formatted
        case .smaller(let amount, let inclusive): (inclusive ? "<=" : "<") + amount.formatted
        case .about(let amount): amount.formatted
        case .between(let low, let high): low.formatted + ".." + high.formatted
        }
    }

    /// The sizes that match, in bytes.
    public var range: ClosedRange<Int64>? {
        switch self {
        case .any: return nil
        case .bucket(let bucket): return bucket.range
        case .larger(let amount, let inclusive): return (inclusive ? amount.bytes : amount.bytes + 1)...Int64.max
        case .smaller(let amount, let inclusive):
            let top = inclusive ? amount.bytes : amount.bytes - 1
            return top < 0 ? nil : 0...top
        case .about(let amount):
            if amount.unit == .bytes { return amount.bytes...amount.bytes }
            let half = amount.unit.multiplier / 2
            let low = Int64(max(0, (amount.value * amount.unit.multiplier - half).rounded(.up)))
            let high = Int64((amount.value * amount.unit.multiplier + half).rounded(.up)) - 1
            return low <= high ? low...high : nil
        case .between(let a, let b):
            let low = min(a.bytes, b.bytes), high = max(a.bytes, b.bytes)
            return low...high
        }
    }
}

// MARK: Date

public enum DatePreset: String, CaseIterable, Sendable {
    case today, yesterday, thisweek, lastweek, thismonth, lastmonth, thisyear, lastyear

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisweek: "This week"
        case .lastweek: "Last week"
        case .thismonth: "This month"
        case .lastmonth: "Last month"
        case .thisyear: "This year"
        case .lastyear: "Last year"
        }
    }

    func interval(now: Date, calendar: Calendar) -> Range<Date> {
        func span(_ component: Calendar.Component, back: Int) -> Range<Date> {
            let start = calendar.dateInterval(of: component, for: now)?.start ?? now
            let from = calendar.date(byAdding: component, value: -back, to: start) ?? start
            let to = calendar.date(byAdding: component, value: 1, to: from) ?? from
            return from..<to
        }
        return switch self {
        case .today: span(.day, back: 0)
        case .yesterday: span(.day, back: 1)
        case .thisweek: span(.weekOfYear, back: 0)
        case .lastweek: span(.weekOfYear, back: 1)
        case .thismonth: span(.month, back: 0)
        case .lastmonth: span(.month, back: 1)
        case .thisyear: span(.year, back: 0)
        case .lastyear: span(.year, back: 1)
        }
    }
}

/// A calendar day, month or year as written ("2024-05-17", "2024-05", "2024").
public struct CalendarSpan: Equatable, Sendable {
    public var year: Int
    public var month: Int?
    public var day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    static func parse(_ text: Substring) -> CalendarSpan? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts[0].count == 4, let year = Int(parts[0]) else { return nil }
        let month = parts.count > 1 ? Int(parts[1]) : nil
        let day = parts.count > 2 ? Int(parts[2]) : nil
        if let month, !(1...12).contains(month) { return nil }
        if let day, !(1...31).contains(day) { return nil }
        return CalendarSpan(year: year, month: month, day: day)
    }

    public var formatted: String {
        var text = String(format: "%04d", year)
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        return text
    }

    /// The span in `calendar`'s time zone: [first moment, first moment after).
    func interval(calendar: Calendar) -> Range<Date>? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month ?? 1, day: day ?? 1)) else { return nil }
        let component: Calendar.Component = day != nil ? .day : month != nil ? .month : .year
        guard let end = calendar.date(byAdding: component, value: 1, to: start) else { return nil }
        return start..<end
    }

    /// The day `date` falls on.
    public static func day(of date: Date, calendar: Calendar = .current) -> CalendarSpan {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarSpan(year: c.year ?? 2000, month: c.month, day: c.day)
    }

    /// Its first day (for date pickers).
    public func startDate(calendar: Calendar = .current) -> Date? { interval(calendar: calendar)?.lowerBound }
}

public enum AgeUnit: String, CaseIterable, Sendable {
    case days = "d", weeks = "w", months = "m", years = "y"

    public var title: String {
        switch self {
        case .days: "days"
        case .weeks: "weeks"
        case .months: "months"
        case .years: "years"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
    }
}

public struct Age: Equatable, Sendable {
    public var value: Int
    public var unit: AgeUnit

    public init(_ value: Int, _ unit: AgeUnit) {
        self.value = value
        self.unit = unit
    }

    static func parse(_ text: Substring) -> Age? {
        guard let last = text.last, let unit = AgeUnit(rawValue: String(last).lowercased()) else { return nil }
        let number = text.dropLast()
        guard !number.isEmpty, number.allSatisfy(\.isNumber), let value = Int(number) else { return nil }
        return Age(value, unit)
    }

    public var formatted: String { "\(value)\(unit.rawValue)" }

    func cutoff(now: Date, calendar: Calendar) -> Date { calendar.date(byAdding: unit.component, value: -value, to: now) ?? now }
}

public enum DateFilter: Equatable, Sendable {
    case any
    case preset(DatePreset)
    /// That day / month / year.
    case on(CalendarSpan)
    /// `>` (after it) / `>=` (from it on).
    case after(CalendarSpan, inclusive: Bool)
    /// `<` (before it) / `<=` (up to and including it).
    case before(CalendarSpan, inclusive: Bool)
    case between(CalendarSpan, CalendarSpan)
    /// Changed within the last … (`date:7d`, `date:<7d`).
    case within(Age)
    /// Changed longer ago than … (`date:>7d`).
    case olderThan(Age)

    static func parse(_ text: Substring) -> DateFilter? {
        if let preset = DatePreset(rawValue: String(text)) { return .preset(preset) }
        if let range = text.range(of: "..") {
            guard let a = CalendarSpan.parse(text[..<range.lowerBound]), let b = CalendarSpan.parse(text[range.upperBound...]) else { return nil }
            return .between(a, b)
        }
        for op in [">=", "<=", ">", "<"] where text.hasPrefix(op) {
            let rest = text.dropFirst(op.count)
            if let age = Age.parse(rest) { return op.hasPrefix(">") ? .olderThan(age) : .within(age) } // ages compare by age
            guard let span = CalendarSpan.parse(rest) else { return nil }
            return op.hasPrefix(">") ? .after(span, inclusive: op == ">=") : .before(span, inclusive: op == "<=")
        }
        if let age = Age.parse(text) { return .within(age) }
        return CalendarSpan.parse(text).map(DateFilter.on)
    }

    public var formatted: String {
        switch self {
        case .any: ""
        case .preset(let preset): preset.rawValue
        case .on(let span): span.formatted
        case .after(let span, let inclusive): (inclusive ? ">=" : ">") + span.formatted
        case .before(let span, let inclusive): (inclusive ? "<=" : "<") + span.formatted
        case .between(let a, let b): a.formatted + ".." + b.formatted
        case .within(let age): age.formatted
        case .olderThan(let age): ">" + age.formatted
        }
    }

    /// The modification dates that match.
    public func interval(now: Date, calendar: Calendar) -> Range<Date>? {
        let distantPast = Date.distantPast, distantFuture = Date.distantFuture
        switch self {
        case .any: return nil
        case .preset(let preset): return preset.interval(now: now, calendar: calendar)
        case .on(let span): return span.interval(calendar: calendar)
        case .after(let span, let inclusive):
            guard let range = span.interval(calendar: calendar) else { return nil }
            return (inclusive ? range.lowerBound : range.upperBound)..<distantFuture
        case .before(let span, let inclusive):
            guard let range = span.interval(calendar: calendar) else { return nil }
            return distantPast..<(inclusive ? range.upperBound : range.lowerBound)
        case .between(let a, let b):
            guard let first = a.interval(calendar: calendar), let second = b.interval(calendar: calendar) else { return nil }
            return min(first.lowerBound, second.lowerBound)..<max(first.upperBound, second.upperBound)
        case .within(let age): return age.cutoff(now: now, calendar: calendar)..<distantFuture
        case .olderThan(let age): return distantPast..<age.cutoff(now: now, calendar: calendar)
        }
    }
}
