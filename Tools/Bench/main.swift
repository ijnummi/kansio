// kansio-bench: listing and sorting benchmarks for FileSystemKit.
//
//   swift run -c release kansio-bench [fixtures-dir] [--iterations N] [--home]
//
// Read-only: it only lists directories. Prints a Markdown table for PERF.md.
// Numbers are warm-cache (the first, cold run is discarded as warm-up).
import Foundation
import FileSystemKit

var args = Array(CommandLine.arguments.dropFirst())
var iterations = 15
var includeHome = false
if let i = args.firstIndex(of: "--iterations"), i + 1 < args.count {
    iterations = Int(args[i + 1]) ?? iterations
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--home") { includeHome = true; args.remove(at: i) }
var trashOnly = false // --trash: only the Trash listing table (P2-1)
if let i = args.firstIndex(of: "--trash") { trashOnly = true; args.remove(at: i) }
let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "/tmp"
let fixtures = URL(filePath: args.first ?? ProcessInfo.processInfo.environment["KANSIO_FIXTURES"] ?? "\(tmp)/kansio-fixtures")

@MainActor
func measure(_ body: () throws -> Void) rethrows -> (median: Double, min: Double) {
    try body() // warm-up
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3)
    }
    samples.sort()
    return (samples[samples.count / 2], samples[0])
}

func ms(_ v: (median: Double, min: Double)) -> String { String(format: "%.2f (%.2f)", v.median, v.min) }

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
}

let bulk = BulkDirectoryLister()
let foundation = FoundationDirectoryLister()

print("Machine: \(sysctlString("hw.model")), \(sysctlString("machdep.cpu.brand_string")), " +
      "\(ProcessInfo.processInfo.activeProcessorCount) cores, " +
      "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Date: \(ISO8601DateFormatter().string(from: Date())), iterations: \(iterations), times in ms as median (min)\n")

var targets: [(String, URL)] = ["flat-1k", "flat-10k", "flat-100k"].map { ($0, fixtures.appending(path: $0)) }
if includeHome { targets.append(("home", FileManager.default.homeDirectoryForCurrentUser)) }
if trashOnly { trashTable(); exit(0) }

print("| Folder | Items | getattrlistbulk | FileManager | Speed-up | First batch (bulk) | Name ranks (ICU pre-sort + exact CF) | Swift localizedStandardCompare sort (reference) | Re-sort by date | Re-sort by size | List + rank + order |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for (label, url) in targets {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        print("| \(label) | missing — run Tools/make-fixtures.sh | | | | | | | | | |")
        continue
    }
    let items = try bulk.listAll(url)
    let bulkTime = try measure { _ = try bulk.listAll(url) }
    let fmTime = try measure { _ = try foundation.listAll(url) }
    let firstBatch = try measure {
        try bulk.list(url) { _ in false } // stop after the first syscall's batch
    }
    let names = items.map(\.name)
    let rankTime = measure { _ = NameCollation.ranks(of: names) }
    let singleThread = measure {
        _ = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    let contents = FolderContents(items: items)
    let byDate = measure { _ = contents.ordered(by: FileSort(field: .dateModified, ascending: false), includeHidden: true) }
    let bySize = measure { _ = contents.ordered(by: FileSort(field: .size), includeHidden: true) }
    let pipeline = try measure {
        let c = FolderContents(items: try bulk.listAll(url))
        _ = c.ordered(by: .default, includeHidden: false)
    }
    print("| \(label) | \(items.count) | \(ms(bulkTime)) | \(ms(fmTime)) | \(String(format: "%.1f×", fmTime.median / bulkTime.median)) | \(ms(firstBatch)) | \(ms(rankTime)) | \(ms(singleThread)) | \(ms(byDate)) | \(ms(bySize)) | \(ms(pipeline)) |")
}

// Sorting by the text-derived columns: Type (kind descriptions, collated once per distinct kind) and
// Extension (P1-7, collated once per distinct extension).
print("\n| Folder | Items | Re-sort by type | Re-sort by extension |")
print("|---|---:|---:|---:|")
for (label, url) in targets {
    guard let items = try? bulk.listAll(url) else { continue }
    let contents = FolderContents(items: items)
    let byKind = measure { _ = contents.ordered(by: FileSort(field: .kind), includeHidden: true) }
    let byExtension = measure { _ = contents.ordered(by: FileSort(field: .fileExtension), includeHidden: true) }
    print("| \(label) | \(items.count) | \(ms(byKind)) | \(ms(byExtension)) |")
}

// P2-1: the Trash view lists every Trash folder in full (no progressive display), adds where each item came from and
// when it was deleted (the date added to the folder when Kansio has no record), then orders the rows. A fixtures
// folder stands in for a Trash folder (read-only: nothing is moved or deleted).
trashTable()

@MainActor
func trashTable() {
print("\n| Folder (as a Trash folder) | Items | List with origin + date deleted | …without the per-item date lookup | Order by Date Deleted | Order by Original Location |")
print("|---|---:|---:|---:|---:|---:|")
for (label, url) in targets where label.hasPrefix("flat-1") {
    let folder = TrashFolder(url: url, volumeRoot: URL(filePath: "/"))
    let history = TrashHistory(file: nil)
    let listing = measure { _ = TrashListing.listBlocking([folder], history: history) }
    let entries = TrashListing.listBlocking([folder], history: history).entries
    // Every item known to the history (its date comes from there): the cost without the per-item lookup.
    let known = TrashHistory(file: nil)
    for entry in entries { known.record(original: URL(filePath: "/x/" + entry.displayName), inTrash: URL(filePath: entry.path)) }
    let withHistory = measure { _ = TrashListing.listBlocking([folder], history: known) }
    let byDate = measure { _ = TrashListing.ordered(entries, sort: .default, key: .dateDeleted, ascending: false, includeHidden: true) }
    let byOrigin = measure { _ = TrashListing.ordered(entries, sort: .default, key: .originalLocation, ascending: true, includeHidden: true) }
    print("| \(label) | \(entries.count) | \(ms(listing)) | \(ms(withHistory)) | \(ms(byDate)) | \(ms(byOrigin)) |")
}
}
