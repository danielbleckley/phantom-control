import Foundation
import CoreGraphics

/// Full-resolution CPU debayer for 16-bit cine frames (GBRG, CFA=3).
/// Bilinear demosaic, then black/white-level normalization, white balance
/// and gamma applied through per-channel LUTs. Rows are processed in
/// parallel bands — fast enough for 24fps playback of 2.5K frames and for
/// transcode, where the video encoder dominates anyway.
///
/// Two output flavors:
///   - BGRA8 for on-screen display (CGImage) and H.264 encoding
///   - 64ARGB (16-bit big-endian) for ProRes, keeping grading latitude
public enum Debayer16 {

    public struct RenderSettings: Sendable {
        public var wbRed: Float
        public var wbGreen: Float
        public var wbBlue: Float
        public var gain: Float
        public var gamma: Float          // display gamma, e.g. 2.2
        public var blackLevel16: Int     // left-justified to 16-bit scale
        public var whiteLevel16: Int
        /// Highlight-rolloff knee (0…1). 1.0 = hard clip (legacy). Below 1.0,
        /// values above the knee are smoothly compressed toward white instead
        /// of clipping — recovers blown highlights (a filmic "shoulder").
        public var highlightKnee: Float

        public init(wbRed: Float = 1.0, wbGreen: Float = 1.0, wbBlue: Float = 1.0,
                    gain: Float = 1.0, gamma: Float = 2.2,
                    blackLevel16: Int = 64 << 4, whiteLevel16: Int = 4064 << 4,
                    highlightKnee: Float = 1.0) {
            self.wbRed = wbRed; self.wbGreen = wbGreen; self.wbBlue = wbBlue
            self.gain = gain; self.gamma = gamma
            self.blackLevel16 = blackLevel16; self.whiteLevel16 = whiteLevel16
            self.highlightKnee = highlightKnee
        }

        /// A neutral, gradeable Rec.709 delivery look — matches how DaVinci
        /// decodes a Phantom cine (deeper blacks via a slightly darker film
        /// gamma, a highlight shoulder instead of a hard clip, a touch under
        /// exposure), rather than the punchy hard-clipped baked develop. Used
        /// for .mov exports so downloaded clips edit/grade like PCC/Resolve.
        public static func neutralRec709(info: CineFileInfo) -> RenderSettings {
            var s = RenderSettings(info: info)
            s.gamma = 1.85             // lower gamma = darker, contrastier (Resolve-like)
            s.gain = 0.80
            s.highlightKnee = 0.80     // roll off the top 20% instead of clipping
            // Deepen the black point so shadows land clean instead of milky.
            s.blackLevel16 += Int(0.008 * Double(max(s.whiteLevel16 - s.blackLevel16, 1)))
            // Less warm/greener than the baked daylight nudge — Resolve's tint.
            s.wbRed = min(s.wbRed, 1.24)
            s.wbBlue = min(s.wbBlue, 1.30)
            return s
        }

        /// Settings seeded from a cine file's setup block. Files written by
        /// our own CineWriter store WB gains of 1.0 (raw); a plain 1.0/1.0
        /// looks green on a color sensor, so nudge toward daylight then.
        public init(info: CineFileInfo) {
            let fileIsNeutral = abs(info.wbGainRed - 1) < 0.001 && abs(info.wbGainBlue - 1) < 0.001
            self.init(
                wbRed: (fileIsNeutral && info.isColor) ? 1.6 : info.wbGainRed,
                wbGreen: 1.0,
                wbBlue: (fileIsNeutral && info.isColor) ? 1.45 : info.wbGainBlue,
                blackLevel16: info.blackLevel16,
                whiteLevel16: info.whiteLevel16)
        }
    }

    // MARK: demosaic (linear, raw 16-bit scale)

    /// Bilinear GBRG demosaic to interleaved RGB, 3×UInt16 per pixel, top-down,
    /// still on the raw left-justified 16-bit scale (no WB/gamma yet).
    /// For mono frames (cfa 0) the gray value is replicated into R=G=B.
    public static func demosaicRGB48(frame: CineFrame16, cfa: Int) -> [UInt16] {
        let w = frame.width, h = frame.height
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        guard w >= 2, h >= 2 else { return rgb }

        if cfa == 0 {
            frame.pixels.withUnsafeBufferPointer { src in
                rgb.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<(w * h) {
                        let v = src[i]
                        dst[i*3] = v; dst[i*3+1] = v; dst[i*3+2] = v
                    }
                }
            }
            return rgb
        }

        // GBRG: even rows G B G B…, odd rows R G R G…
        frame.pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            rgb.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 2))
                let rowsPerBand = (h + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let y0 = band * rowsPerBand
                    let y1 = min(y0 + rowsPerBand, h)
                    guard y0 < y1 else { return }
                    for y in y0..<y1 {
                        // Clamped neighbor rows (edge replication).
                        let up = src + max(y - 1, 0) * w
                        let row = src + y * w
                        let dn = src + min(y + 1, h - 1) * w
                        var o = y * w * 3
                        let oddRow = (y & 1) == 1
                        for x in 0..<w {
                            let xl = max(x - 1, 0), xr = min(x + 1, w - 1)
                            let r: Int, g: Int, b: Int
                            if !oddRow {
                                if (x & 1) == 0 {
                                    // G site, blue row: B horiz, R vert
                                    g = Int(row[x])
                                    b = (Int(row[xl]) + Int(row[xr])) >> 1
                                    r = (Int(up[x]) + Int(dn[x])) >> 1
                                } else {
                                    // B site: G plus, R diagonals
                                    b = Int(row[x])
                                    g = (Int(row[xl]) + Int(row[xr]) + Int(up[x]) + Int(dn[x])) >> 2
                                    r = (Int(up[xl]) + Int(up[xr]) + Int(dn[xl]) + Int(dn[xr])) >> 2
                                }
                            } else {
                                if (x & 1) == 0 {
                                    // R site: G plus, B diagonals
                                    r = Int(row[x])
                                    g = (Int(row[xl]) + Int(row[xr]) + Int(up[x]) + Int(dn[x])) >> 2
                                    b = (Int(up[xl]) + Int(up[xr]) + Int(dn[xl]) + Int(dn[xr])) >> 2
                                } else {
                                    // G site, red row: R horiz, B vert
                                    g = Int(row[x])
                                    r = (Int(row[xl]) + Int(row[xr])) >> 1
                                    b = (Int(up[x]) + Int(dn[x])) >> 1
                                }
                            }
                            dst[o] = UInt16(r); dst[o+1] = UInt16(g); dst[o+2] = UInt16(b)
                            o += 3
                        }
                    }
                }
            }
        }
        return rgb
    }

    // MARK: tone LUTs

    /// Normalized tone curve: raw16 → 0…1 after black/white levels, channel
    /// gain and display gamma.
    private static func toneValue(_ raw: Int, black: Float, scale: Float,
                                  gain: Float, invGamma: Float, knee: Float) -> Float {
        var v = (Float(raw) - black) * scale * gain
        v = max(v, 0)
        v = powf(v, invGamma)
        // Highlight shoulder: smoothly roll everything above the knee toward 1
        // (asymptotic), so over-white detail compresses instead of clipping.
        if knee < 1, v > knee {
            let s = 1 - knee
            v = knee + s * (1 - expf(-(v - knee) / s))
        }
        return min(v, 1)
    }

    private static func makeLUTs<T>(settings: RenderSettings, map: (Float) -> T) -> (r: [T], g: [T], b: [T]) {
        let black = Float(settings.blackLevel16)
        let white = Float(max(settings.whiteLevel16, settings.blackLevel16 + 1))
        let scale = 1.0 / (white - black)
        let invGamma = 1.0 / max(settings.gamma, 0.1)
        let knee = settings.highlightKnee
        func lut(_ chanGain: Float) -> [T] {
            let gain = chanGain * settings.gain
            var t = [T](repeating: map(0), count: 65536)
            for i in 0..<65536 {
                t[i] = map(toneValue(i, black: black, scale: scale, gain: gain, invGamma: invGamma, knee: knee))
            }
            return t
        }
        return (lut(settings.wbRed), lut(settings.wbGreen), lut(settings.wbBlue))
    }

    // MARK: emitters

    /// Interleaved RGB48 → BGRA8 bytes (premultiplied-none, alpha 255).
    public static func bgra8(rgb48: [UInt16], width w: Int, height h: Int,
                             settings: RenderSettings) -> [UInt8] {
        let (lr, lg, lb) = makeLUTs(settings: settings) { UInt8(min(255, Int($0 * 255 + 0.5))) }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        rgb48.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            out.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                lr.withUnsafeBufferPointer { lr in lg.withUnsafeBufferPointer { lg in lb.withUnsafeBufferPointer { lb in
                    DispatchQueue.concurrentPerform(iterations: 8) { band in
                        let n = w * h
                        let i0 = n * band / 8, i1 = n * (band + 1) / 8
                        for i in i0..<i1 {
                            dst[i*4]     = lb[Int(src[i*3+2])]
                            dst[i*4 + 1] = lg[Int(src[i*3+1])]
                            dst[i*4 + 2] = lr[Int(src[i*3])]
                            dst[i*4 + 3] = 255
                        }
                    }
                }}}
            }
        }
        return out
    }

    /// Interleaved RGB48 → 64-bit ARGB, 16 bits per component, big endian
    /// (kCVPixelFormatType_64ARGB), written straight into a pixel buffer plane.
    public static func writeARGB16BE(rgb48: [UInt16], width w: Int, height h: Int,
                                     settings: RenderSettings,
                                     to base: UnsafeMutableRawPointer, bytesPerRow: Int) {
        let (lr, lg, lb) = makeLUTs(settings: settings) { v -> UInt16 in
            UInt16(min(65535, Int(v * 65535 + 0.5))).bigEndian
        }
        rgb48.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            lr.withUnsafeBufferPointer { lr in lg.withUnsafeBufferPointer { lg in lb.withUnsafeBufferPointer { lb in
                DispatchQueue.concurrentPerform(iterations: 8) { band in
                    let y0 = h * band / 8, y1 = h * (band + 1) / 8
                    for y in y0..<y1 {
                        let row = (base + y * bytesPerRow).bindMemory(to: UInt16.self, capacity: w * 4)
                        var s = y * w * 3
                        var d = 0
                        for _ in 0..<w {
                            row[d] = UInt16(0xFFFF).bigEndian
                            row[d+1] = lr[Int(src[s])]
                            row[d+2] = lg[Int(src[s+1])]
                            row[d+3] = lb[Int(src[s+2])]
                            s += 3; d += 4
                        }
                    }
                }
            }}}
        }
    }

    /// Writes BGRA8 straight into a pixel buffer plane (for H.264 transcode).
    public static func writeBGRA8(rgb48: [UInt16], width w: Int, height h: Int,
                                  settings: RenderSettings,
                                  to base: UnsafeMutableRawPointer, bytesPerRow: Int) {
        let bytes = bgra8(rgb48: rgb48, width: w, height: h, settings: settings)
        bytes.withUnsafeBufferPointer { src in
            for y in 0..<h {
                memcpy(base + y * bytesPerRow, src.baseAddress! + y * w * 4, w * 4)
            }
        }
    }

    // MARK: display

    /// Full pipeline for on-screen display: demosaic + tone → CGImage.
    public static func render(frame: CineFrame16, cfa: Int, settings: RenderSettings) -> CGImage? {
        let rgb = demosaicRGB48(frame: frame, cfa: cfa)
        let bgra = bgra8(rgb48: rgb, width: frame.width, height: frame.height, settings: settings)
        return cgImage(bgra8: bgra, width: frame.width, height: frame.height)
    }

    public static func cgImage(bgra8 bytes: [UInt8], width w: Int, height h: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Gray-world auto white balance: returns (red, blue) gains that bring the
    /// red and blue channel means to the green mean, computed on raw values.
    public static func autoWhiteBalance(frame: CineFrame16, cfa: Int, blackLevel16: Int) -> (red: Float, blue: Float)? {
        guard cfa != 0 else { return nil }
        let w = frame.width, h = frame.height
        guard w >= 2, h >= 2 else { return nil }
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        frame.pixels.withUnsafeBufferPointer { src in
            // Sample 2x2 GBRG cells on a sparse grid over the center half.
            var y = h / 4
            while y < h * 3 / 4 {
                let row0 = (y & ~1) * w
                var x = w / 4
                while x < w * 3 / 4 {
                    let cx = x & ~1
                    let g1 = Int(src[row0 + cx])
                    let b = Int(src[row0 + cx + 1])
                    let r = Int(src[row0 + w + cx])
                    let g2 = Int(src[row0 + w + cx + 1])
                    sumG += Double((g1 + g2) >> 1)
                    sumB += Double(b)
                    sumR += Double(r)
                    count += 1
                    x += 8
                }
                y += 8
            }
        }
        guard count > 0 else { return nil }
        let black = Double(blackLevel16)
        let mr = sumR / Double(count) - black
        let mg = sumG / Double(count) - black
        let mb = sumB / Double(count) - black
        guard mr > 1, mg > 1, mb > 1 else { return nil }
        let red = min(max(Float(mg / mr), 0.3), 8)
        let blue = min(max(Float(mg / mb), 0.3), 8)
        return (red, blue)
    }
}
