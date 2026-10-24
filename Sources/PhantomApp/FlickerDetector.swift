import Foundation
import CoreGraphics

/// Detects lighting flicker by tracking frame-to-frame brightness.
///
/// At high frame rates a light's AC ripple (mains, cheap LED/HMI ballasts)
/// shows up as periodic brightness pulsing. We feed in each frame's mean luma,
/// keep a rolling window, and report:
///   - amplitude: peak-to-peak brightness swing as % of mean (the "how bad")
///   - frequencyHz: dominant ripple frequency, if the capture frame rate is known
///   - a sparkline of recent samples for a live meter
///
/// Brightness sampling is cheap (a coarse subsample) and lives on whatever
/// thread already has the pixels; only the published summary hops to main.
@MainActor
final class FlickerDetector: ObservableObject {
    struct Reading {
        var amplitudePct: Double = 0      // whole-frame peak-to-peak / mean, % (temporal)
        var frequencyHz: Double = 0       // 0 = unknown / not enough info
        var flickering: Bool = false      // temporal OR banding tripped
        var trace: [Double] = []          // recent normalized samples 0..1 for the meter
        var bandingPct: Double = 0        // rolling intra-frame banding, % of frame mean (spatial)
        var banding: Bool = false         // banding tripped its threshold
    }

    @Published var enabled = false
    @Published var reading = Reading()
    /// Warn threshold: whole-frame (temporal) peak-to-peak brightness swing, %.
    @Published var thresholdPct: Double = 2.0
    /// Warn threshold for rolling banding (spatial), % of frame mean. Banding
    /// reads lower than the temporal swing, so its trip point is lower.
    @Published var bandingThresholdPct: Double = 1.0

    /// The frame rate the samples arrive at — set this to the camera's record
    /// rate for live, or the playback rate for playback, to get a frequency.
    var sampleRateHz: Double = 0

    private var samples: [Double] = []        // raw mean luma history
    private let maxSamples = 180

    // Rolling-band state: a per-row temporal average. Static scene content (even
    // a striped color chart) settles into this average and cancels out; only
    // bands that TRAVEL between frames survive in the residual.
    private var rowEMA: [Double] = []
    private var bandingPctStore = 0.0

    /// When true, push() runs even if the live `enabled` toggle is off —
    /// used by the one-shot clip scan.
    var forceSampling = false

    /// Feed one frame's mean luma (any scale — we normalize internally).
    func push(meanLuma: Double) {
        guard enabled || forceSampling else { return }
        samples.append(meanLuma)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        guard samples.count >= 16 else { return }
        analyze()
    }

    /// Feed one frame's per-row luma profile to detect rolling banding (PWM LEDs,
    /// rolling-shutter × flicker). Static content cancels via the per-row average;
    /// only bands that move frame-to-frame register in the residual.
    func pushBanding(profile: [Double]) {
        guard enabled || forceSampling, profile.count >= 8 else { return }
        if rowEMA.count != profile.count { rowEMA = profile; return }   // seed
        let a = 0.12
        var residSq = 0.0, meanSum = 0.0
        for i in 0..<profile.count {
            rowEMA[i] = (1 - a) * rowEMA[i] + a * profile[i]
            let r = profile[i] - rowEMA[i]
            residSq += r * r
            meanSum += profile[i]
        }
        let mean = meanSum / Double(profile.count)
        guard mean > 0.5 else { return }
        let rms = (residSq / Double(profile.count)).squareRoot()
        // Peak-to-peak of a sinusoidal band ≈ 2√2·RMS — report as % of frame mean.
        let pct = 2.83 * rms / mean * 100.0
        bandingPctStore = bandingPctStore * 0.6 + pct * 0.4    // smooth jitter
        reading.bandingPct = bandingPctStore
        reading.banding = bandingPctStore >= bandingThresholdPct
        if reading.banding { reading.flickering = true }
    }

    func reset() {
        samples.removeAll()
        rowEMA.removeAll()
        bandingPctStore = 0
        reading = Reading()
    }

    private func analyze() {
        let mean = samples.reduce(0, +) / Double(samples.count)
        guard mean > 0.0001 else { return }
        let lo = samples.min() ?? mean
        let hi = samples.max() ?? mean
        let amp = (hi - lo) / mean * 100.0

        // Dominant frequency via autocorrelation on the mean-removed signal.
        var freq = 0.0
        if sampleRateHz > 0 {
            let centered = samples.map { $0 - mean }
            let n = centered.count
            var bestLag = 0
            var bestCorr = 0.0
            // Search lags 2…n/2; a strong periodic peak = flicker period.
            let minLag = 2, maxLag = n / 2
            if maxLag > minLag {
                for lag in minLag...maxLag {
                    var c = 0.0
                    for i in 0..<(n - lag) { c += centered[i] * centered[i + lag] }
                    if c > bestCorr { bestCorr = c; bestLag = lag }
                }
                // Energy normalizer to reject noise-only "peaks".
                let energy = centered.reduce(0) { $0 + $1 * $1 }
                if bestLag > 0, energy > 0, bestCorr / energy > 0.3 {
                    freq = sampleRateHz / Double(bestLag)
                }
            }
        }

        // Normalized trace for the meter.
        let span = max(hi - lo, 0.0001)
        let trace = samples.suffix(120).map { ($0 - lo) / span }

        // Temporal flicker must be PERIODIC (freq found) — a one-way pan or
        // exposure change has a huge amplitude but no periodicity, so it no
        // longer trips the meter.
        let flick = amp >= thresholdPct && freq > 0
        let band = bandingPctStore >= bandingThresholdPct
        reading = Reading(amplitudePct: amp, frequencyHz: freq,
                          flickering: flick || band, trace: Array(trace),
                          bandingPct: bandingPctStore, banding: band)
    }

    // MARK: - Sampling helpers

    /// Mean luma of a CGImage (BGRA8), coarse-subsampled. For the SDI path.
    static func meanLuma(of image: CGImage) -> Double? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let w = image.width, h = image.height
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        var sum = 0.0, count = 0
        var y = 0
        while y < h {
            var x = 0
            let row = ptr + y * bpr
            while x < w {
                let p = row + x * bpp
                // BGRA or RGBA — luma is order-independent enough for flicker.
                sum += 0.2126 * Double(p[2]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[0])
                count += 1
                x += 16
            }
            y += 8
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
