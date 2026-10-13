import SwiftUI

/// Fixed vitals colors — deliberately distinct from any substance color and legible in
/// both light and dark. Shared by the timeline cardio lane and the entry-row HR chips so
/// they always match. HR is a warm crimson; BP a calm blue.
enum VitalsPalette {
    static let heart = Color(red: 0.898, green: 0.290, blue: 0.310)
    static let bloodPressure = Color(red: 0.231, green: 0.490, blue: 0.847)
}

/// A single heart-rate sample read from HealthKit (Apple Watch records these ~every 5 min).
nonisolated struct HeartRateSample: Hashable {
    let date: Date
    let bpm: Double
    /// Whether the sample falls inside a recorded workout. A run raises heart rate by more
    /// than any dose in the library, so a workout inside a dose's window would otherwise be
    /// read as that dose's response — the single largest confound in the whole overlay.
    var isWorkout = false
}

/// A single blood-pressure reading (systolic/diastolic) read from HealthKit. BP is sparse —
/// there is no continuous BP sensor, so these are occasional spot checks, not a curve.
nonisolated struct BloodPressureReading: Hashable {
    let date: Date
    let systolic: Double
    let diastolic: Double
}

/// Physiological vitals for one session's time window, overlaid on the timeline.
///
/// Empty arrays mean "no data" — the UI renders **nothing** rather than an empty axis, so a
/// day without an Apple Watch (or without a BP reading) shows no vitals chrome at all.
nonisolated struct SessionVitals: Hashable {
    let heartRate: [HeartRateSample]
    var bloodPressure: [BloodPressureReading]
    /// The user's resting heart rate near the session, for the "elevated vs resting" summary.
    var restingHeartRate: Double?
    /// ``heartRate`` prepared for the timeline's cardio lane. Built here, once per
    /// fetch, so panning and scrubbing the graph only read it.
    let heartRateTrace: HeartRateTrace

    init(heartRate: [HeartRateSample], bloodPressure: [BloodPressureReading], restingHeartRate: Double? = nil) {
        self.heartRate = heartRate
        self.bloodPressure = bloodPressure
        self.restingHeartRate = restingHeartRate
        heartRateTrace = HeartRateTrace(samples: heartRate)
    }

    /// The trace is derived from ``heartRate``, so equality and hashing skip it.
    static func == (lhs: SessionVitals, rhs: SessionVitals) -> Bool {
        lhs.heartRate == rhs.heartRate
            && lhs.bloodPressure == rhs.bloodPressure
            && lhs.restingHeartRate == rhs.restingHeartRate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(heartRate)
        hasher.combine(bloodPressure)
        hasher.combine(restingHeartRate)
    }

    var hasHeartRate: Bool {
        !heartRate.isEmpty
    }
    var hasBloodPressure: Bool {
        !bloodPressure.isEmpty
    }
    var isEmpty: Bool {
        heartRate.isEmpty && bloodPressure.isEmpty
    }

    static let empty = SessionVitals(heartRate: [], bloodPressure: [], restingHeartRate: nil)
}

/// Heart rate prepared for the timeline's cardio lane, computed once from the samples.
///
/// Samples are averaged into buckets anchored to absolute time (the reference date), so a
/// bucket holds the same samples wherever the graph is panned. Never anchor buckets to the
/// visible window: that regroups the samples on every pan frame and the line writhes as it
/// moves. Each zoom range has its own bucket width from ``bucketLadder``.
///
/// Within a bucket width the points split into runs at gaps the watch did not sample. A run
/// carries the tangents of the monotone cubic the lane strokes, and ``bpm(at:visibleSpan:)``
/// evaluates that same cubic, so the scrub dot and the callout sit on the drawn line and read
/// nothing in a gap or past the last reading.
nonisolated struct HeartRateTrace: Sendable {
    /// One bucket's samples, reduced.
    nonisolated struct Point: Sendable {
        /// Mean sample time, seconds since the reference date.
        let time: TimeInterval
        let mean: Double
        let low: Double
        let high: Double
        /// Tangent of the drawn curve here, bpm per second.
        let slope: Double
    }

    /// The trace at one bucket width.
    nonisolated struct Level: Sendable {
        let bucket: TimeInterval
        /// Unbroken stretches in time order. Nothing is drawn or read between two runs.
        let runs: [[Point]]
        /// The longest gap between two points that still joins them into one run.
        let maximumGap: TimeInterval
    }

    /// Bucket widths, finest first. The lane uses the finest that keeps the visible span
    /// within ``maximumPointsPerSpan`` buckets.
    static let bucketLadder: [TimeInterval] = [2, 5, 10, 15, 30, 60].map { $0 * 60 }
    static let maximumPointsPerSpan: Double = 90

    let levels: [Level]
    /// The bpm axis for the whole series: padded, snapped to 10s, at least 20 bpm tall.
    /// The same for every pan and zoom position, so the line never rescales while it moves.
    let axis: ClosedRange<Double>?

    init(samples: [HeartRateSample]) {
        let sorted = samples.sorted { $0.date < $1.date }
        guard let minimum = sorted.map(\.bpm).min(), let maximum = sorted.map(\.bpm).max() else {
            levels = []
            axis = nil
            return
        }
        let low = ((minimum - 6) / 10).rounded(.down) * 10
        var high = ((maximum + 6) / 10).rounded(.up) * 10
        if high - low < 20 { high = low + 20 }
        axis = low ... high
        levels = Self.bucketLadder.map { Self.level(bucket: $0, samples: sorted) }
    }

    /// The level drawn for a visible span of `seconds`.
    func level(forVisibleSpan seconds: TimeInterval) -> Level? {
        levels.first { seconds / $0.bucket <= Self.maximumPointsPerSpan } ?? levels.last
    }

    /// Heart rate on the drawn curve at `date`, or nil in a gap, before the first reading
    /// or after the last.
    func bpm(at date: Date, visibleSpan seconds: TimeInterval) -> Double? {
        guard let level = level(forVisibleSpan: seconds) else { return nil }
        return Self.bpm(at: date.timeIntervalSinceReferenceDate, in: level)
    }

    /// The newest point of the level, when it is recent enough at `date` to still count as
    /// the current reading.
    func latestPoint(asOf date: Date, visibleSpan seconds: TimeInterval) -> Point? {
        guard let level = level(forVisibleSpan: seconds), let last = level.runs.last?.last else { return nil }
        let age = date.timeIntervalSinceReferenceDate - last.time
        return age >= 0 && age <= level.maximumGap ? last : nil
    }

    static func bpm(at time: TimeInterval, in level: Level) -> Double? {
        for run in level.runs {
            guard let first = run.first, let last = run.last else { continue }
            if run.count == 1 {
                if abs(time - first.time) <= level.bucket / 2 { return first.mean }
                continue
            }
            guard time >= first.time, time <= last.time else { continue }
            var lower = 0
            var upper = run.count - 1
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if run[middle].time <= time { lower = middle } else { upper = middle }
            }
            return hermite(run[lower], run[upper], at: time)
        }
        return nil
    }

    /// The cubic Hermite segment between two points with their tangents — the curve a
    /// Bézier with controls at a third of the span along each tangent draws.
    static func hermite(_ a: Point, _ b: Point, at time: TimeInterval) -> Double {
        let span = b.time - a.time
        guard span > 0 else { return a.mean }
        let s = (time - a.time) / span
        let s2 = s * s, s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * a.mean
            + (s3 - 2 * s2 + s) * span * a.slope
            + (-2 * s3 + 3 * s2) * b.mean
            + (s3 - s2) * span * b.slope
    }

    private typealias Reduced = (time: TimeInterval, mean: Double, low: Double, high: Double)

    private nonisolated struct Bucket {
        let start: TimeInterval
        /// Sample times are summed as offsets from `start`, which keeps the mean exact
        /// where summing raw reference-date seconds would lose precision.
        var timeOffsetSum = 0.0
        var bpmSum = 0.0
        var count = 0.0
        var low = Double.infinity
        var high = -Double.infinity

        mutating func add(time: TimeInterval, bpm: Double) {
            timeOffsetSum += time - start
            bpmSum += bpm
            count += 1
            low = min(low, bpm)
            high = max(high, bpm)
        }

        var reduced: Reduced {
            (start + timeOffsetSum / count, bpmSum / count, low, high)
        }
    }

    private static func level(bucket: TimeInterval, samples: [HeartRateSample]) -> Level {
        var buckets: [Bucket] = []
        for sample in samples {
            let time = sample.date.timeIntervalSinceReferenceDate
            let start = (time / bucket).rounded(.down) * bucket
            if buckets.last?.start != start { buckets.append(Bucket(start: start)) }
            buckets[buckets.count - 1].add(time: time, bpm: sample.bpm)
        }
        let reduced = buckets.map(\.reduced)

        let maximumGap = max(VitalsAnalysis.maximumSampleGap, bucket * 1.5)
        var runs: [[Point]] = []
        var run: [Reduced] = []
        for point in reduced {
            if let previous = run.last, point.time - previous.time > maximumGap {
                runs.append(withTangents(run))
                run = []
            }
            run.append(point)
        }
        if !run.isEmpty { runs.append(withTangents(run)) }
        return Level(bucket: bucket, runs: runs, maximumGap: maximumGap)
    }

    /// Fritsch–Carlson tangents: adjacent secants averaged, zero at a local extremum, capped
    /// at three times the smaller neighboring secant, so no segment overshoots its endpoints.
    private static func withTangents(_ run: [Reduced]) -> [Point] {
        let count = run.count
        var slopes = [Double](repeating: 0, count: count)
        if count >= 2 {
            var secants = [Double](repeating: 0, count: count - 1)
            for i in 0 ..< count - 1 {
                let span = run[i + 1].time - run[i].time
                secants[i] = span > 0 ? (run[i + 1].mean - run[i].mean) / span : 0
            }
            slopes[0] = secants[0]
            slopes[count - 1] = secants[count - 2]
            if count > 2 {
                for i in 1 ..< count - 1 {
                    if secants[i - 1] * secants[i] <= 0 {
                        slopes[i] = 0
                    } else {
                        let average = (secants[i - 1] + secants[i]) / 2
                        let limit = 3 * min(abs(secants[i - 1]), abs(secants[i]))
                        slopes[i] = min(max(average, -limit), limit)
                    }
                }
            }
        }
        return run.indices.map { i in
            Point(time: run[i].time, mean: run[i].mean, low: run[i].low, high: run[i].high, slope: slopes[i])
        }
    }
}

/// Which way a dose's heart rate moved. ``unchanged`` means the move stayed inside
/// ``VitalsAnalysis/noiseFloor`` — the wander a wrist sensor shows from posture and
/// movement alone — so the numbers are shown without claiming a response.
nonisolated enum HRDirection: Hashable {
    case rose
    case fell
    case unchanged
}

/// One dose's heart-rate response, shown as an inline chip on its entry row:
/// HR at the moment of dosing → the extreme reached within the response window.
nonisolated struct DoseHRResponse: Hashable {
    /// HR nearest the dose time (bpm, rounded).
    let atDose: Int
    /// The furthest HR from ``atDose`` within the response window (bpm, rounded) —
    /// the peak for a dose that raised heart rate, the nadir for one that lowered it.
    /// A beta blocker's whole signal is the drop, so the extreme is chosen by distance
    /// from baseline rather than by magnitude.
    let extreme: Int
    /// `extreme - atDose` (negative when heart rate fell).
    let delta: Int
    let direction: HRDirection
    /// Other substances still in their come-up across this dose's window — whatever the
    /// numbers show is theirs as much as this dose's.
    let confounders: [String]
    /// In-window bpm values, for the row's mini sparkline.
    let sparkline: [Double]

    var isConfounded: Bool {
        !confounders.isEmpty
    }
}

/// One dose handed to the batch analysis: when it was taken, how long its own effects
/// take to arrive, and what it is called.
nonisolated struct HRDoseWindow: Hashable {
    let id: UUID
    let at: Date
    let substance: String
    /// Minutes from the dose to the end of its modeled peak — the stretch a cardiovascular
    /// response would land in. Nil for a substance with no modeled duration.
    let peakEndMinutes: Double?
    /// Minutes from the dose to the end of its modeled come-up — the stretch in which this
    /// dose is still *changing* the body, so a later dose landing inside it can't claim its
    /// own reading cleanly. Nil for a substance with no modeled duration.
    let comeUpEndMinutes: Double?
}

/// Session-wide heart-rate summary for the Summary card.
nonisolated struct HRSummary: Hashable {
    let average: Int
    let peak: Int
    /// Resting HR baseline, if known (for "elevated vs your resting N bpm").
    let resting: Int?
    /// Minutes of the window spent in a recorded workout. Both figures above include it —
    /// they describe the session as it happened — so this is what stops a post-run peak
    /// from reading as something a dose did.
    var workoutMinutes = 0
}

/// Pure heart-rate analysis over sample arrays — no HealthKit, no view state, so it's unit-testable.
nonisolated enum VitalsAnalysis {
    /// Response window for a dose whose substance has no modeled duration.
    static let responseWindow: TimeInterval = 45 * 60
    /// Floor on a duration-derived window, so a fast substance's few-minute peak still
    /// spans enough of a ~5-minute-cadence sample series to describe anything.
    static let minimumWindow: TimeInterval = 30 * 60
    /// Cap on a duration-derived window: past three hours the reading stops being *this*
    /// dose's response and becomes the afternoon's.
    static let maximumWindow: TimeInterval = 3 * 3_600
    /// How far *before* the dose to accept a sample as the "at dose" baseline.
    static let baselineLookback: TimeInterval = 20 * 60
    /// Swing a wrist sensor shows at rest from posture, movement and breathing alone.
    /// A delta under this is reported as measured but not as a response.
    static let noiseFloor = 8
    /// Fewest in-window samples that can describe a change rather than assert one.
    static let minimumSamples = 2
    /// Shortest first-to-last span of in-window samples worth reading. Two samples a
    /// minute apart describe that minute, not the dose.
    static let minimumSpan: TimeInterval = 10 * 60

    /// Per-dose heart-rate responses for a whole session, keyed by dose id.
    ///
    /// Two things the single-dose call can't do on its own, and the reason the session
    /// goes through here: each dose's window is cut short at the **next** dose, so one
    /// rise is never counted as three separate responses to a re-dose; and a dose taken
    /// while something else is still coming up carries that substance in
    /// ``DoseHRResponse/confounders`` rather than quietly taking credit for it.
    static func doseResponses(for doses: [HRDoseWindow], in samples: [HeartRateSample]) -> [UUID: DoseHRResponse] {
        guard !samples.isEmpty, !doses.isEmpty else { return [:] }
        let readable = samples.filter { !$0.isWorkout }
        let ordered = doses.sorted { $0.at < $1.at }
        var out: [UUID: DoseHRResponse] = [:]
        for (index, dose) in ordered.enumerated() {
            let modeled = dose.peakEndMinutes.map { min(max($0 * 60, minimumWindow), maximumWindow) }
            var end = dose.at.addingTimeInterval(modeled ?? responseWindow)
            if index + 1 < ordered.count {
                end = min(end, ordered[index + 1].at)
            }
            // Same-substance re-doses are left out: the reading is still that substance's,
            // and naming it as its own confounder says nothing the row doesn't already show.
            let confounders = ordered[..<index]
                .filter { earlier in
                    earlier.substance.caseInsensitiveCompare(dose.substance) != .orderedSame
                        && (earlier.comeUpEndMinutes.map { earlier.at.addingTimeInterval($0 * 60) > dose.at } ?? false)
                }
                .map(\.substance)
            if let response = response(doseAt: dose.at, until: end, in: readable, confounders: uniqued(confounders)) {
                out[dose.id] = response
            }
        }
        return out
    }

    /// The heart-rate response to a single dose over a fixed window, or `nil` when the
    /// samples in it are too few or too bunched to describe one.
    static func doseResponse(
        doseAt: Date,
        in samples: [HeartRateSample],
        window: TimeInterval = responseWindow,
    ) -> DoseHRResponse? {
        response(
            doseAt: doseAt, until: doseAt.addingTimeInterval(window),
            in: samples.filter { !$0.isWorkout }, confounders: [],
        )
    }

    private static func response(
        doseAt: Date,
        until end: Date,
        in samples: [HeartRateSample],
        confounders: [String],
    ) -> DoseHRResponse? {
        guard end > doseAt else { return nil }
        let inWindow = samples
            .filter { $0.date >= doseAt && $0.date <= end }
            .sorted { $0.date < $1.date }
        guard inWindow.count >= minimumSamples,
              let first = inWindow.first, let last = inWindow.last,
              last.date.timeIntervalSince(first.date) >= minimumSpan
        else { return nil }

        // Baseline = the most recent sample just before the dose (within `baselineLookback`);
        // fall back to the first in-window sample when nothing precedes the dose.
        let baselineWindowStart = doseAt.addingTimeInterval(-baselineLookback)
        let before = samples
            .filter { $0.date <= doseAt && $0.date >= baselineWindowStart }
            .max(by: { $0.date < $1.date })
        let atSample = before ?? first

        let at = Int(atSample.bpm.rounded())
        // Furthest from baseline in either direction, so a dose that lowered heart rate
        // reports its nadir instead of the meaningless highest sample of the window.
        let extremeSample = inWindow.max { abs($0.bpm - atSample.bpm) < abs($1.bpm - atSample.bpm) }!
        let extreme = Int(extremeSample.bpm.rounded())
        let delta = extreme - at
        let direction: HRDirection = abs(delta) < noiseFloor ? .unchanged : (delta > 0 ? .rose : .fell)
        return DoseHRResponse(
            atDose: at, extreme: extreme, delta: delta, direction: direction,
            confounders: confounders, sparkline: inWindow.map(\.bpm),
        )
    }

    /// Time covered by workout samples, measured the same gap-capped way the average is
    /// weighted: only a stretch *between two* workout samples counts, so one stray flagged
    /// sample contributes nothing.
    private static func workoutSpan(of samples: [HeartRateSample]) -> TimeInterval {
        zip(samples, samples.dropFirst())
            .filter { $0.isWorkout && $1.isWorkout }
            .reduce(0) { $0 + min($1.1.date.timeIntervalSince($1.0.date), maximumSampleGap) }
    }

    /// Order-preserving dedup, so "overlaps Caffeine, Caffeine" can't happen.
    private static func uniqued(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Longest gap between samples that still counts as measured time in the average.
    /// Past it the watch simply wasn't looking, and stretching two readings across the
    /// hole would let a single pre-nap sample outweigh an hour of the session.
    static let maximumSampleGap: TimeInterval = 15 * 60

    /// The session-wide heart-rate summary over `[start, end]`, or `nil` if no samples fall inside.
    ///
    /// The average is **time-weighted**. A wrist sensor bursts to seconds-apart samples during
    /// movement and idles at five-minute intervals at rest, so counting every sample equally
    /// reports the average of whatever the user was doing most actively rather than the average
    /// of the session. The peak is the plain maximum: a real beat the watch recorded is worth
    /// reporting even when a staircase, not the dose, caused it.
    ///
    /// Workout samples stay in both figures — this describes the session, not the doses — and
    /// are reported separately as ``HRSummary/workoutMinutes``. The per-dose chips are the
    /// place a workout must not appear, and ``doseResponses(for:in:)`` drops it there.
    static func summary(
        from start: Date,
        to end: Date,
        heartRate: [HeartRateSample],
        restingHeartRate: Double?,
    ) -> HRSummary? {
        let inWindow = heartRate
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
        guard let firstSample = inWindow.first else { return nil }
        let peak = Int((inWindow.map(\.bpm).max() ?? 0).rounded())
        let resting = restingHeartRate.map { Int($0.rounded()) }

        var weighted = 0.0
        var weight = 0.0
        for (previous, next) in zip(inWindow, inWindow.dropFirst()) {
            let span = min(next.date.timeIntervalSince(previous.date), maximumSampleGap)
            weighted += (previous.bpm + next.bpm) / 2 * span
            weight += span
        }
        let average = weight > 0 ? weighted / weight : firstSample.bpm
        return HRSummary(
            average: Int(average.rounded()), peak: peak, resting: resting,
            workoutMinutes: Int((workoutSpan(of: inWindow) / 60).rounded()),
        )
    }
}
