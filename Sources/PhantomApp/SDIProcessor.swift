import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// SmallHD-style monitor tools for the SDI capture feed.
/// Taps raw frames from the capture session and runs a Core Image chain on
/// the GPU: 3D LUT, false color, focus peaking, zebras, invert, flips —
/// plus a luma histogram for the exposure panel.
final class SDIProcessor: NSObject, ObservableObject {
    struct Tools: Equatable {
        var falseColor = false
        var falseColorMode = "arri"       // arri / spectrum / elzone
        var showLegend = true             // band legend with false color
        var peaking = false
        var peakingThreshold: Double = 0.3  // lower = more edges highlighted
        var peakingColor = "red"            // red / yellow / green / blue
        var zebra = false
        var zebraLevel: Double = 0.95     // luma threshold 0..1
        var invert = false
        var flipH = false
        var flipV = false
        var rotate = 0                    // display rotation, degrees CW (0/90/180/270) — vertical mode
        var anamorphic: Double = 1.0      // desqueeze factor (1.0 off · 1.33 / 1.5 / 1.8 / 2.0) — display only
        var flickerMap = false            // highlight areas that flicker over time
        var lutName: String = ""          // display name of loaded LUT
    }

    static let falseColorModes: [(id: String, name: String)] =
        [("arri", "ARRI"), ("spectrum", "Spectrum"), ("elzone", "EL Zone")]

    /// Legend bands (label, IRE/stop range, swatch) for the active mode.
    static func falseColorLegend(_ mode: String) -> [(String, String, Color)] {
        switch mode {
        case "spectrum":
            return [
                ("Clip", "100", .red),
                ("Highlight", "75", .yellow),
                ("Mid", "50", .green),
                ("Shadow", "25", Color(red: 0.2, green: 0.4, blue: 1)),
                ("Crush", "0", Color(red: 1, green: 0.2, blue: 0.8)),
            ]
        case "elzone":
            return [
                ("Over", "100", .white),
                ("+2", "82–95", Color(red: 1, green: 0.3, blue: 0)),
                ("+1", "70–82", .orange),
                ("Mid+", "58–70", Color(red: 0.8, green: 0.9, blue: 0)),
                ("18% grey", "50–58", Color(white: 0.5)),
                ("Mid−", "42–50", .green),
                ("−1", "30–42", Color(red: 0, green: 0.7, blue: 1)),
                ("−2", "18–30", Color(red: 0.2, green: 0.2, blue: 1)),
                ("−3", "9–18", .purple),
                ("Under", "0–9", .black),
            ]
        default: // ARRI
            return [
                ("Clipped", "96–100", .red),
                ("Hot", "88–96", .orange),
                ("Near clip", "78–88", .yellow),
                ("Skin", "52–58", Color(red: 1, green: 0.6, blue: 0.7)),
                ("18% grey", "42–48", .green),
                ("Shadow", "10–20", Color(red: 0.3, green: 0.6, blue: 1)),
                ("Deep shadow", "2–10", .blue),
                ("Crushed", "0–2", .purple),
            ]
        }
    }

    @Published var tools = Tools()
    @Published var processedImage: CGImage?
    /// Aspect ratio (w/h) of the current frame — for placing overlays on the
    /// picture rather than the letterbox.
    var imageAspect: CGFloat {
        guard let i = processedImage, i.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(i.width) / CGFloat(i.height)
    }
    @Published var histogram: [Float] = []     // 64 luma bins, normalized
    @Published var showHistogram = false
    @Published var showWaveform = false
    @Published var showVectorscope = false
    @Published var waveformImage: CGImage?
    @Published var vectorscopeImage: CGImage?

    // Scope layout (shared by all scopes), persisted across launches.
    @Published var scopeCorner: Int = UserDefaults.standard.object(forKey: "scopeCorner") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(scopeCorner, forKey: "scopeCorner") }   // 0 TL · 1 TR · 2 BL · 3 BR
    }
    @Published var scopeScale: Double = UserDefaults.standard.object(forKey: "scopeScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(scopeScale, forKey: "scopeScale") }     // 0.6 … 1.8
    }
    @Published var scopeLightBG: Bool = UserDefaults.standard.bool(forKey: "scopeLightBG") {
        didSet { UserDefaults.standard.set(scopeLightBG, forKey: "scopeLightBG") }
    }

    /// PICTURE-altering tools — false color, peaking, zebra, invert, flips,
    /// rotate, flicker map, or a loaded LUT. ONLY these need the processed
    /// CGImage on the main viewer; a scope on its own must NOT drag the live
    /// picture onto the slower Core-Image path — it should stay on the smooth
    /// hardware preview layer while the scope reads the raw buffer.
    var needsProcessedPicture: Bool { tools != Tools() }
    /// Any scope panel is showing.
    var needsScopes: Bool { showHistogram || showWaveform || showVectorscope }
    /// Anything on at all. Still drives the secondary CGImage feed (the external
    /// Video Out window + the phone mirror, which can't use the hardware layer).
    var isActive: Bool { needsProcessedPicture || needsScopes }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "sdi.processor", qos: .userInteractive)
    private var lutFilter: CIFilter?
    private var frameCount = 0

    // MARK: Spatial flicker map
    /// Per-tile brightness history (ring buffer). A tile whose brightness
    /// oscillates over the recent window is painted red over the picture, so a
    /// single flickering light or banding in the highlights stands out.
    private let fgw = 40, fgh = 22, fhist = 45
    private var ftile: [Float] = []        // fgw*fgh*fhist, column-major per tile
    private var ftileCol = 0
    private var ftileCount = 0
    /// Peak-to-peak / mean threshold for a tile to count as flickering (lower =
    /// more sensitive). ~0.045 catches mild banding without flagging noise.
    @Published var flickerSensitivity: Float = 0.045

    func resetFlickerGrid() {
        ftileCount = 0; ftileCol = 0
    }

    // MARK: Flicker SAMPLE (record ~3 s, then analyze + freeze a localized map)
    // A deliberate capture beats a jittery live overlay: we collect N frames of a
    // fine tile grid, then flag tiles that PULSE over time (flashing) or differ
    // from their vertical neighbours in the time-average (stationary banding). The
    // result freezes as a red heatmap so it's clear WHERE the flicker is (e.g. one
    // spotlight) while the rest of the frame stays clean.
    private let sgw = 24, sgh = 120          // sample grid (finer vertically for bands)
    private var sampleTarget = 0
    private var sampleBuf: [[Float]] = []
    private(set) var frozenFlickerGrid: CIImage?
    var onFlickerSampleProgress: ((Double) -> Void)?
    var onFlickerSampleDone: ((String) -> Void)?

    var isSamplingFlicker: Bool { sampleTarget > 0 }

    func startFlickerSample(frames: Int) {
        frozenFlickerGrid = nil
        sampleBuf.removeAll(keepingCapacity: true)
        sampleTarget = max(frames, 8)
    }

    func clearFlickerSample() {
        frozenFlickerGrid = nil
        sampleTarget = 0
        sampleBuf.removeAll(keepingCapacity: false)
    }

    /// Fired for every delivered sample buffer, on `queue`. Lets the capture
    /// manager tell "session opened" apart from "frames are actually arriving".
    var onFrameArrived: ((Int, Int, OSType) -> Void)?

    func attach(to session: AVCaptureSession) {
        guard !session.outputs.contains(output) else { return }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // Pin BGRA only if this output actually offers it. AVFoundation inserts
        // the conversion transparently for every device tested, so this is
        // belt-and-braces rather than a fix — but an unsatisfiable videoSettings
        // demand throws, and it must be set AFTER addOutput for
        // availableVideoPixelFormatTypes to reflect the real connection.
        //
        // Do NOT relax this to accept the device's native format without also
        // fixing the raw scanners (rowProfile/meanLuma/computeHistogram/
        // computeWaveform/computeVectorscope/tileLuma): they index packed BGRA
        // as x*4 against bytesPerRow, which on a 2vuy or v210 buffer reads off
        // the end of the allocation.
        if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        } else {
            NSLog("[SDI] 32BGRA unavailable on this output; using device-native pixel format")
            output.videoSettings = [:]
        }
    }

    // MARK: 3D LUT (.cube files)

    func loadLUT(from url: URL) {
        guard let (data, size) = Self.parseCube(url: url) else {
            DispatchQueue.main.async { self.tools.lutName = "LUT load failed" }
            return
        }
        let f = CIFilter.colorCubeWithColorSpace()
        f.cubeData = data
        f.cubeDimension = Float(size)
        f.colorSpace = CGColorSpaceCreateDeviceRGB()
        lutFilter = f
        DispatchQueue.main.async { self.tools.lutName = url.deletingPathExtension().lastPathComponent }
    }

    func clearLUT() {
        lutFilter = nil
        tools.lutName = ""
    }

    /// Minimal .cube parser (Resolve/Adobe standard).
    static func parseCube(url: URL) -> (Data, Int)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.isEmpty { continue }
            if t.uppercased().hasPrefix("LUT_3D_SIZE") {
                size = Int(t.split(separator: " ").last ?? "0") ?? 0
                values.reserveCapacity(size * size * size * 4)
                continue
            }
            let parts = t.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 {
                values.append(contentsOf: [parts[0], parts[1], parts[2], 1.0])
            }
        }
        guard size > 1, values.count == size * size * size * 4 else { return nil }
        return (values.withUnsafeBufferPointer { Data(buffer: $0) }, size)
    }

    // MARK: False color cube (IRE bands, SmallHD-ish)

    /// Pre-built false-color cubes, one per mode (built once, thread-safe).
    private static let falseColorCubes: [String: CIFilter] = [
        "arri": buildFalseColorCube(arriBand),
        "spectrum": buildFalseColorCube(spectrumBand),
        "elzone": buildFalseColorCube(elZoneBand),
    ]
    private static func falseColorCube(_ mode: String) -> CIFilter {
        falseColorCubes[mode] ?? falseColorCubes["arri"]!
    }

    private static func buildFalseColorCube(_ band: (Float) -> (Float, Float, Float)) -> CIFilter {
        let n = 64
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let luma = 0.2126 * Float(r) / Float(n - 1)
                             + 0.7152 * Float(g) / Float(n - 1)
                             + 0.0722 * Float(b) / Float(n - 1)
                    let (cr, cg, cb) = band(luma)
                    cube[i] = cr; cube[i + 1] = cg; cube[i + 2] = cb; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        let f = CIFilter.colorCubeWithColorSpace()
        f.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        f.cubeDimension = Float(n)
        f.colorSpace = CGColorSpaceCreateDeviceRGB()
        return f
    }

    // ARRI-style IRE bands.
    private static func arriBand(_ l: Float) -> (Float, Float, Float) {
        switch l {
        case ..<0.02: return (0.5, 0.0, 0.8)     // crushed: purple
        case ..<0.10: return (0.0, 0.0, 1.0)     // deep shadow: blue
        case ..<0.20: return (0.3, 0.6, 1.0)     // shadow: light blue
        case ..<0.42: return (0.45, 0.45, 0.45)  // low-mid: gray
        case ..<0.48: return (0.0, 0.8, 0.0)     // 18% gray: green
        case ..<0.52: return (0.55, 0.55, 0.55)  // mid gray
        case ..<0.58: return (1.0, 0.6, 0.7)     // skin: pink
        case ..<0.78: return (0.7, 0.7, 0.7)     // high-mid: light gray
        case ..<0.88: return (1.0, 1.0, 0.0)     // highlight: yellow
        case ..<0.96: return (1.0, 0.5, 0.0)     // hot: orange
        default:      return (1.0, 0.0, 0.0)     // clipped: red
        }
    }

    // Smooth spectrum: pink → blue → green → yellow → red across exposure.
    private static func spectrumBand(_ l: Float) -> (Float, Float, Float) {
        let hue = (1 - max(0, min(1, l))) * 300.0   // 300° magenta … 0° red
        return hsvToRGB(hue, 1, 1)
    }

    // EL-Zone-style stops: black (under) → grey (middle) → white (over).
    private static func elZoneBand(_ l: Float) -> (Float, Float, Float) {
        switch l {
        case ..<0.025: return (0, 0, 0)            // under / clip black
        case ..<0.09:  return (0.5, 0.0, 0.7)      // −3: purple
        case ..<0.18:  return (0.2, 0.2, 1.0)      // −2: blue
        case ..<0.30:  return (0.0, 0.7, 1.0)      // −1: cyan
        case ..<0.42:  return (0.0, 0.8, 0.3)      // mid−: green
        case ..<0.50:  return (0.5, 0.5, 0.5)      // 18% grey
        case ..<0.58:  return (0.6, 0.85, 0.0)     // mid+: yellow-green
        case ..<0.70:  return (0.9, 0.9, 0.0)      // +1: yellow
        case ..<0.82:  return (1.0, 0.6, 0.0)      // +2: orange
        case ..<0.95:  return (1.0, 0.25, 0.0)     // +3: red-orange
        default:       return (1, 1, 1)            // over / clip white
        }
    }

    private static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Float, Float, Float)
        switch h {
        case ..<60:   (r, g, b) = (c, x, 0)
        case ..<120:  (r, g, b) = (x, c, 0)
        case ..<180:  (r, g, b) = (0, c, x)
        case ..<240:  (r, g, b) = (0, x, c)
        case ..<300:  (r, g, b) = (x, 0, c)
        default:      (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    // MARK: Frame processing

    /// The most recent raw SDI frame, kept so a screen-grab works even when no
    /// monitor tool is active (we skip the per-frame CGImage build then).
    private var latestBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    /// Builds a CGImage from the latest SDI frame on demand — for "grab frame".
    func latestFrameImage() -> CGImage? {
        bufferLock.lock(); let pb = latestBuffer; bufferLock.unlock()
        guard let pb else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        bufferLock.lock(); latestBuffer = pixelBuffer; bufferLock.unlock()
        // When no monitor tool is active, do NOT build a CGImage every frame —
        // that heavy Core Image → CGImage → SwiftUI path can't hold 30fps and
        // made the feed jittery. Instead let the viewer show the hardware
        // AVCaptureVideoPreviewLayer (smooth). Cheap flicker sampling still runs.
        guard isActive else {
            if processedImage != nil { DispatchQueue.main.async { self.processedImage = nil } }
            if sampleFlicker, let prof = Self.rowProfile(of: pixelBuffer) {
                onFlickerSample?(prof.reduce(0, +) / Double(prof.count))
                onBandingSample?(prof)
            }
            return
        }
        var img = CIImage(cvPixelBuffer: pixelBuffer)
        let t = tools

        if t.flipH || t.flipV {
            let sx: CGFloat = t.flipH ? -1 : 1
            let sy: CGFloat = t.flipV ? -1 : 1
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
                .translatedBy(x: t.flipH ? -img.extent.width : 0,
                              y: t.flipV ? -img.extent.height : 0))
        }
        // Vertical mode: rotate the whole frame in 90° steps (camera on its side),
        // then re-anchor the extent to the origin so downstream sizing is correct.
        if t.rotate % 360 != 0 {
            let rotated = img.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-t.rotate) * .pi / 180))
            img = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                                            y: -rotated.extent.origin.y))
        }
        // Anamorphic desqueeze: stretch horizontally by the lens's squeeze factor
        // so the monitor shows the true taking aspect. Display-only — the camera
        // keeps recording the squeezed frame. Re-anchor the extent to the origin.
        if t.anamorphic != 1.0 {
            let wide = img.transformed(by: CGAffineTransform(scaleX: CGFloat(t.anamorphic), y: 1))
            img = wide.transformed(by: CGAffineTransform(translationX: -wide.extent.origin.x,
                                                         y: -wide.extent.origin.y))
        }
        if let lut = lutFilter, !t.falseColor {
            lut.setValue(img, forKey: kCIInputImageKey)
            img = lut.outputImage ?? img
        }
        if t.invert {
            let f = CIFilter.colorInvert()
            f.inputImage = img
            img = f.outputImage ?? img
        }
        if t.falseColor {
            let f = Self.falseColorCube(t.falseColorMode)
            f.setValue(img, forKey: kCIInputImageKey)
            img = f.outputImage ?? img
        }
        if t.zebra {
            // paint luma above threshold magenta
            let mono = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            let thresh = mono.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": t.zebraLevel])
            let magenta = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: img.extent)
            img = magenta.applyingFilter("CIBlendWithMask",
                                         parameters: [kCIInputBackgroundImageKey: img,
                                                      kCIInputMaskImageKey: thresh])
        }
        if t.peaking {
            let edges = img.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4.0])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": t.peakingThreshold])
            let colors: [String: CIColor] = ["red": .init(red: 1, green: 0, blue: 0),
                                             "yellow": .init(red: 1, green: 1, blue: 0),
                                             "green": .init(red: 0, green: 1, blue: 0),
                                             "blue": .init(red: 0.2, green: 0.5, blue: 1)]
            let paint = CIImage(color: colors[t.peakingColor] ?? .red).cropped(to: img.extent)
            img = paint.applyingFilter("CIBlendWithMask",
                                       parameters: [kCIInputBackgroundImageKey: img,
                                                    kCIInputMaskImageKey: edges])
        }

        if t.flickerMap {
            if let grid = frozenFlickerGrid {
                // Frozen result of the last 3-second Sample & Analyze.
                let sx = img.extent.width / CGFloat(sgw)
                let sy = img.extent.height / CGFloat(sgh)
                let ov = grid.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    .transformed(by: CGAffineTransform(translationX: img.extent.origin.x, y: img.extent.origin.y))
                img = ov.composited(over: img)
            } else if let band = buildBandOverlay(pixelBuffer, extent: img.extent) {
                // Live = the periodicity-gated band map only (regular LED bands).
                // Temporal pulsing/flashing is handled by Sample & Analyze, which
                // is held-still and far less fooled by panning / exposure change.
                img = band.composited(over: img)
            }
        }

        // Collect frames for a Sample & Analyze run (independent of the overlay).
        if sampleTarget > 0 {
            sampleBuf.append(Self.tileLuma(pixelBuffer, gw: sgw, gh: sgh))
            onFlickerSampleProgress?(Double(sampleBuf.count) / Double(sampleTarget))
            if sampleBuf.count >= sampleTarget {
                sampleTarget = 0
                let summary = analyzeFlickerSample()
                onFlickerSampleDone?(summary)
            }
        }

        guard let cg = ciContext.createCGImage(img, from: img.extent) else { return }
        DispatchQueue.main.async { self.processedImage = cg }

        // Scopes every 6th frame, from a downsample.
        frameCount += 1
        if frameCount % 6 == 0 {
            if showHistogram { computeHistogram(pixelBuffer) }
            if showWaveform { computeWaveform(pixelBuffer) }
            if showVectorscope { computeVectorscope(pixelBuffer) }
        }
        // Flicker needs every frame's brightness — sample the raw buffer cheaply.
        // The per-row profile gives us BOTH the whole-frame mean (temporal
        // flicker) and the row pattern (rolling banding) in one pass.
        if sampleFlicker, let prof = Self.rowProfile(of: pixelBuffer) {
            let mean = prof.reduce(0, +) / Double(prof.count)
            onFlickerSample?(mean)
            onBandingSample?(prof)
        }
    }

    /// When true, publish each frame's mean luma + row profile.
    var sampleFlicker = false
    var onFlickerSample: ((Double) -> Void)?
    var onBandingSample: (([Double]) -> Void)?
    /// Every raw capture frame, for the H.264 LAN feed (model gates on clients).
    var onStreamFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Per-row mean-luma profile (coarse) straight from the capture buffer, for
    /// rolling-band detection. `buckets` horizontal strips, columns subsampled.
    static func rowProfile(of pb: CVPixelBuffer, buckets: Int = 96) -> [Double]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard h >= buckets, w > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var prof = [Double](repeating: 0, count: buckets)
        var cnt = [Int](repeating: 0, count: buckets)
        var y = 0
        while y < h {
            let b = min(y * buckets / h, buckets - 1)
            let row = p + y * stride
            var x = 0
            while x < w {
                let o = x * 4
                prof[b] += 0.2126 * Double(row[o + 2]) + 0.7152 * Double(row[o + 1]) + 0.0722 * Double(row[o])
                cnt[b] += 1
                x += 24
            }
            y += 2
        }
        for i in 0..<buckets where cnt[i] > 0 { prof[i] /= Double(cnt[i]) }
        return prof
    }

    /// Coarse mean luma straight from the capture buffer (BGRA8).
    static func meanLuma(of pb: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, count = 0
        var y = 0
        while y < h {
            var x = 0
            let row = p + y * stride
            while x < w {
                let o = x * 4
                sum += 0.2126 * Double(row[o + 2]) + 0.7152 * Double(row[o + 1]) + 0.0722 * Double(row[o])
                count += 1
                x += 16
            }
            y += 8
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private func computeHistogram(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var bins = [Float](repeating: 0, count: 64)
        let p = base.assumingMemoryBound(to: UInt8.self)
        // Fixed sample budget (see waveform): identical to x+=8 / y+=8 at ≤1080p,
        // constant cost at 4K.
        let sx = max(8, w / 240)
        let sy = max(8, h / 135)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * stride + x * 4
                let luma = (Int(p[o]) * 25 + Int(p[o + 1]) * 183 + Int(p[o + 2]) * 54) >> 8
                bins[min(luma >> 2, 63)] += 1
                x += sx
            }
            y += sy
        }
        let maxV = max(bins.max() ?? 1, 1)
        let norm = bins.map { $0 / maxV }
        DispatchQueue.main.async { self.histogram = norm }
    }

    // MARK: Scopes (waveform + vectorscope)

    /// Luma waveform: x = horizontal position across the frame, y = luma (bright
    /// at top), brightness = how many pixels in that column hit that level.
    private func computeWaveform(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let cols = 256, levels = 256
        // Sample a fixed budget rather than a hardcoded stride: at ≤1080p this is
        // exactly the old x+=2 / y+=2 density; at 4K the stride widens so the
        // sample count (and cost) stays flat instead of quadrupling.
        let sx = max(2, w / 960)
        let sy = max(2, h / 540)
        var counts = [UInt32](repeating: 0, count: cols * levels)
        var y = 0
        while y < h {
            let row = p + y * stride
            var x = 0
            while x < w {
                let o = x * 4   // BGRA
                let luma = (Int(row[o + 2]) * 54 + Int(row[o + 1]) * 183 + Int(row[o]) * 19) >> 8
                let col = min(x * cols / w, cols - 1)
                counts[col * levels + min(luma, levels - 1)] += 1
                x += sx
            }
            y += sy
        }
        var px = [UInt8](repeating: 0, count: cols * levels * 4)
        for col in 0..<cols {
            for lvl in 0..<levels where counts[col * levels + lvl] > 0 {
                let c = Double(counts[col * levels + lvl])
                let inten = UInt8(min(255.0, 35.0 + 55.0 * log2(c + 1)))
                let yPix = levels - 1 - lvl                 // bright luma at top
                let i = (yPix * cols + col) * 4
                px[i] = inten / 4; px[i + 1] = inten; px[i + 2] = inten / 4; px[i + 3] = 255
            }
        }
        let cg = Self.scopeImage(px, cols, levels)
        DispatchQueue.main.async { self.waveformImage = cg }
    }

    /// Vectorscope: each pixel plotted by its chroma (Cb/Cr) — hue = angle,
    /// saturation = distance from center.
    private func computeVectorscope(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let size = 256, half = Double(size) / 2.0
        // Fixed sample budget (see waveform): identical to x+=3 / y+=3 at ≤1080p,
        // constant cost at 4K.
        let sx = max(3, w / 640)
        let sy = max(3, h / 360)
        var counts = [UInt32](repeating: 0, count: size * size)
        var y = 0
        while y < h {
            let row = p + y * stride
            var x = 0
            while x < w {
                let o = x * 4
                let b = Double(row[o]), g = Double(row[o + 1]), r = Double(row[o + 2])
                let cb = -0.169 * r - 0.331 * g + 0.5 * b      // U
                let cr = 0.5 * r - 0.419 * g - 0.081 * b       // V
                let px = Int(half + cb * half / 128.0)
                let py = Int(half - cr * half / 128.0)         // flip y
                if px >= 0, px < size, py >= 0, py < size { counts[py * size + px] += 1 }
                x += sx
            }
            y += sy
        }
        var pix = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<size * size where counts[i] > 0 {
            let c = Double(counts[i])
            let inten = UInt8(min(255.0, 45.0 + 50.0 * log2(c + 1)))
            pix[i * 4] = inten / 3; pix[i * 4 + 1] = inten; pix[i * 4 + 2] = inten / 3; pix[i * 4 + 3] = 255
        }
        let cg = Self.scopeImage(pix, size, size)
        DispatchQueue.main.async { self.vectorscopeImage = cg }
    }

    /// Builds a CGImage from premultiplied RGBA bytes.
    private static func scopeImage(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Spatial flicker

    /// One pass over the frame, accumulating mean brightness per grid tile into
    /// the ring buffer.
    private func updateFlickerGrid(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let cells = fgw * fgh
        if ftile.count != cells * fhist { ftile = [Float](repeating: 0, count: cells * fhist); ftileCol = 0; ftileCount = 0 }
        var sum = [Float](repeating: 0, count: cells)
        var cnt = [Int](repeating: 0, count: cells)
        var y = 0
        while y < h {
            let ty = min(y * fgh / h, fgh - 1)
            let row = p + y * stride
            var x = 0
            while x < w {
                let tx = min(x * fgw / w, fgw - 1)
                let o = x * 4
                let luma = 0.2126 * Float(row[o + 2]) + 0.7152 * Float(row[o + 1]) + 0.0722 * Float(row[o])
                let idx = ty * fgw + tx
                sum[idx] += luma; cnt[idx] += 1
                x += 8
            }
            y += 6
        }
        let col = ftileCol
        for i in 0..<cells { ftile[i * fhist + col] = cnt[i] > 0 ? sum[i] / Float(cnt[i]) : 0 }
        ftileCol = (ftileCol + 1) % fhist
        ftileCount = min(ftileCount + 1, fhist)
    }

    /// Builds a small RGBA overlay: red where a tile's brightness oscillates
    /// (high peak-to-peak AND several direction reversals — that rejects a plain
    /// brightness ramp from motion/exposure). Scaled up over the picture.
    private func buildFlickerOverlay(extent: CGRect) -> CIImage? {
        let cells = fgw * fgh
        guard ftileCount >= 14, ftile.count == cells * fhist else { return nil }
        let n = ftileCount
        let thr = flickerSensitivity
        var px = [UInt8](repeating: 0, count: cells * 4)   // premultiplied RGBA, top-down
        for i in 0..<cells {
            let baseI = i * fhist
            var mn: Float = .greatestFiniteMagnitude, mx: Float = 0, s: Float = 0
            var reversals = 0, lastDir: Float = 0, prev: Float = 0
            for k in 0..<n {
                let col = (ftileCol - n + k + fhist) % fhist     // oldest → newest
                let v = ftile[baseI + col]
                mn = min(mn, v); mx = max(mx, v); s += v
                if k > 0 {
                    let d = v - prev
                    if d != 0 {
                        if d * lastDir < 0 { reversals += 1 }
                        lastDir = d
                    }
                }
                prev = v
            }
            let mean = s / Float(n)
            guard mean > 5 else { continue }                     // skip near-black (noisy)
            let amp = (mx - mn) / mean
            // Require the brightness to OSCILLATE several times over the window —
            // a flickering light/screen pulses repeatedly, whereas motion ramps a
            // tile once or twice. That's what separates flicker from movement.
            if amp > thr && reversals >= 6 {
                let sev = min((amp - thr) / 0.22, 1.0)
                let a = UInt8(45 + sev * 120)                    // alpha 45…165 (see-through)
                px[i * 4] = a; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = a   // premultiplied red
            }
        }
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: fgw, height: fgh, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: fgw * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // Grid is top-down; CIImage(cgImage:) yields a bottom-left-origin image,
        // so flip vertically, then scale to the picture and align to its origin.
        let sx = extent.width / CGFloat(fgw)
        let sy = extent.height / CGFloat(fgh)
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }

    /// High-passes a 1-D profile (removes vignette/gradient) and reports how
    /// PERIODIC it is via the normalized autocorrelation peak. A regular repeating
    /// pattern (LED banding) scores high; a lone edge, a text line, or a smooth
    /// ramp scores low. Returns (amplitude rms/mean, periodicity 0…1, period, hp[]).
    static func periodicity(_ profile: [Float], minMean: Float = 6)
        -> (amp: Float, score: Float, period: Int, hp: [Float], mean: Float) {
        let n = profile.count
        let empty = [Float](repeating: 0, count: n)
        guard n >= 12 else { return (0, 0, 0, empty, 0) }
        let mean = profile.reduce(0, +) / Float(n)
        guard mean > minMean else { return (0, 0, 0, empty, mean) }
        let win = max(3, n / 6)
        var hp = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0, c = 0
            var k = max(0, i - win); let ke = min(n - 1, i + win)
            while k <= ke { s += profile[k]; c += 1; k += 1 }
            hp[i] = profile[i] - s / Float(c)
        }
        let energy = hp.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return (0, 0, 0, hp, mean) }
        var bestLag = 0; var bestCorr: Float = 0
        let minLag = 2, maxLag = n / 3
        if maxLag > minLag {
            for lag in minLag...maxLag {
                var cc: Float = 0
                for i in 0..<(n - lag) { cc += hp[i] * hp[i + lag] }
                if cc > bestCorr { bestCorr = cc; bestLag = lag }
            }
        }
        let rms = (energy / Float(n)).squareRoot()
        return (rms / mean, bestCorr / energy, bestLag, hp, mean)
    }

    /// Single-frame horizontal-band detector — now PERIODICITY-GATED. For each
    /// column it checks whether the vertical luma profile is a *regular repeating*
    /// pattern (real LED banding) rather than a one-off transition; only then are
    /// the stripes painted red. This rejects the vignette ring, the OSD burn-in
    /// text, object edges, and the frame border that the old contrast-only version
    /// lit up. The outer margin is ignored entirely (letterbox / lens falloff).
    private func buildBandOverlay(_ pb: CVPixelBuffer, extent: CGRect) -> CIImage? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let BW = 16, BH = 220
        guard h >= BH, w > 0 else { return nil }
        let tile = Self.tileLuma(pb, gw: BW, gh: BH)
        let thr = flickerSensitivity
        let marginY = BH / 18                                // skip outer ~5.5%
        var px = [UInt8](repeating: 0, count: BW * BH * 4)   // premultiplied RGBA
        for x in 0..<BW {
            var col = [Float](repeating: 0, count: BH)
            for y in 0..<BH { col[y] = tile[y * BW + x] }
            let r = Self.periodicity(col)
            guard r.score > 0.35, r.amp > thr, r.mean > 6 else { continue }   // regular bands only
            for y in marginY..<(BH - marginY) {
                let strength = abs(r.hp[y]) / r.mean
                if strength > thr * 0.55 {
                    let sev = min((strength - thr * 0.55) / 0.08, 1.0)
                    let a = UInt8(60 + sev * 150)
                    let i = (y * BW + x) * 4
                    px[i] = a; px[i + 3] = a
                }
            }
        }
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: BW, height: BH, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: BW * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let sx = extent.width / CGFloat(BW)
        let sy = extent.height / CGFloat(BH)
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }

    /// Mean luma per tile of a `gw × gh` grid, one cheap pass. For sampling.
    static func tileLuma(_ pb: CVPixelBuffer, gw: Int, gh: Int) -> [Float] {
        let cells = gw * gh
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [Float](repeating: 0, count: cells) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = [Float](repeating: 0, count: cells)
        var cnt = [Int](repeating: 0, count: cells)
        var y = 0
        while y < h {
            let ty = min(y * gh / h, gh - 1)
            let row = p + y * stride
            var x = 0
            while x < w {
                let tx = min(x * gw / w, gw - 1)
                let o = x * 4
                sum[ty * gw + tx] += 0.2126 * Float(row[o + 2]) + 0.7152 * Float(row[o + 1]) + 0.0722 * Float(row[o])
                cnt[ty * gw + tx] += 1
                x += 12
            }
            y += 2
        }
        var out = [Float](repeating: 0, count: cells)
        for i in 0..<cells where cnt[i] > 0 { out[i] = sum[i] / Float(cnt[i]) }
        return out
    }

    /// Analyzes the captured sample: per tile, flag PULSING (peak-to-peak over the
    /// window with several reversals — rejects a one-way motion ramp) and/or
    /// stationary BANDING (the time-average differs from its vertical neighbours).
    /// Builds the frozen red grid and returns a plain-English summary.
    private func analyzeFlickerSample() -> String {
        let gw = sgw, gh = sgh, cells = gw * gh, n = sampleBuf.count
        guard n >= 8 else { frozenFlickerGrid = nil; return "Sample too short — try again." }
        let thr = flickerSensitivity

        var avg = [Float](repeating: 0, count: cells)
        for f in sampleBuf { for i in 0..<cells { avg[i] += f[i] } }
        for i in 0..<cells { avg[i] /= Float(n) }

        var px = [UInt8](repeating: 0, count: cells * 4)   // premultiplied RGBA
        var flashCells = 0, bandCells = 0, litCells = 0
        var maxAmp: Float = 0
        let marginX = max(1, gw / 16), marginY = max(2, gh / 16)   // skip border/letterbox

        // TEMPORAL: a tile pulses over the 3 s in a REGULAR way (periodicity gate
        // rejects a one-way pan / exposure ramp, which isn't periodic).
        for x in marginX..<(gw - marginX) {
            for y in marginY..<(gh - marginY) {
                let i = y * gw + x
                guard avg[i] > 8 else { continue }
                litCells += 1
                var series = [Float](repeating: 0, count: n)
                for k in 0..<n { series[k] = sampleBuf[k][i] }
                let r = Self.periodicity(series, minMean: 8)
                if r.score > 0.30 && r.amp > thr {
                    flashCells += 1
                    maxAmp = max(maxAmp, r.amp)
                    let sev = min((r.amp - thr) / 0.25, 1.0)
                    let a = UInt8(70 + sev * 150)
                    px[i * 4] = a; px[i * 4 + 3] = a
                }
            }
        }

        // SPATIAL banding: a column of the time-average is a REGULAR repeating
        // stripe pattern (periodicity gate rejects edges / text / vignette).
        for x in marginX..<(gw - marginX) {
            var col = [Float](repeating: 0, count: gh)
            for y in 0..<gh { col[y] = avg[y * gw + x] }
            let r = Self.periodicity(col, minMean: 8)
            guard r.score > 0.35, r.amp > thr else { continue }
            for y in marginY..<(gh - marginY) {
                let strength = abs(r.hp[y]) / r.mean
                if strength > thr * 0.55 {
                    bandCells += 1
                    let i = y * gw + x
                    let sev = min((strength - thr * 0.55) / 0.08, 1.0)
                    let a = UInt8(70 + sev * 150)
                    px[i * 4] = max(px[i * 4], a); px[i * 4 + 3] = max(px[i * 4 + 3], a)
                }
            }
        }

        let data = Data(px)
        if let provider = CGDataProvider(data: data as CFData),
           let cg = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: gw * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            frozenFlickerGrid = CIImage(cgImage: cg)
        } else {
            frozenFlickerGrid = nil
        }

        let lit = max(litCells, 1)
        if flashCells == 0 && bandCells == 0 {
            return "No flicker or banding found in this 3-second sample."
        }
        var parts: [String] = []
        if flashCells > 0 {
            parts.append(String(format: "pulsing/flashing in %.0f%% of the lit area (±%.0f%%)",
                                Double(flashCells) / Double(lit) * 100, Double(maxAmp) * 100))
        }
        if bandCells > 0 {
            parts.append(String(format: "banding in %.0f%% of the lit area",
                                Double(bandCells) / Double(lit) * 100))
        }
        return "Detected " + parts.joined(separator: " + ")
             + ". Red marks the affected areas. For an exact Hz, record a clip and tap Scan Flicker (reads at the record rate)."
    }
}

extension SDIProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Always process (passthrough when no tools active) so the viewer has
        // ONE continuous video path — swapping views caused flicker/black-outs.
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Proof of life for the capture manager — cheap integer reads, no
        // allocation. This is the ONLY thing that distinguishes a working feed
        // from a session that opened and delivers nothing.
        onFrameArrived?(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                        CVPixelBufferGetPixelFormatType(pb))
        // Raw pixel buffer → low-latency H.264 LAN feed (gated on clients by the model).
        onStreamFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        process(pb)
    }
}
