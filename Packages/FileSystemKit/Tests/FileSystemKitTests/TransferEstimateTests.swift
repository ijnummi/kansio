import Foundation
import Synchronization
import Testing
@testable import FileSystemKit

@Suite("Pause and time-left estimate")
struct TransferEstimateTests {
    // MARK: Pause

    @Test func pausedBeforeStartDoesNothingUntilResumed() async throws {
        let t = try TempDir()
        let source = t.url.appending(path: "src", directoryHint: .isDirectory)
        let destination = t.url.appending(path: "dst", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for i in 0..<50 { try Data("\(i)".utf8).write(to: source.appending(path: "f\(i).txt")) }
        let gate = PauseGate()
        gate.pause()
        var engine = CopyEngine(kind: .copy, sources: [source], destination: destination)
        engine.allowClone = false
        engine.pauseGate = gate
        let task = Task { await engine.run() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)).isEmpty)
        gate.resume()
        let result = await task.value
        #expect(!result.cancelled && result.errors.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "src").path(percentEncoded: false)).count == 50)
    }

    @Test func pausesInsideALargeFileAndResumes() async throws {
        let t = try TempDir()
        let big = t.url.appending(path: "big.bin")
        try Data(repeating: 7, count: 96 << 20).write(to: big)
        let destination = t.url.appending(path: "dst", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let gate = PauseGate()
        let seen = Mutex<Int64>(0)
        let pausedOnce = Atomic<Bool>(false)
        var engine = CopyEngine(kind: .copy, sources: [big], destination: destination)
        engine.allowClone = false
        engine.pauseGate = gate
        engine.progressInterval = .zero // every chunk reports (a fast disk copies 96 MB between two throttled reports)
        let task = Task {
            await engine.run { progress in
                seen.withLock { $0 = progress.completedBytes }
                // Mid-file, once (after Resume it carries on).
                if progress.completedBytes > 0, progress.completedBytes < progress.totalBytes, pausedOnce.exchange(true, ordering: .relaxed) == false {
                    gate.pause()
                }
            }
        }
        var waited = 0
        while !gate.isPaused, waited < 500 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(gate.isPaused)
        try await Task.sleep(for: .milliseconds(150))
        let atPause = seen.withLock { $0 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.withLock { $0 } == atPause) // nothing moved while paused
        #expect(atPause < 96 << 20)
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "big.bin").path(percentEncoded: false))) // not placed yet
        gate.resume()
        let result = await task.value
        #expect(!result.cancelled && result.errors.isEmpty)
        let size = try FileManager.default.attributesOfItem(atPath: destination.appending(path: "big.bin").path(percentEncoded: false))[.size] as? Int
        #expect(size == 96 << 20)
    }

    @Test func cancelWhilePausedStopsPromptly() async throws {
        let t = try TempDir()
        let file = try t.file("a.txt", bytes: 10)
        let destination = t.url.appending(path: "dst", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let gate = PauseGate()
        gate.pause()
        var engine = CopyEngine(kind: .copy, sources: [file], destination: destination)
        engine.pauseGate = gate
        let task = Task { await engine.run() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        #expect(result.cancelled || result.completed.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)).isEmpty)
    }

    // MARK: Estimate

    /// A simulated copy: each file costs `perFile` seconds plus its bytes at `speed` bytes/s; sampled every 50 ms.
    struct Simulation {
        var files: [Int64]
        var perFile: Double
        var speed: Double
        var estimator = TransferEstimator()
        private(set) var time = 0.0
        private(set) var bytes: Int64 = 0
        private(set) var items = 0
        private var index = 0
        private var spentOnCurrent = 0.0

        init(files: [Int64], perFile: Double, speed: Double) { self.files = files; self.perFile = perFile; self.speed = speed }

        var totalBytes: Int64 { files.reduce(0, +) }
        var remainingTruth: Double {
            guard index < files.count else { return 0 }
            let rest = files[index...].reduce(0.0) { $0 + perFile + Double($1) / speed }
            return rest - spentOnCurrent
        }

        /// Runs until `fraction` of the files are done (or `seconds` more pass).
        mutating func run(untilFiles count: Int? = nil, seconds: Double? = nil) {
            let stopTime = seconds.map { time + $0 }
            while index < files.count {
                if let count, items >= count { return }
                if let stopTime, time >= stopTime { return }
                var budget = 0.05
                while budget > 0, index < files.count {
                    let cost = perFile + Double(files[index]) / speed
                    let left = cost - spentOnCurrent
                    if left <= budget {
                        budget -= left
                        spentOnCurrent = 0
                        bytes = files[..<(index + 1)].reduce(0, +)
                        items += 1
                        index += 1
                    } else {
                        spentOnCurrent += budget
                        budget = 0
                        let done = files[..<index].reduce(0, +)
                        bytes = done + Int64(Double(files[index]) * min(1, spentOnCurrent / cost))
                    }
                }
                time += 0.05
                estimator.add(time: time, bytes: bytes, items: items)
            }
        }
    }

    @Test func pricesRemainingFilesNotJustBytes() {
        // Big and small files mixed, then thousands of small files at the end: an average byte rate would say
        // "almost done"; the fitted per-file cost knows better.
        var rng = SystemRandomNumberGenerator()
        var files: [Int64] = (0..<120).map { _ in Bool.random(using: &rng) ? 8_000_000 : 4_000 }
        files += Array(repeating: 4_000, count: 2_000)
        var sim = Simulation(files: files, perFile: 0.002, speed: 200_000_000)
        sim.run(untilFiles: 120)
        let truth = sim.remainingTruth
        let estimate = sim.estimator.rawRemaining(totalBytes: sim.totalBytes, totalItems: files.count) ?? -1
        let averageRate = Double(sim.bytes) / sim.time
        let naive = Double(sim.totalBytes - sim.bytes) / averageRate
        #expect(abs(estimate - truth) / truth < 0.15, "estimate \(estimate) s, truth \(truth) s")
        #expect(naive < truth / 5) // the naive estimate is far off here
        let costs = sim.estimator.costs
        #expect(costs.map { abs($0.perFile - 0.002) < 0.0005 } == true, "\(String(describing: costs))")
    }

    @Test func followsATrend() {
        // Same-size files (bytes and files in lockstep), then the disk gets twice as slow.
        var sim = Simulation(files: Array(repeating: 2_000_000, count: 4_000), perFile: 0.001, speed: 100_000_000)
        sim.run(seconds: 10)
        sim.speed = 50_000_000
        sim.perFile = 0.002
        sim.run(seconds: 12)
        let truth = sim.remainingTruth
        let estimate = sim.estimator.rawRemaining(totalBytes: sim.totalBytes, totalItems: 4_000) ?? -1
        #expect(abs(estimate - truth) / truth < 0.2, "estimate \(estimate) s, truth \(truth) s")
        let speed = sim.estimator.bytesPerSecond ?? 0
        #expect(abs(speed - 2_000_000 / 0.042) / (2_000_000 / 0.042) < 0.1, "speed \(speed)")
    }

    @Test func nothingBeforeWarmUpThenACountdown() {
        var sim = Simulation(files: Array(repeating: 10_000_000, count: 400), perFile: 0.001, speed: 100_000_000)
        sim.run(seconds: 1)
        #expect(sim.estimator.rawRemaining(totalBytes: sim.totalBytes, totalItems: 400) == nil) // "Estimating…"
        sim.run(seconds: 2)
        var previous = Double.infinity
        var monotonic = true
        for _ in 0..<40 {
            sim.run(seconds: 0.25)
            guard let shown = sim.estimator.remaining(totalBytes: sim.totalBytes, totalItems: 400) else { monotonic = false; break }
            if shown > previous + 0.05 { monotonic = false }
            previous = shown
        }
        #expect(monotonic)
        #expect(abs(previous - sim.remainingTruth) / sim.remainingTruth < 0.1)
    }
}
