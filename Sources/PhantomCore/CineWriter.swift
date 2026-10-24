import Foundation

/// Writes Vision Research .cine files (version 1, uncompressed 16-bit raw).
///
/// Layout per "Cine File Format.pdf" (SDK 3.12) and the packed SETUP struct
/// in Phint.h (10,688 bytes, #pragma pack(1) — offsets generated mechanically
/// from the header, do not hand-edit):
///   CINEFILEHEADER(44) | BITMAPINFOHEADER(40) | SETUP(10688) | offsets[n]·u64 | frames
/// Each frame: u32 annotationSize(=8) | u32 imageSize | pixels (16bpp LE, bottom-up)
public struct CineMetadata {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var exposureNs: Int
    public var serial: Int
    public var cfa: Int                 // 3 = GBRG bayer on Flex
    public var firstImageNo: Int        // trigger-relative number of first saved frame
    public var totalFrames: Int         // frcount of the source cine
    public var firstMovieImage: Int     // firstfr of the source cine
    public var triggerSecs: UInt32
    public var triggerFrac: UInt32
    public var postTrigger: Int
    public var cameraModel: String
    /// Numeric camera type — the camera's `info.hwver`, written to SETUP
    /// `CameraVersion`. **0 = unknown**, which leaves the field alone rather
    /// than asserting something false.
    ///
    /// Verified values (SDK datasheet + our own .cine files): Phantom Flex =
    /// **135**, v12 = 120, VEO 640S = 7011, VEO 1310L = 12002. No complete table
    /// exists in the SDK — read it per body with `get info.hwver`.
    ///
    /// This matters because metadata-honouring apps (PCC, Resolve, Seance,
    /// PhantomFuse) key camera-specific handling off it. Until now the template
    /// path wrote the VEO4K donor's value and the hand-built path hardcoded a
    /// literal `7` regardless of body, so Flex 4K downloads identified as a VEO.
    public var cameraVersion: Int = 0
    public var cineName: String
    // Develop metadata read from the CAMERA at download time, so the .cine carries the
    // clip's REAL look — not template placeholders. (Fixes the Seance/PhantomFuse
    // mismatch: our files used to stamp neutral WB, a leftover EI tone curve, and the
    // template donor camera's color matrix — apps honoring the metadata rendered them
    // washed out and off-colour.) Zero/empty = unknown → the template values stay.
    public var wbRed: Float = 0          // WBGain red (1.0 = neutral); 0 = unknown
    public var wbBlue: Float = 0
    public var toneString: String = ""   // camera video.adj.tone verbatim ("label x y …")
    public var toneKnown: Bool = false   // true = we read the camera; "" then means NEUTRAL (zero the template's curve)
    public var calMatrix: [Float] = []   // 9 floats: the camera's cmatrix (calibration → Rec709, WB folded)

    public init(width: Int, height: Int, frameRate: Int, exposureNs: Int, serial: Int,
                cfa: Int, firstImageNo: Int, totalFrames: Int, firstMovieImage: Int,
                triggerSecs: UInt32 = 0, triggerFrac: UInt32 = 0, postTrigger: Int = 0,
                cameraModel: String = "Phantom", cameraVersion: Int = 0,
                cineName: String = "cine",
                wbRed: Float = 0, wbBlue: Float = 0,
                toneString: String = "", toneKnown: Bool = false, calMatrix: [Float] = []) {
        self.width = width; self.height = height; self.frameRate = frameRate
        self.exposureNs = exposureNs; self.serial = serial; self.cfa = cfa
        self.firstImageNo = firstImageNo; self.totalFrames = totalFrames
        self.firstMovieImage = firstMovieImage
        self.triggerSecs = triggerSecs; self.triggerFrac = triggerFrac
        self.postTrigger = postTrigger
        self.cameraModel = cameraModel; self.cameraVersion = cameraVersion
        self.cineName = cineName
        self.wbRed = wbRed; self.wbBlue = wbBlue
        self.toneString = toneString; self.toneKnown = toneKnown; self.calMatrix = calMatrix
    }
}

public final class CineWriter {
    static let handBuiltSetupSize = 10688
    static let headerSize = 44
    static let bmiSize = 40

    /// On-disk pixel layout. `raw16` is the legacy uncompressed 16-bit path used
    /// by the TCP `img` download. `packed10` writes BI_PACKED (256) frames byte
    /// for byte — exactly what the ximg 10G stream delivers (RealBPP 10).
    public enum PixelLayout {
        case raw16
        case packed10

        /// Bytes per frame for a given resolution.
        func frameBytes(width: Int, height: Int) -> Int {
            switch self {
            case .raw16:    return width * height * 2
            case .packed10: return (width * height * 10 + 7) / 8
            }
        }
    }

    let meta: CineMetadata
    let frameCount: Int
    let layout: PixelLayout
    let handle: FileHandle
    let url: URL
    var framesWritten = 0
    let frameBytes: Int
    let dataStart: UInt64

    public init(url: URL, meta: CineMetadata, frameCount: Int,
                layout: PixelLayout = .raw16) throws {
        self.url = url
        self.meta = meta
        self.frameCount = frameCount
        self.layout = layout
        self.frameBytes = layout.frameBytes(width: meta.width, height: meta.height)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            throw PhantomError.socketError("cannot create \(url.path)")
        }
        self.handle = h
        // Build SETUP first; its size sets the image-data offset (the modern
        // VEO template is 18,052 bytes vs the 10,688 hand-built fallback).
        let setup = Self.setupBlock(meta: meta, layout: layout)
        let offImageOffsets = Self.headerSize + Self.bmiSize + setup.count
        self.dataStart = UInt64(offImageOffsets + frameCount * 8)

        var header = Data()
        header.append(Self.fileHeader(meta: meta, frameCount: frameCount, setupLen: setup.count))
        header.append(Self.bitmapHeader(meta: meta, layout: layout))
        header.append(setup)
        header.append(Self.offsetTable(frameCount: frameCount, dataStart: dataStart, frameBytes: frameBytes))
        h.write(header)
    }

    /// Appends one frame of 16-bit pixels (top-down sensor order, left-justified
    /// camera values). Converts to bottom-up, right-justified 12-bit as PCC does.
    public func appendFrame(_ pixels: Data) throws {
        guard layout == .raw16 else {
            throw PhantomError.protocolError("appendFrame requires raw16 layout; use appendPackedFrame")
        }
        guard pixels.count == frameBytes else {
            throw PhantomError.protocolError("frame size \(pixels.count) != \(frameBytes)")
        }
        var block = Data(capacity: 8 + frameBytes)
        block.append(le32(8))                       // annotation size (just the two u32s)
        block.append(le32(UInt32(frameBytes)))      // image size
        // Flip vertically and shift each pixel >>4 (camera P16 is left-justified 12-bit).
        let w = meta.width, h = meta.height
        var out = [UInt16](repeating: 0, count: w * h)
        pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let p = src.bindMemory(to: UInt16.self)
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let srcRow = p.baseAddress! + row * w
                    let dstRow = dst.baseAddress! + (h - 1 - row) * w
                    for x in 0..<w {
                        dstRow[x] = UInt16(littleEndian: srcRow[x].littleEndian) >> 4
                    }
                }
            }
        }
        out.withUnsafeBufferPointer { block.append(Data(buffer: $0)) }
        handle.write(block)
        framesWritten += 1
    }

    /// Appends one frame of already-packed BI_PACKED (10-bit, 4px/5 bytes, MSB
    /// first, top-down) pixel bytes exactly as received from the ximg stream.
    /// No row flip and no bit shift — the bytes are written verbatim, which is
    /// precisely how PCC stores packed cines and how CineReader expects them.
    public func appendPackedFrame(_ packed: Data) throws {
        guard layout == .packed10 else {
            throw PhantomError.protocolError("appendPackedFrame requires packed10 layout")
        }
        guard packed.count == frameBytes else {
            throw PhantomError.protocolError("packed frame size \(packed.count) != \(frameBytes)")
        }
        var block = Data(capacity: 8 + frameBytes)
        block.append(le32(8))                       // annotation size (just the two u32s)
        block.append(le32(UInt32(frameBytes)))      // image size
        block.append(packed)
        handle.write(block)
        framesWritten += 1
    }

    public func finish() {
        try? handle.close()
    }

    // MARK: header builders

    static func fileHeader(meta: CineMetadata, frameCount: Int, setupLen: Int = handBuiltSetupSize) -> Data {
        var d = Data()
        d.append(contentsOf: [0x43, 0x49])          // "CI"
        d.append(le16(UInt16(headerSize)))
        // CC_UNINT (2) = uninterpolated color RAW (what PCC writes for a CFA
        // sensor); CC_RGB (0) = gray. Writing 0 for a color cine made Resolve
        // crash — it must match the sensor's color nature.
        d.append(le16(meta.cfa != 0 ? 2 : 0))       // Compression
        d.append(le16(1))                           // Version 1
        d.append(le32s(Int32(meta.firstMovieImage)))
        d.append(le32(UInt32(meta.totalFrames)))
        d.append(le32s(Int32(meta.firstImageNo)))
        d.append(le32(UInt32(frameCount)))
        d.append(le32(UInt32(headerSize)))                       // OffImageHeader
        d.append(le32(UInt32(headerSize + bmiSize)))             // OffSetup
        d.append(le32(UInt32(headerSize + bmiSize + setupLen)))  // OffImageOffsets
        d.append(le32(meta.triggerFrac))            // TIME64: fractions then seconds
        d.append(le32(meta.triggerSecs))
        return d
    }

    static func bitmapHeader(meta: CineMetadata, layout: PixelLayout) -> Data {
        let frameBytes = layout.frameBytes(width: meta.width, height: meta.height)
        // PCC writes POSITIVE biHeight even for top-down BI_PACKED frames, and
        // Resolve relies on that. Match it (negative height crashed Resolve).
        let heightField = Int32(meta.height)
        var d = Data()
        d.append(le32(UInt32(bmiSize)))
        d.append(le32s(Int32(meta.width)))
        d.append(le32s(heightField))
        d.append(le16(1))                           // planes
        d.append(le16(16))                          // bitCount (unused by packed decode)
        d.append(le32(layout == .packed10 ? 256 : 0))   // BI_PACKED (256) or BI_RGB (0)
        d.append(le32(UInt32(frameBytes)))
        d.append(le32s(0)); d.append(le32s(0))      // pels per meter
        d.append(le32(0))
        // biClrImportant = max valid sample + 1, per bit depth. Packed-10 (VEO ximg)
        // holds 10-bit samples → 1024; the raw16 path holds 12-bit → 4096. Hardcoding
        // 4096 on a 10-bit clip made viewers normalize against a 4× ceiling = ~2 stops
        // under. (This is a header field, independent of camera develop/gain.)
        d.append(le32(layout == .packed10 ? 1024 : 4096))   // biClrImportant
        return d
    }

    /// SETUP block. For packed-10 (the ximg/standard path) we start from a real
    /// VEO4K template (full color/calibration metadata Resolve needs) and patch
    /// only the per-clip scalars at their fixed offsets. raw16 keeps the
    /// hand-built sparse block.
    static func setupBlock(meta: CineMetadata, layout: PixelLayout) -> Data {
        if layout == .packed10 {
            return templateSetupBlock(meta: meta)
        }
        return handBuiltSetupBlock(meta: meta, layout: layout)
    }

    /// Patches per-clip fields over the embedded VEO template (offsets verified
    /// stable across the modern 18,052-byte layout — they live in the first
    /// 10,688 bytes shared with the older struct).
    static func templateSetupBlock(meta: CineMetadata) -> Data {
        var s = VEOSetupTemplate.data
        func put(_ off: Int, _ v: Data) { s.replaceSubrange(off..<off+v.count, with: v) }
        // Fixed-width NUL-terminated C string. Unlike the hand-built block —
        // which starts from a zero-filled buffer — this one overwrites a DONOR
        // string, so it must clear the whole field. Writing only "name\0" over
        // a longer donor name ("Phantom VEO4K PL RLS") leaves the tail sitting
        // past the terminator; harmless to a C-string reader, confusing in a hex
        // dump.
        //
        // CameraModel is char[256] (Phint.h MAXSTDSTRSZ) at 0x2790..0x288F —
        // EXACTLY 256 bytes, no slack. Do NOT widen it on the arithmetic to
        // MagSerial (0x2898): the 8 bytes at 0x2890 are two separate live
        // fields — real PCC-written Flex files hold u32 = 1 and float 1.0 there.
        func cstr(_ off: Int, _ str: String, _ maxLen: Int) {
            var bytes = Array(str.utf8.prefix(maxLen - 1))
            bytes.append(contentsOf: [UInt8](repeating: 0, count: maxLen - bytes.count))
            put(off, Data(bytes))
        }
        let rate = max(meta.frameRate, 1)
        put(0,    le16(UInt16(min(rate, 65535))))                 // FrameRate16
        put(2,    le16(UInt16(min(meta.exposureNs / 1000, 65535))))// Shutter16 (µs)
        put(737,  le16(UInt16(meta.width)))                       // ImWidth
        put(739,  le16(UInt16(meta.height)))                      // ImHeight
        put(743,  le32(UInt32(meta.serial)))                      // Serial
        put(768,  le32(UInt32(rate)))                             // FrameRateInt
        put(772,  le32(UInt32(meta.exposureNs / 1000)))           // Shutter (µs)
        put(780,  le32(UInt32(meta.postTrigger)))                 // PostTrigger
        put(1568, le32(UInt32(meta.exposureNs)))                  // ShutterNs
        put(10400, led(Double(rate)))                             // dFrameRate
        // Patch CFA from the actual camera so color is correct-by-construction,
        // not correct-by-accident (VEO/Flex both = 3 today, but don't assume).
        put(808, le32(UInt32(meta.cfa)))                          // CFA
        // Black/white levels + RealBPP stay from the template (correct for P10).
        // Conv8Max: 10-bit data → 1023 (the template's donor had 4095 = 12-bit,
        // which made 8-bit conversions in other apps come out dark).
        put(904, le32(1023))                                      // Conv8Max
        // CAMERA IDENTITY. Without these the file inherits the template donor's
        // identity — every Flex 4K download announced itself as a
        // "Phantom VEO4K PL RLS", and apps that pick camera-specific handling
        // off CameraVersion applied VEO behaviour to Flex footage.
        //
        // BOTH fields are written UNCONDITIONALLY. Writing the model but leaving
        // CameraVersion conditional produced a self-contradicting file whenever
        // hwver was unknown: model "Phantom Flex4K" next to the donor's VEO4K
        // CameraVersion. Zero means "unknown", which is honest; the donor's
        // value is an affirmative lie about a different camera.
        cstr(10128, meta.cameraModel, 256)                        // CameraModel
        put(792, le32(UInt32(max(meta.cameraVersion, 0))))        // CameraVersion (info.hwver)
        // Develop metadata (WB, tone curve, colour matrix) — the CAMERA's real
        // values, not the template donor's. See patchDevelop.
        patchDevelop(into: &s, meta: meta)
        return s
    }

    /// Stamp the camera's REAL develop state over a SETUP block. The template (and the
    /// hand-built block) otherwise carry placeholder develop values — neutral WB, the
    /// donor camera's cmCalib, and a leftover EI tone curve — which any metadata-honouring
    /// app (PCC, Seance, PhantomFuse, Resolve) renders as washed-out / wrong colour.
    /// SETUP offsets: WBGain[0] 852/856 · WBView 888/892 · ToneLabel[256] 6056 ·
    /// TonePoints(i32) 6312 · fTone[32×2] 6316 · cmCalib[9] 7252.
    static func patchDevelop(into s: inout Data, meta: CineMetadata) {
        func put(_ off: Int, _ v: Data) { s.replaceSubrange(off..<off+v.count, with: v) }
        // White balance (green = 1.0 by convention; only pair [0] is the whole image).
        if meta.wbRed > 0.01, meta.wbBlue > 0.01 {
            put(852, lef(meta.wbRed)); put(856, lef(meta.wbBlue))   // WBGain[0]
            put(888, lef(meta.wbRed)); put(892, lef(meta.wbBlue))   // WBView
        }
        // Tone curve — write the camera's ACTUAL curve; when the camera holds a neutral
        // tone ("" / no points) explicitly ZERO the block so no template curve leaks in.
        if meta.toneKnown {
            var label = ""
            var pts: [Float] = []
            for tok in meta.toneString.split(whereSeparator: { " \",".contains($0) }) {
                if let f = Float(tok) { pts.append(f) } else if label.isEmpty { label = String(tok) }
            }
            if pts.count % 2 == 1 { pts.removeLast() }        // defensive: full x,y pairs only
            let pairs = min(pts.count / 2, 32)
            var lbl = Array(label.utf8.prefix(255)); lbl.append(0)
            put(6056, Data(repeating: 0, count: 256))          // clear ToneLabel
            put(6056, Data(lbl))
            put(6312, le32s(Int32(pairs)))                     // TonePoints
            put(6316, Data(repeating: 0, count: 256))          // clear fTone[32×2]
            for i in 0..<(pairs * 2) { put(6316 + i*4, lef(pts[i])) }
        }
        // Colour calibration matrix (camera → Rec709, WB folded) — THIS camera's, from
        // its own cmatrix, replacing the template donor's calibration.
        if meta.calMatrix.count == 9 {
            for i in 0..<9 { put(7252 + i*4, lef(meta.calMatrix[i])) }
        }
    }

    /// Offsets generated from Phint.h tagSETUP with pack(1). Field: byte offset.
    static func handBuiltSetupBlock(meta: CineMetadata, layout: PixelLayout) -> Data {
        // RealBPP/RecBPP differ by layout: packed-10 frames carry 10 real bits
        // (companded), the raw16 path stores 12-bit values left-justified.
        let realBPP: UInt32 = layout == .packed10 ? 10 : 12
        var s = Data(repeating: 0, count: handBuiltSetupSize)
        func put(_ off: Int, _ v: Data) { s.replaceSubrange(off..<off+v.count, with: v) }
        func cstr(_ off: Int, _ str: String, _ maxLen: Int) {
            var bytes = Array(str.utf8.prefix(maxLen - 1)); bytes.append(0)
            put(off, Data(bytes))
        }
        put(0, le16(UInt16(min(meta.frameRate, 65535))))            // FrameRate16
        put(2, le16(UInt16(min(meta.exposureNs / 1000, 65535))))    // Shutter16 (µs)
        cstr(12, meta.cineName, 121)                                // DescriptionOld
        put(140, Data([0x53, 0x54]))                                // Mark "ST"
        put(142, le16(UInt16(handBuiltSetupSize)))                  // Length
        put(737, le16(UInt16(meta.width)))                          // ImWidth
        put(739, le16(UInt16(meta.height)))                         // ImHeight
        put(743, le32(UInt32(meta.serial)))                         // Serial
        put(768, le32(UInt32(meta.frameRate)))                      // FrameRateInt
        put(772, le32(UInt32(meta.exposureNs / 1000)))              // Shutter (µs legacy)
        put(780, le32(UInt32(meta.postTrigger)))                    // PostTrigger
        put(788, le32(1))                                           // bEnableColor
        // CameraVersion = the camera's own info.hwver. This used to be a
        // hardcoded literal 7 on every body, which is not a real Phantom camera
        // version at all — our own .cine files show a Flex reporting 135. Write
        // the true value when we know it, and leave the field unset (0) rather
        // than assert a wrong one.
        if meta.cameraVersion > 0 {
            put(792, le32(UInt32(meta.cameraVersion)))              // CameraVersion (info.hwver)
        }
        put(800, le32(806))                                         // SoftwareVersion
        put(808, le32(UInt32(meta.cfa)))                            // CFA
        for i in 0..<4 {                                            // WBGain[4] = 1.0,1.0
            put(852 + i*8, lef(1.0)); put(852 + i*8 + 4, lef(1.0))
        }
        put(888, lef(1.0)); put(892, lef(1.0))                      // WBView
        put(896, le32(realBPP))                                     // RealBPP
        put(900, le32(0))                                           // Conv8Min
        put(904, le32(4095))                                        // Conv8Max
        put(1568, le32(UInt32(meta.exposureNs)))                    // ShutterNs
        put(5732, le32s(64))                                        // BlackLevel
        put(5736, le32s(4064))                                      // WhiteLevel
        put(6012, lef(1.0))                                         // fGain
        put(6016, lef(1.0))                                         // fSaturation
        put(6024, lef(1.0))                                         // fGamma
        put(6052, lef(1.0))                                         // fChroma
        put(6312, le32s(0))                                         // TonePoints
        put(6900, lef(1.0))                                         // fGain16_8
        put(6976, lef(24.0))                                        // fPbRate
        put(6980, lef(24.0))                                        // fTcRate
        cstr(6984, meta.cineName, 256)                              // CineName
        put(7240, lef(1.0)); put(7244, lef(1.0)); put(7248, lef(1.0)) // fGainR/G/B
        put(10112, le32(realBPP))                                   // RecBPP
        cstr(10128, meta.cameraModel, 256)                          // CameraModel
        put(10400, led(Double(meta.frameRate)))                     // dFrameRate
        // Stamp the camera's real develop state (WB / tone / matrix) over the
        // placeholder values above — same fix as the template path.
        patchDevelop(into: &s, meta: meta)
        return s
    }

    static func offsetTable(frameCount: Int, dataStart: UInt64, frameBytes: Int) -> Data {
        var d = Data(capacity: frameCount * 8)
        var off = dataStart
        for _ in 0..<frameCount {
            var v = off.littleEndian
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            off += UInt64(8 + frameBytes)
        }
        return d
    }
}

private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32s(_ v: Int32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func lef(_ v: Float) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
private func led(_ v: Double) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
