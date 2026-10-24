import Foundation

/// Reads Vision Research .cine files.
///
/// Supports (per "Cine File Format.pdf", SDK 3.12):
///   - version 0 (32-bit image offsets) and version 1 (64-bit) files
///   - BI_RGB (0): uncompressed 16bpp gray/raw, bottom-up rows, values
///     right-justified to RealBPP bits
///   - BI_PACKED (256): 10-bit packed (4 px in 5 bytes, MSB first), top-down,
///     Rec.709-companded — linearized to 12 bit via the Appendix 1 LUT
///   - BI_PACKED12L (1024): 12-bit packed (2 px in 3 bytes, MSB first), top-down
///
/// Decoded frames are returned top-down with values left-justified to 16 bits
/// so all bit depths share one scale. Black/white levels are scaled to match.
public struct CineFileInfo {
    public var width: Int
    public var height: Int
    public var frameCount: Int
    public var version: Int
    public var fileCompression: Int      // CINEFILEHEADER.Compression (0 gray, 2 raw CFA)
    public var biCompression: Int        // 0 raw16, 256 packed10, 1024 packed12L
    public var realBPP: Int              // bit depth after decode (12 for packed10)
    public var cfa: Int                  // 0 = mono, 3 = GBRG bayer (Flex/VEO)
    public var frameRate: Double         // recording rate
    public var playbackFPS: Double       // fPbRate — intended playback rate (e.g. 24)
    public var blackLevel16: Int         // left-justified to 16-bit scale
    public var whiteLevel16: Int
    public var wbGainRed: Float
    public var wbGainBlue: Float
    public var firstImageNo: Int
    public var triggerSecs: UInt32
    public var triggerFrac: UInt32
    public var cameraModel: String
    public var serial: Int
    public var exposureNs: Int

    public var isColor: Bool { cfa != 0 }
    public var durationSeconds: Double { playbackFPS > 0 ? Double(frameCount) / playbackFPS : 0 }
}

public struct CineFrame16 {
    public let width: Int
    public let height: Int
    /// Top-down row order, one UInt16 per pixel, left-justified to 16 bits.
    public let pixels: [UInt16]
}

/// All state is immutable after init and frame reads use pread (no shared
/// file position), so concurrent reads from any thread are safe.
public final class CineReader: @unchecked Sendable {
    public let url: URL
    public let info: CineFileInfo
    private let fd: Int32
    private let imageOffsets: [UInt64]
    private let biSizeImage: Int

    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw PhantomError.socketError("cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        self.fd = fd
        do {
            (self.info, self.imageOffsets, self.biSizeImage) = try Self.parseHeader(fd: fd)
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(fd) }

    private static func parseHeader(fd: Int32) throws -> (CineFileInfo, [UInt64], Int) {
        func bad(_ msg: String) -> PhantomError { .protocolError("not a readable .cine file: \(msg)") }
        let head = try pread(fd: fd, offset: 0, count: 44)
        guard head.count == 44, head[0] == 0x43, head[1] == 0x49 else {
            throw bad("missing CI marker")
        }
        let fileCompression = Int(head.u16(2 + 2))     // Type(2) Headersize(2) → Compression
        let version = Int(head.u16(6))
        guard version == 0 || version == 1 else { throw bad("unsupported version \(version)") }
        guard fileCompression == 0 || fileCompression == 2 else {
            throw bad("compression \(fileCompression) (JPEG .cci files are not supported)")
        }
        let firstImageNo = Int(Int32(bitPattern: head.u32(16)))
        let imageCount = Int(head.u32(20))
        let offImageHeader = Int(head.u32(24))
        let offSetup = Int(head.u32(28))
        let offImageOffsets = Int(head.u32(32))
        let triggerFrac = head.u32(36)
        let triggerSecs = head.u32(40)
        guard imageCount > 0 else { throw bad("file contains no images") }

        let bmi = try pread(fd: fd, offset: UInt64(offImageHeader), count: 40)
        guard bmi.count == 40 else { throw bad("truncated BITMAPINFOHEADER") }
        let width = Int(Int32(bitPattern: bmi.u32(4)))
        let height = abs(Int(Int32(bitPattern: bmi.u32(8))))
        let bitCount = Int(bmi.u16(14))
        let biCompression = Int(bmi.u32(16))
        let biSizeImage = Int(bmi.u32(20))
        guard width > 0, height > 0 else { throw bad("bad dimensions \(width)x\(height)") }
        switch biCompression {
        case 0:
            guard bitCount == 16 else {
                throw bad("unsupported \(bitCount)bpp uncompressed image (only 16bpp raw is supported)")
            }
        case 256, 1024: break
        default: throw bad("unsupported biCompression \(biCompression)")
        }

        // SETUP — guard every field read against the structure length in the
        // file (old files have shorter setups; missing fields keep defaults).
        let setupHead = try pread(fd: fd, offset: UInt64(offSetup) + 140, count: 4)
        guard setupHead.count == 4, setupHead[0] == 0x53, setupHead[1] == 0x54 else {
            throw bad("missing SETUP marker")
        }
        let setupLen = Int(setupHead.u16(2))
        let setup = try pread(fd: fd, offset: UInt64(offSetup), count: setupLen)
        func u16At(_ off: Int, _ def: Int) -> Int { off + 2 <= setup.count ? Int(setup.u16(off)) : def }
        func u32At(_ off: Int, _ def: Int) -> Int { off + 4 <= setup.count ? Int(setup.u32(off)) : def }
        func i32At(_ off: Int, _ def: Int) -> Int { off + 4 <= setup.count ? Int(Int32(bitPattern: setup.u32(off))) : def }
        func f32At(_ off: Int, _ def: Float) -> Float {
            guard off + 4 <= setup.count else { return def }
            let v = Float(bitPattern: setup.u32(off))
            return v.isFinite ? v : def
        }
        func f64At(_ off: Int, _ def: Double) -> Double {
            guard off + 8 <= setup.count else { return def }
            let v = Double(bitPattern: setup.u64(off))
            return v.isFinite ? v : def
        }
        func strAt(_ off: Int, _ maxLen: Int) -> String {
            guard off < setup.count else { return "" }
            let slice = setup[off..<min(off + maxLen, setup.count)]
            let bytes = slice.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }

        let cfa = u32At(808, 0)
        var realBPP = u32At(896, 12)
        if realBPP <= 0 || realBPP > 16 { realBPP = 12 }
        // Packed-10 frames are linearized through the LUT to 12-bit values.
        if biCompression == 256 || biCompression == 1024 { realBPP = 12 }
        let shift = 16 - realBPP

        var black = i32At(5732, 0)
        var white = i32At(5736, (1 << realBPP) - 1)
        let maxVal = (1 << realBPP) - 1
        if !(black >= 0 && black < white && white <= maxVal) { black = 0; white = maxVal }

        var frameRate = f64At(10400, 0)
        if frameRate <= 0 { frameRate = Double(u32At(768, u16At(0, 24))) }
        var pbRate = Double(f32At(6976, 0))
        if pbRate <= 0 { pbRate = 24 }

        var exposureNs = u32At(1568, 0)
        if exposureNs == 0 { exposureNs = u32At(772, 0) * 1000 }

        let info = CineFileInfo(
            width: width, height: height, frameCount: imageCount,
            version: version, fileCompression: fileCompression,
            biCompression: biCompression, realBPP: realBPP, cfa: cfa,
            frameRate: frameRate, playbackFPS: pbRate,
            blackLevel16: black << shift, whiteLevel16: white << shift,
            wbGainRed: max(f32At(852, 1), 0.01), wbGainBlue: max(f32At(856, 1), 0.01),
            firstImageNo: firstImageNo,
            triggerSecs: triggerSecs, triggerFrac: triggerFrac,
            cameraModel: strAt(10128, 256), serial: u32At(743, 0),
            exposureNs: exposureNs)

        // Image offset table: u32 entries in version 0 files, u64 in version 1.
        let entrySize = version == 0 ? 4 : 8
        let table = try pread(fd: fd, offset: UInt64(offImageOffsets), count: imageCount * entrySize)
        guard table.count == imageCount * entrySize else { throw bad("truncated image offset table") }
        var offsets = [UInt64](repeating: 0, count: imageCount)
        for i in 0..<imageCount {
            offsets[i] = version == 0 ? UInt64(table.u32(i * 4)) : table.u64(i * 8)
        }
        return (info, offsets, biSizeImage)
    }

    /// Decodes one frame (0-based index). Thread-safe — uses pread, no shared
    /// file position, so playback and transcode can read concurrently.
    public func readFrame(_ index: Int) throws -> CineFrame16 {
        guard index >= 0 && index < info.frameCount else {
            throw PhantomError.protocolError("frame \(index) out of range 0..<\(info.frameCount)")
        }
        let base = imageOffsets[index]
        // Each image: u32 AnnotationSize (includes itself and the trailing
        // u32 ImageSize) | annotation bytes | u32 ImageSize | pixels.
        let annHead = try Self.pread(fd: fd, offset: base, count: 4)
        guard annHead.count == 4 else { throw PhantomError.protocolError("truncated frame \(index)") }
        var annSize = Int(annHead.u32(0))
        if annSize < 8 || annSize > 1 << 20 { annSize = 8 }
        let sizeData = try Self.pread(fd: fd, offset: base + UInt64(annSize) - 4, count: 4)
        var imageSize = sizeData.count == 4 ? Int(sizeData.u32(0)) : 0
        if imageSize <= 0 { imageSize = biSizeImage }

        let w = info.width, h = info.height
        let expected: Int
        switch info.biCompression {
        case 256: expected = (w * h * 10 + 7) / 8
        case 1024: expected = (w * h * 12 + 7) / 8
        default: expected = w * h * 2
        }
        let data = try Self.pread(fd: fd, offset: base + UInt64(annSize), count: max(imageSize, expected))
        guard data.count >= expected else {
            throw PhantomError.protocolError("frame \(index): got \(data.count) bytes, need \(expected)")
        }

        var out = [UInt16](repeating: 0, count: w * h)
        switch info.biCompression {
        case 256: Self.unpack10(data, width: w, height: h, into: &out)
        case 1024: Self.unpack12L(data, width: w, height: h, into: &out)
        default: Self.unpackRaw16(data, width: w, height: h, shift: 16 - info.realBPP, into: &out)
        }
        return CineFrame16(width: w, height: h, pixels: out)
    }

    /// Returns the raw, still-packed pixel bytes for one frame plus the size
    /// the GPU unpacker should expect, without doing any CPU unpacking/LUT.
    /// `biCompression`/`realBPP`/dimensions come from `info`. Thread-safe.
    public func readRawFrame(_ index: Int) throws -> Data {
        guard index >= 0 && index < info.frameCount else {
            throw PhantomError.protocolError("frame \(index) out of range 0..<\(info.frameCount)")
        }
        let base = imageOffsets[index]
        let annHead = try Self.pread(fd: fd, offset: base, count: 4)
        guard annHead.count == 4 else { throw PhantomError.protocolError("truncated frame \(index)") }
        var annSize = Int(annHead.u32(0))
        if annSize < 8 || annSize > 1 << 20 { annSize = 8 }
        let sizeData = try Self.pread(fd: fd, offset: base + UInt64(annSize) - 4, count: 4)
        var imageSize = sizeData.count == 4 ? Int(sizeData.u32(0)) : 0
        if imageSize <= 0 { imageSize = biSizeImage }

        let w = info.width, h = info.height
        let expected: Int
        switch info.biCompression {
        case 256: expected = (w * h * 10 + 7) / 8
        case 1024: expected = (w * h * 12 + 7) / 8
        default: expected = w * h * 2
        }
        let data = try Self.pread(fd: fd, offset: base + UInt64(annSize), count: max(imageSize, expected))
        guard data.count >= expected else {
            throw PhantomError.protocolError("frame \(index): got \(data.count) bytes, need \(expected)")
        }
        return data.count == expected ? data : data.prefix(expected)
    }

    // MARK: pixel decoders

    /// BI_RGB 16bpp: bottom-up rows, right-justified values → flip + left-justify.
    private static func unpackRaw16(_ data: Data, width w: Int, height h: Int,
                                    shift: Int, into out: inout [UInt16]) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.baseAddress!
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let srcRow = src + (h - 1 - row) * w * 2
                    let dstRow = dst.baseAddress! + row * w
                    for x in 0..<w {
                        let v = srcRow.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)
                        dstRow[x] = UInt16(littleEndian: v) << shift
                    }
                }
            }
        }
    }

    /// Public wrapper for decoding a raw packed-10 frame that never touched a
    /// .cine file — e.g. a single ximg fmt:flash frame grabbed for a thumbnail.
    public static func unpackPacked10(_ data: Data, width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height)
        unpack10(data, width: width, height: height, into: &out)
        return out
    }

    /// BI_PACKED: 4 pixels in 5 bytes, MSB first, top-down, companded 10-bit.
    /// Linearized to 12 bit through the Appendix 1 LUT, then left-justified.
    private static func unpack10(_ data: Data, width w: Int, height h: Int,
                                 into out: inout [UInt16]) {
        let n = w * h
        cineLinLUT.withUnsafeBufferPointer { lut in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let b = raw.bindMemory(to: UInt8.self).baseAddress!
                out.withUnsafeMutableBufferPointer { dst in
                    var i = 0, p = 0
                    while i + 4 <= n {
                        let b0 = Int(b[p]), b1 = Int(b[p+1]), b2 = Int(b[p+2])
                        let b3 = Int(b[p+3]), b4 = Int(b[p+4])
                        dst[i]   = lut[(b0 << 2) | (b1 >> 6)] << 4
                        dst[i+1] = lut[((b1 & 0x3F) << 4) | (b2 >> 4)] << 4
                        dst[i+2] = lut[((b2 & 0x0F) << 6) | (b3 >> 2)] << 4
                        dst[i+3] = lut[((b3 & 0x03) << 8) | b4] << 4
                        i += 4; p += 5
                    }
                    // width*height not divisible by 4: trailing pixels
                    if i < n {
                        var acc = 0, bits = 0
                        while i < n {
                            while bits < 10 { acc = (acc << 8) | Int(b[p]); p += 1; bits += 8 }
                            dst[i] = lut[(acc >> (bits - 10)) & 0x3FF] << 4
                            bits -= 10; i += 1
                        }
                    }
                }
            }
        }
    }

    /// BI_PACKED12L: 2 pixels in 3 bytes, MSB first, top-down, 12-bit linear.
    private static func unpack12L(_ data: Data, width w: Int, height h: Int,
                                  into out: inout [UInt16]) {
        let n = w * h
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self).baseAddress!
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0, p = 0
                while i + 2 <= n {
                    let b0 = UInt16(b[p]), b1 = UInt16(b[p+1]), b2 = UInt16(b[p+2])
                    dst[i]   = ((b0 << 4) | (b1 >> 4)) << 4
                    dst[i+1] = (((b1 & 0x0F) << 8) | b2) << 4
                    i += 2; p += 3
                }
                if i < n {  // odd pixel count
                    let b0 = UInt16(b[p]), b1 = UInt16(b[p+1])
                    dst[i] = ((b0 << 4) | (b1 >> 4)) << 4
                }
            }
        }
    }

    // MARK: low-level IO

    private static func pread(fd: Int32, offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { buf -> Int in
            var done = 0
            while done < count {
                let n = Darwin.pread(fd, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n <= 0 { break }
                done += n
            }
            return done
        }
        if got < count { data.removeSubrange(got..<count) }
        return data
    }
}

// MARK: little-endian Data accessors

private extension Data {
    func u16(_ off: Int) -> UInt16 {
        let i = startIndex + off
        return UInt16(self[i]) | (UInt16(self[i+1]) << 8)
    }
    func u32(_ off: Int) -> UInt32 {
        let i = startIndex + off
        return UInt32(self[i]) | (UInt32(self[i+1]) << 8) | (UInt32(self[i+2]) << 16) | (UInt32(self[i+3]) << 24)
    }
    func u64(_ off: Int) -> UInt64 {
        UInt64(u32(off)) | (UInt64(u32(off + 4)) << 32)
    }
}
