import Foundation
import CoreGraphics

/// CPU debayer for Phantom 8-bit sensor data.
/// Flex sensors report CFA_BAYER (3) = GBRG layout:
///   row 0: G B G B ...
///   row 1: R G R G ...
/// Half-resolution reconstruction: each 2x2 cell becomes one RGB pixel.
/// Fast enough for preview; a Metal path can replace this later.
public enum Debayer {

    public struct WhiteBalance {
        public var red: Float
        public var green: Float
        public var blue: Float
        public init(red: Float = 1.0, green: Float = 1.0, blue: Float = 1.0) {
            self.red = red; self.green = green; self.blue = blue
        }
        public static let daylightish = WhiteBalance(red: 1.6, green: 1.0, blue: 1.45)
    }

    /// Returns a BGRA8 image at half the sensor resolution.
    /// `peaking` paints high-contrast edges red (focus assist).
    public static func halfResBGRA(frame: PhantomFrame, wb: WhiteBalance = .init(),
                                   gain: Float = 1.0, peaking: Bool = false,
                                   blackLevel: Float = 0.045, whiteLevel: Float = 1.0,
                                   contrast: Float = 1.25,
                                   saturation: Float = 1.28,
                                   gamma: Float = 0) -> CGImage? {
        let w = frame.width, h = frame.height
        guard w >= 2, h >= 2, frame.pixels.count >= w * h else { return nil }
        let outW = w / 2, outH = h / 2

        // Tone: with `gamma > 0` (Match-SDI mode) apply the CAMERA's display
        // gamma (out = in^(1/gamma)) over the levels range — the same curve the
        // camera uses for its SDI output, so the two feeds match. Otherwise use
        // the auto-levels stretch + contrast S-curve that lifts the flat raw.
        let black = Float(blackLevel)                 // input level → 0
        let white = max(black + 0.02, Float(whiteLevel)) // input level → 1
        let inv = 1.0 / (white - black)
        let invGamma = gamma > 0 ? 1.0 / gamma : 0
        func toneSCurve(_ x0: Float) -> Float {
            let x = min(1, max(0, (x0 - black) * inv)) // levels stretch
            let c = Float(contrast)
            return x < 0.5 ? 0.5 * powf(2 * x, c) : 1 - 0.5 * powf(2 * (1 - x), c)
        }
        var lutR = [UInt8](repeating: 0, count: 256)
        var lutG = [UInt8](repeating: 0, count: 256)
        var lutB = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let lin = Float(i) / 255.0
            if invGamma > 0 {
                // Camera-accurate develop (Match SDI): normalize, then WB in
                // LINEAR, THEN the camera's gamma. WB must precede gamma — doing
                // it after pushes boosted channels past 1.0 and blows out (pink).
                let x = min(1, max(0, (lin - black) * inv))
                lutR[i] = UInt8(min(255, max(0, Int(powf(min(1, x * wb.red),   invGamma) * gain * 255))))
                lutG[i] = UInt8(min(255, max(0, Int(powf(min(1, x * wb.green), invGamma) * gain * 255))))
                lutB[i] = UInt8(min(255, max(0, Int(powf(min(1, x * wb.blue),  invGamma) * gain * 255))))
            } else {
                let t = toneSCurve(lin) * gain
                lutR[i] = UInt8(min(255, max(0, Int(t * wb.red   * 255))))
                lutG[i] = UInt8(min(255, max(0, Int(t * wb.green * 255))))
                lutB[i] = UInt8(min(255, max(0, Int(t * wb.blue  * 255))))
            }
        }
        let sat = Float(saturation)

        var out = [UInt8](repeating: 255, count: outW * outH * 4)
        frame.pixels.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let src = rawPtr.bindMemory(to: UInt8.self).baseAddress!
            out.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                // Demosaic + tone across parallel horizontal bands — one core per
                // band instead of one core for the whole frame. Rows are fully
                // independent, so the output is bit-identical to the old serial
                // loop; it just finishes N× faster on multi-core (helps most on
                // the slower/Intel Macs where this loop caps live fps).
                lutR.withUnsafeBufferPointer { lutR in
                lutG.withUnsafeBufferPointer { lutG in
                lutB.withUnsafeBufferPointer { lutB in
                    let bands = max(1, min(outH, ProcessInfo.processInfo.activeProcessorCount))
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let y0 = outH * band / bands
                        let y1 = outH * (band + 1) / bands
                        for y in y0..<y1 {
                            let r0 = src + (2 * y) * w       // G B
                            let r1 = src + (2 * y + 1) * w   // R G
                            var o = y * outW * 4
                            for x in 0..<outW {
                                let g1 = Int(r0[2 * x])
                                let b  = Int(r0[2 * x + 1])
                                let r  = Int(r1[2 * x])
                                let g2 = Int(r1[2 * x + 1])
                                var rr = Float(lutR[r])
                                var gg = Float(lutG[(g1 + g2) >> 1])
                                var bb = Float(lutB[b])
                                if sat != 1.0 {
                                    // Rec.601 luma; push colour away from grey by `sat`.
                                    let l = 0.299 * rr + 0.587 * gg + 0.114 * bb
                                    rr = min(255, max(0, l + (rr - l) * sat))
                                    gg = min(255, max(0, l + (gg - l) * sat))
                                    bb = min(255, max(0, l + (bb - l) * sat))
                                }
                                dst[o]     = UInt8(bb)
                                dst[o + 1] = UInt8(gg)
                                dst[o + 2] = UInt8(rr)
                                dst[o + 3] = 255
                                o += 4
                            }
                        }
                    }
                }}}
            }
        }

        if peaking {
            // Mark strong luma edges in red, using the green channel as luma.
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<(outH - 1) {
                    let row = y * outW * 4
                    let next = (y + 1) * outW * 4
                    for x in 0..<(outW - 1) {
                        let g = Int(dst[row + x*4 + 1])
                        let gx = Int(dst[row + (x+1)*4 + 1])
                        let gy = Int(dst[next + x*4 + 1])
                        if abs(g - gx) + abs(g - gy) > 48 {
                            dst[row + x*4] = 0       // B
                            dst[row + x*4 + 1] = 0   // G
                            dst[row + x*4 + 2] = 255 // R
                        }
                    }
                }
            }
        }

        return makeCGImage(out, outW, outH)
    }

    /// 12-/16-bit (P16) debayer — the "quality" preview path. Same look pipeline
    /// as the 8-bit version, but the levels stretch + tone happen in the full
    /// bit depth (via a 4096-entry LUT) so gradients stay SMOOTH instead of
    /// banding when a narrow raw range is expanded. Slower over the wire (2×
    /// the bytes → ~half the fps) but visibly cleaner, PCC-style.
    /// `data` is width*height 16-bit little-endian samples, GBRG.
    public static func halfResBGRA16(data: Data, width w: Int, height h: Int,
                                     wb: WhiteBalance = .init(), gain: Float = 1.0,
                                     peaking: Bool = false,
                                     blackLevel: Float = 0.045, whiteLevel: Float = 1.0,
                                     contrast: Float = 1.25, saturation: Float = 1.28,
                                     gamma: Float = 0) -> CGImage? {
        guard w >= 2, h >= 2, data.count >= w * h * 2 else { return nil }
        let outW = w / 2, outH = h / 2
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CGImage? in
            let src = raw.bindMemory(to: UInt16.self).baseAddress!
            // Detect justification: 12-bit right-justified (max ≤4095) vs
            // 16-bit left-justified. Scale so the 4096-entry LUT indexes cleanly.
            var maxV: UInt16 = 0
            var i = 0
            let n = w * h
            while i < n { if src[i] > maxV { maxV = src[i] }; i += 97 }  // coarse scan
            let shift = maxV > 4095 ? 4 : 0                              // →12-bit index

            let black = blackLevel, white = max(blackLevel + 0.02, whiteLevel)
            let inv = 1.0 / (white - black)
            let c = contrast
            let invGamma = gamma > 0 ? 1.0 / gamma : 0   // Match-SDI camera gamma
            // Per-channel LUTs already scaled to 0–255. In camera-accurate
            // (gamma) mode WB is applied in LINEAR *before* the gamma; otherwise
            // it's a tone-then-WB S-curve. This bakes WB into the LUT so the
            // pixel loop is a plain lookup. The LUTs are CACHED across frames
            // (keyed on the look params) — rebuilding 3×4096 powf entries every
            // frame was pure waste when levels/WB/gamma rarely change, and it's
            // exactly the work a slow machine can least afford in quality mode.
            let lutKey: [Float] = [black, white, c, gamma, gain, wb.red, wb.green, wb.blue]
            let (lutRc, lutGc, lutBc) = tone16LUTs(key: lutKey, black: black, inv: inv,
                                                   c: c, invGamma: invGamma, gain: gain, wb: wb)
            let sat = saturation
            var out = [UInt8](repeating: 255, count: outW * outH * 4)
            out.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                lutRc.withUnsafeBufferPointer { lutRc in
                lutGc.withUnsafeBufferPointer { lutGc in
                lutBc.withUnsafeBufferPointer { lutBc in
                    let bands = max(1, min(outH, ProcessInfo.processInfo.activeProcessorCount))
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let y0 = outH * band / bands
                        let y1 = outH * (band + 1) / bands
                        for y in y0..<y1 {
                            let r0 = src + (2 * y) * w       // G B
                            let r1 = src + (2 * y + 1) * w   // R G
                            var o = y * outW * 4
                            for x in 0..<outW {
                                let g1 = Int(r0[2 * x] >> shift)
                                let b  = Int(r0[2 * x + 1] >> shift)
                                let r  = Int(r1[2 * x] >> shift)
                                let g2 = Int(r1[2 * x + 1] >> shift)
                                var rr = lutRc[min(4095, r)]
                                var gg = lutGc[min(4095, (g1 + g2) >> 1)]
                                var bb = lutBc[min(4095, b)]
                                if sat != 1.0 {
                                    let l = 0.299 * rr + 0.587 * gg + 0.114 * bb
                                    rr = l + (rr - l) * sat
                                    gg = l + (gg - l) * sat
                                    bb = l + (bb - l) * sat
                                }
                                dst[o]     = UInt8(min(255, max(0, bb)))
                                dst[o + 1] = UInt8(min(255, max(0, gg)))
                                dst[o + 2] = UInt8(min(255, max(0, rr)))
                                dst[o + 3] = 255
                                o += 4
                            }
                        }
                    }
                }}}
            }
            return makeCGImage(out, outW, outH)
        }
    }

    // MARK: - Cached 16-bit tone LUTs

    // Guards the shared LUT cache below. `halfResBGRA16` can be called from more
    // than one queue (live preview + on-demand mag scrub), so the swap is locked.
    private static let tone16Lock = NSLock()
    nonisolated(unsafe) private static var tone16Key: [Float] = []
    nonisolated(unsafe) private static var tone16R: [Float] = []
    nonisolated(unsafe) private static var tone16G: [Float] = []
    nonisolated(unsafe) private static var tone16B: [Float] = []

    /// Returns the three 4096-entry tone LUTs for the given look. When `key`
    /// matches the last build, the SAME arrays are handed back (copy-on-write,
    /// so no bytes move) instead of recomputing ~12k powf calls. Any change to
    /// levels / contrast / gamma / gain / WB produces a new key and a rebuild,
    /// so the picture updates exactly as before.
    private static func tone16LUTs(key: [Float], black: Float, inv: Float, c: Float,
                                   invGamma: Float, gain: Float, wb: WhiteBalance)
        -> ([Float], [Float], [Float]) {
        tone16Lock.lock(); defer { tone16Lock.unlock() }
        if tone16Key == key, tone16R.count == 4096 {
            return (tone16R, tone16G, tone16B)
        }
        var lutRc = [Float](repeating: 0, count: 4096)
        var lutGc = [Float](repeating: 0, count: 4096)
        var lutBc = [Float](repeating: 0, count: 4096)
        for j in 0..<4096 {
            let x0 = Float(j) / 4095.0
            let x = min(1, max(0, (x0 - black) * inv))
            if invGamma > 0 {
                lutRc[j] = powf(min(1, x * wb.red),   invGamma) * gain * 255
                lutGc[j] = powf(min(1, x * wb.green), invGamma) * gain * 255
                lutBc[j] = powf(min(1, x * wb.blue),  invGamma) * gain * 255
            } else {
                let s = (x < 0.5 ? 0.5 * powf(2 * x, c) : 1 - 0.5 * powf(2 * (1 - x), c)) * gain
                lutRc[j] = s * wb.red   * 255
                lutGc[j] = s * wb.green * 255
                lutBc[j] = s * wb.blue  * 255
            }
        }
        tone16Key = key; tone16R = lutRc; tone16G = lutGc; tone16B = lutBc
        return (lutRc, lutGc, lutBc)
    }

    private static func makeCGImage(_ pixels: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
