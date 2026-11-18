import Foundation
import Synchronization

/// Pause / resume for a running operation (P3-4). The engine calls `waitIfPaused` between items and from copyfile's
/// progress callback (so a large file pauses mid-way); it blocks the operation's own thread (never the main thread)
/// until resumed or cancelled.
public final class PauseGate: Sendable {
    private let condition = NSCondition()
    private let paused = Atomic<Bool>(false)

    public init() {}

    public var isPaused: Bool { paused.load(ordering: .relaxed) }

    public func pause() { paused.store(true, ordering: .relaxed) }

    public func resume() {
        condition.lock()
        paused.store(false, ordering: .relaxed)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks while paused; returns early when `cancel` is set (checked every 100 ms).
    public func waitIfPaused(_ cancel: CancellationFlag?) {
        guard isPaused else { return }
        condition.lock()
        while isPaused && !(cancel?.isCancelled ?? false) {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        condition.unlock()
    }
}

/// Speed and time left for a copy/move (P3-4) — more than "bytes left ÷ average speed".
///
/// Copying is two costs: moving bytes, and a fixed cost per file (create, metadata, xattrs, rename). A folder of
/// photos is throughput-bound, a source tree is per-file bound, and an average over the whole run gets both wrong
/// whenever the mix changes (a few big files first, thousands of small ones last). So the estimator models
/// `seconds ≈ c · (megabytes + r · files)`: the mix `r` (what one file costs, in megabytes' worth of time) comes from a
/// least-squares fit of `seconds ≈ a · MB + b · files` on the deltas between samples (r = b / a), and the scale `c`
/// from recent time over recent work — a ratio of sums, which weights every second alike (least squares alone would
/// favour the fast stretches). The remaining bytes *and* files are priced with it. Older samples fade (half-life
/// `halfLife` seconds of active time), so a trend — a slower disk region, a full cache, thermal throttling, another
/// copy starting — shows up within seconds. When the history can't tell the two costs apart (every file the same
/// size), `r` is a prior per-file cost. The time shown counts down between updates and moves
/// toward each new estimate gradually, so it doesn't jump around.
///
/// Time is *active* time: the caller leaves out paused periods and time spent waiting for an answer (conflicts,
/// errors).
public struct TransferEstimator: Sendable {
    /// Seconds (active time) for a sample's weight to halve.
    public var halfLife: Double = 8
    /// Before this much active time, or this few samples, there's no estimate ("Estimating…").
    public var warmUp: Double = 1.0
    /// The per-file cost assumed when the history can't separate it, in megabyte-equivalents.
    public var priorMBPerFile: Double = 0.25

    private var last: (t: Double, bytes: Int64, items: Int)?
    private var first: (t: Double, bytes: Int64, items: Int)?
    /// Deltas are gathered until they span `step` seconds (samples arrive every ~50 ms; that's noise).
    private var pending: (dt: Double, mb: Double, files: Double) = (0, 0, 0)
    private let step = 0.25
    // Exponentially weighted sums for the two-variable fit (x = MB, y = files, t = seconds).
    private var sxx = 0.0, sxy = 0.0, syy = 0.0, sxt = 0.0, syt = 0.0, steps = 0
    // Exponentially weighted totals (time, MB, files) for the scale.
    private var st = 0.0, sx = 0.0, sy = 0.0
    // Recent speeds (EWMA, half-life `speedHalfLife`).
    private var mbPerSecond: Double?
    private var filesPerSecond: Double?
    private let speedHalfLife = 2.5
    private var smoothed: (remaining: Double, at: Double)?

    public init() {}

    /// Feeds the totals done so far at active time `t` (seconds since the operation started moving data).
    public mutating func add(time t: Double, bytes: Int64, items: Int) {
        guard let previous = last else {
            last = (t, bytes, items)
            first = last
            return
        }
        let dt = t - previous.t
        guard dt > 0 else { return }
        last = (t, bytes, items)
        pending.dt += dt
        pending.mb += Double(bytes - previous.bytes) / 1_000_000
        pending.files += Double(items - previous.items)
        guard pending.dt >= step else { return }
        let (d, x, y) = pending
        pending = (0, 0, 0)
        let decay = pow(0.5, d / halfLife)
        sxx = sxx * decay + x * x
        sxy = sxy * decay + x * y
        syy = syy * decay + y * y
        sxt = sxt * decay + x * d
        syt = syt * decay + y * d
        st = st * decay + d
        sx = sx * decay + x
        sy = sy * decay + y
        steps += 1
        let speedDecay = pow(0.5, d / speedHalfLife)
        mbPerSecond = mbPerSecond.map { $0 * speedDecay + (x / d) * (1 - speedDecay) } ?? x / d
        filesPerSecond = filesPerSecond.map { $0 * speedDecay + (y / d) * (1 - speedDecay) } ?? y / d
    }

    /// Recent throughput.
    public var bytesPerSecond: Double? { mbPerSecond.map { $0 * 1_000_000 } }
    public var itemsPerSecond: Double? { filesPerSecond }

    /// The fitted costs: seconds per megabyte and per file (nil until there's enough to go on).
    public var costs: (perMB: Double, perFile: Double)? {
        guard steps >= 3, st > 0 else { return nil }
        // The mix: from the two-variable fit when bytes and files didn't move in lockstep.
        var mix = priorMBPerFile
        let det = sxx * syy - sxy * sxy
        if sxx > 0, syy > 0, det > 0.02 * sxx * syy {
            let a = (sxt * syy - syt * sxy) / det
            let b = (syt * sxx - sxt * sxy) / det
            if a <= 0, b > 0, sy > 0 { return (0, st / sy) } // only files cost anything (empty files, folders)
            if b <= 0, a > 0, sx > 0 { return (st / sx, 0) } // only bytes do
            if a > 0, b > 0 { mix = b / a }
        }
        // The scale: recent time over recent work.
        let work = sx + mix * sy
        guard work > 0 else { return nil }
        let c = st / work
        return (c, c * mix)
    }

    /// The raw estimate of the seconds left for the remaining bytes and files.
    public func rawRemaining(totalBytes: Int64, totalItems: Int) -> Double? {
        guard let last, let first, last.t - first.t >= warmUp, let costs else { return nil }
        let mb = Double(max(0, totalBytes - last.bytes)) / 1_000_000
        let files = Double(max(0, totalItems - last.items))
        return costs.perMB * mb + costs.perFile * files
    }

    /// The time left to show: counts down between updates and eases toward each new estimate.
    public mutating func remaining(totalBytes: Int64, totalItems: Int) -> Double? {
        guard let raw = rawRemaining(totalBytes: totalBytes, totalItems: totalItems), let now = last?.t else { return nil }
        guard let previous = smoothed else {
            smoothed = (raw, now)
            return raw
        }
        let predicted = max(0, previous.remaining - (now - previous.at))
        // Far off (twice / half): catch up quickly; otherwise ease (≈ a quarter of the gap per update).
        let ratio = predicted > 0 ? raw / predicted : 10
        let alpha = ratio > 2 || ratio < 0.5 ? 0.5 : 0.25
        let value = max(0, predicted + alpha * (raw - predicted))
        smoothed = (value, now)
        return value
    }
}
