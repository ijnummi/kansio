import AppKit
import FileSystemKit
import SwiftUI

/// The search filters popover (P3-7): size and date modified as controls, kept in step with the search box — a change
/// here rewrites the `size:` / `date:` part of the query (the words stay); typing a filter in the box updates the
/// controls. The query text stays the one source of truth (`SearchQuery`). SwiftUI: a small, low-traffic popover.
@MainActor
final class SearchFilterModel: ObservableObject {
    /// "any", "bucket.<name>", "larger", "atLeast", "smaller", "atMost", "about", "between".
    @Published var sizeMode = "any" { didSet { changed() } }
    @Published var sizeValue: Double = 1 { didSet { changed() } }
    @Published var sizeUnit: SizeUnit = .mb { didSet { changed() } }
    @Published var sizeValue2: Double = 10 { didSet { changed() } }
    @Published var sizeUnit2: SizeUnit = .mb { didSet { changed() } }
    /// "any", "preset.<name>", "within", "olderThan", "on", "after", "onOrAfter", "before", "onOrBefore", "between".
    @Published var dateMode = "any" { didSet { changed() } }
    @Published var ageValue = 7 { didSet { changed() } }
    @Published var ageUnit: AgeUnit = .days { didSet { changed() } }
    @Published var date1 = Date.now { didSet { changed() } }
    @Published var date2 = Date.now { didSet { changed() } }
    /// Whether a date means its day, month or year ("date:2024-05" = all of May).
    @Published var granularity: Granularity = .day { didSet { changed() } }

    enum Granularity: String, CaseIterable { case day, month, year }

    /// The query's words (kept as they are).
    private(set) var words = ""
    /// A change from the controls: the new query text.
    var onChange: ((String) -> Void)?
    private var loading = false

    var sizeNeedsValue: Bool { ["larger", "atLeast", "smaller", "atMost", "about", "between"].contains(sizeMode) }
    var dateNeedsAge: Bool { dateMode == "within" || dateMode == "olderThan" }
    var dateNeedsDate: Bool { ["on", "after", "onOrAfter", "before", "onOrBefore", "between"].contains(dateMode) }

    /// Shows `query` in the controls (no write-back).
    func load(_ query: SearchQuery) {
        loading = true
        defer { loading = false }
        words = query.text
        switch query.size {
        case .any: sizeMode = "any"
        case .bucket(let bucket): sizeMode = "bucket." + bucket.rawValue
        case .larger(let a, let inclusive): sizeMode = inclusive ? "atLeast" : "larger"; set(a)
        case .smaller(let a, let inclusive): sizeMode = inclusive ? "atMost" : "smaller"; set(a)
        case .about(let a): sizeMode = "about"; set(a)
        case .between(let a, let b): sizeMode = "between"; set(a); sizeValue2 = b.value; sizeUnit2 = b.unit
        }
        switch query.date {
        case .any: dateMode = "any"
        case .preset(let preset): dateMode = "preset." + preset.rawValue
        case .within(let age): dateMode = "within"; ageValue = age.value; ageUnit = age.unit
        case .olderThan(let age): dateMode = "olderThan"; ageValue = age.value; ageUnit = age.unit
        case .on(let span): dateMode = "on"; set(span)
        case .after(let span, let inclusive): dateMode = inclusive ? "onOrAfter" : "after"; set(span)
        case .before(let span, let inclusive): dateMode = inclusive ? "onOrBefore" : "before"; set(span)
        case .between(let a, let b): dateMode = "between"; set(a); date2 = b.startDate() ?? date2
        }
    }

    private func set(_ amount: SizeAmount) {
        sizeValue = amount.value
        sizeUnit = amount.unit
    }

    private func set(_ span: CalendarSpan) {
        date1 = span.startDate() ?? date1
        granularity = span.day != nil ? .day : span.month != nil ? .month : .year
    }

    /// The query the controls describe (with the words).
    var query: SearchQuery {
        var query = SearchQuery(text: words)
        let a = SizeAmount(max(0, sizeValue), sizeUnit), b = SizeAmount(max(0, sizeValue2), sizeUnit2)
        switch sizeMode {
        case "larger": query.size = .larger(a, inclusive: false)
        case "atLeast": query.size = .larger(a, inclusive: true)
        case "smaller": query.size = .smaller(a, inclusive: false)
        case "atMost": query.size = .smaller(a, inclusive: true)
        case "about": query.size = .about(a)
        case "between": query.size = .between(a, b)
        default:
            if sizeMode.hasPrefix("bucket."), let bucket = SizeBucket(rawValue: String(sizeMode.dropFirst(7))) { query.size = .bucket(bucket) }
        }
        func span(_ date: Date) -> CalendarSpan {
            var span = CalendarSpan.day(of: date)
            if granularity != .day { span.day = nil }
            if granularity == .year { span.month = nil }
            return span
        }
        let age = Age(max(0, ageValue), ageUnit)
        switch dateMode {
        case "within": query.date = .within(age)
        case "olderThan": query.date = .olderThan(age)
        case "on": query.date = .on(span(date1))
        case "after": query.date = .after(span(date1), inclusive: false)
        case "onOrAfter": query.date = .after(span(date1), inclusive: true)
        case "before": query.date = .before(span(date1), inclusive: false)
        case "onOrBefore": query.date = .before(span(date1), inclusive: true)
        case "between": query.date = .between(span(date1), span(date2))
        default:
            if dateMode.hasPrefix("preset."), let preset = DatePreset(rawValue: String(dateMode.dropFirst(7))) { query.date = .preset(preset) }
        }
        return query
    }

    func clear() {
        loading = true
        sizeMode = "any"
        dateMode = "any"
        loading = false
        changed()
    }

    private func changed() {
        guard !loading else { return }
        onChange?(query.formatted)
    }
}

struct SearchFiltersView: View {
    @ObservedObject var model: SearchFilterModel

    var body: some View {
        Form {
            Section("Size") {
                Picker("Size", selection: $model.sizeMode) {
                    Text("Any size").tag("any")
                    Divider()
                    ForEach(SizeBucket.allCases, id: \.self) { Text($0.title).tag("bucket." + $0.rawValue) }
                    Divider()
                    Text("Larger than").tag("larger")
                    Text("At least").tag("atLeast")
                    Text("Smaller than").tag("smaller")
                    Text("At most").tag("atMost")
                    Text("About").tag("about")
                    Text("Between").tag("between")
                }
                if model.sizeNeedsValue {
                    sizeRow(value: $model.sizeValue, unit: $model.sizeUnit, label: model.sizeMode == "between" ? "From" : "Size")
                    if model.sizeMode == "between" { sizeRow(value: $model.sizeValue2, unit: $model.sizeUnit2, label: "To") }
                }
            }
            Section("Date modified") {
                Picker("Modified", selection: $model.dateMode) {
                    Text("Any time").tag("any")
                    Divider()
                    ForEach(DatePreset.allCases, id: \.self) { Text($0.title).tag("preset." + $0.rawValue) }
                    Divider()
                    Text("Within the last…").tag("within")
                    Text("Longer ago than…").tag("olderThan")
                    Divider()
                    Text("On").tag("on")
                    Text("After").tag("after")
                    Text("On or after").tag("onOrAfter")
                    Text("Before").tag("before")
                    Text("On or before").tag("onOrBefore")
                    Text("Between").tag("between")
                }
                if model.dateNeedsAge {
                    HStack {
                        TextField("Amount", value: $model.ageValue, format: .number).frame(width: 70)
                        Picker("Unit", selection: $model.ageUnit) {
                            ForEach(AgeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                if model.dateNeedsDate {
                    Picker("Whole", selection: $model.granularity) {
                        Text("Day").tag(SearchFilterModel.Granularity.day)
                        Text("Month").tag(SearchFilterModel.Granularity.month)
                        Text("Year").tag(SearchFilterModel.Granularity.year)
                    }
                    .pickerStyle(.segmented)
                    DatePicker(model.dateMode == "between" ? "From" : "Date", selection: $model.date1, displayedComponents: .date)
                    if model.dateMode == "between" { DatePicker("To", selection: $model.date2, displayedComponents: .date) }
                }
            }
            Section {
                HStack {
                    Text(model.query.formatted.isEmpty ? "No filters" : model.query.formatted)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Clear Filters") { model.clear() }
                        .disabled(model.sizeMode == "any" && model.dateMode == "any")
                }
            } footer: {
                Text("Or type them: size:>10MB, size:large, date:thisweek, date:7d, date:2024-05..2024-06")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sizeRow(value: Binding<Double>, unit: Binding<SizeUnit>, label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number).frame(width: 90).labelsHidden()
            Picker("Unit", selection: unit) {
                ForEach([SizeUnit.bytes, .kb, .mb, .gb, .tb, .kib, .mib, .gib, .tib], id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)
        }
    }
}
