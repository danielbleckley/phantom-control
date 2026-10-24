import Foundation
import AVFoundation
import CoreVideo
import Metal
import VideoToolbox

/// App-wide "vertical mode" rotation in degrees clockwise (0/90/180/270). The app
/// keeps this in sync with the monitor's Vertical toggle; exports and thumbnails
/// read it so a sideways-mounted-camera shoot bakes upright automatically.
public enum ExportRotation {
    public nonisolated(unsafe) static var current = 0
}

/// GPU-accelerated .cine → ProRes/H.264/HEVC transcoder.
///
/// Pipeline, all overlapped:
///   disk read (background prefetch) → Metal unpack + demosaic/grade
///   (MetalDebayer) → CVPixelBuffer-backed texture → AVAssetWriter, which
///   drives the Apple-Silicon hardware ProRes/H.264/HEVC encoder.
///
/// No CPU debayer and no CPU pixel round-trips — the graded frame is produced
/// directly in the encoder's pixel buffer. Replaces the ~0.9 fps CPU
/// CineTranscoder for large 4K cines.
public final class GPUTranscoder {

    public enum Codec: String, CaseIterable, Sendable {
        case proRes422HQ = "ProRes 422 HQ"
        case proRes422   = "ProRes 422"
        case proRes422LT = "ProRes 422 LT"
        case proResProxy = "ProRes 422 Proxy"
        case h264        = "H.264"
        case hevc        = "HEVC"

        var avCodec: AVVideoCodecType {
            switch self {
            case .proRes422HQ: return .proRes422HQ
            case .proRes422:   return .proRes422
            case .proRes422LT: return .proRes422LT
            case .proResProxy: return .proRes422Proxy
            case .h264:        return .h264
            case .hevc:        return .hevc
            }
        }
        public var isProRes: Bool {
            switch self {
            case .h264, .hevc: return false
            default: return true
            }
        }
        /// CVPixelBuffer format the GPU writes into and the encoder ingests.
        var cvPixelFormat: OSType {
            isProRes ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        }
        var metalPixelFormat: MTLPixelFormat {
            isProRes ? .rgba16Float : .bgra8Unorm
        }
        /// VideoToolbox codec four-cc for the hardware-encoder probe.
        var fourCC: CMVideoCodecType {
            switch self {
            case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
            case .proRes422:   return kCMVideoCodecType_AppleProRes422
            case .proRes422LT: return kCMVideoCodecType_AppleProRes422LT
            case .proResProxy: return kCMVideoCodecType_AppleProRes422Proxy
            case .h264:        return kCMVideoCodecType_H264
            case .hevc:        return kCMVideoCodecType_HEVC
            }
        }
    }

    /// Compression quality for the variable-bitrate codecs (H.264 / HEVC).
    /// ProRes ignores this — its data rate is fixed by codec + resolution.
    public enum Quality: String, CaseIterable, Sendable {
        case small = "Small"        // email / text
        case balanced = "Balanced"
        case high = "High"

        /// Target bits per pixel per frame (H.264 baseline; HEVC scaled down).
        var bitsPerPixel: Double {
            switch self {
            case .small: return 0.06
            case .balanced: return 0.12
            case .high: return 0.24
            }
        }
    }

    /// Output resolution preset — scales by the source's aspect ratio.
    public enum Resolution: String, CaseIterable, Sendable {
        case full = "Full"
        case uhd2160 = "2160p"
        case hd1080 = "1080p"
        case hd720 = "720p"

        /// Target height in pixels, or 0 for "keep source".
        public var targetHeight: Int {
            switch self {
            case .full: return 0
            case .uhd2160: return 2160
            case .hd1080: return 1080
            case .hd720: return 720
            }
        }
    }

    public struct Options {
        public var codec: Codec
        public var fps: Double
        public var firstFrame: Int
        public var lastFrame: Int
        public var settings: Debayer16.RenderSettings
        public var outputWidth: Int       // encoded frame size (<= source)
        public var outputHeight: Int
        public var quality: Quality
        public var rotate = 0             // vertical mode: bake a 0/90/180/270° CW rotation into the .mov

        public init(codec: Codec = .proRes422HQ, fps: Double = 0,
                    firstFrame: Int = 0, lastFrame: Int = .max,
                    settings: Debayer16.RenderSettings? = nil,
                    resolution: Resolution = .full, quality: Quality = .balanced,
                    rotate: Int = ExportRotation.current,
                    info: CineFileInfo) {
            self.codec = codec
            self.fps = fps > 0 ? fps : (info.playbackFPS > 0 ? info.playbackFPS : 24)
            self.firstFrame = max(0, firstFrame)
            self.lastFrame = min(lastFrame, info.frameCount - 1)
            self.settings = settings ?? Debayer16.RenderSettings(info: info)
            let dims = GPUTranscoder.fitDimensions(srcW: info.width, srcH: info.height,
                                                   targetHeight: resolution.targetHeight)
            self.outputWidth = dims.w
            self.outputHeight = dims.h
            self.quality = quality
            self.rotate = ((rotate % 360) + 360) % 360
        }
    }

    /// Fits a target height to the source aspect ratio, rounding to even
    /// dimensions (required by H.264/HEVC). Never upscales.
    public static func fitDimensions(srcW: Int, srcH: Int, targetHeight: Int) -> (w: Int, h: Int) {
        guard targetHeight > 0, targetHeight < srcH else { return (srcW, srcH) }
        let scale = Double(targetHeight) / Double(srcH)
        let w = max(2, Int((Double(srcW) * scale).rounded()) & ~1)
        let h = max(2, targetHeight & ~1)
        return (w, h)
    }

    /// Estimated output size in bytes for the given settings. ProRes uses a
    /// per-codec bytes-per-pixel table; H.264/HEVC use bits-per-pixel × frames.
    public static func estimatedBytes(codec: Codec, width: Int, height: Int,
                                      frames: Int, quality: Quality) -> Int {
        let pixels = Double(width) * Double(height) * Double(max(frames, 0))
        if codec.isProRes {
            let bytesPerPixel: Double
            switch codec {
            case .proRes422HQ: bytesPerPixel = 0.48
            case .proRes422:   bytesPerPixel = 0.32
            case .proRes422LT: bytesPerPixel = 0.22
            case .proResProxy: bytesPerPixel = 0.11
            default:           bytesPerPixel = 0.48
            }
            return Int(bytesPerPixel * pixels)
        } else {
            let hevcFactor = codec == .hevc ? 0.6 : 1.0
            return Int(quality.bitsPerPixel * hevcFactor * pixels / 8.0)
        }
    }

    /// Per-frame progress payload for live UI (MB/s + fps + fraction done).
    public struct Progress {
        public let fraction: Double
        public let framesDone: Int
        public let totalFrames: Int
        public let fps: Double
        public let mbPerSec: Double
    }

    /// Summary returned on success, including hardware-encoder confirmation.
    public struct Result {
        public let frames: Int
        public let seconds: Double
        public let fps: Double
        public let mbPerSec: Double
        public let outputBytes: Int
        public let hardwareEncoder: Bool
        public let encoderName: String
    }

    /// One clip in a stitched timeline export (file + its in/out trim).
    public struct StitchInput: Sendable {
        public let url: URL
        public let firstFrame: Int
        public let lastFrame: Int
        public init(url: URL, firstFrame: Int, lastFrame: Int) {
            self.url = url; self.firstFrame = firstFrame; self.lastFrame = lastFrame
        }
    }

    private let reader: CineReader
    private let debayer: MetalDebayer

    public init(reader: CineReader) throws {
        self.reader = reader
        self.debayer = try MetalDebayer()
    }

    /// Reports whether VideoToolbox lists a hardware encoder for `codec`,
    /// and its display name. Used to confirm the dedicated ProRes silicon is
    /// engaged rather than the software fallback.
    public static func hardwareEncoder(for codec: Codec) -> (available: Bool, name: String) {
        var listCF: CFArray?
        guard VTCopyVideoEncoderList(nil, &listCF) == noErr,
              let list = listCF as? [[String: Any]] else {
            return (false, "unknown")
        }
        let want = codec.fourCC
        for enc in list {
            guard let typeNum = enc[kVTVideoEncoderList_CodecType as String] as? NSNumber,
                  CMVideoCodecType(typeNum.int32Value) == want else { continue }
            let hw = (enc[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
            let name = (enc[kVTVideoEncoderList_DisplayName as String] as? String) ?? "unknown"
            if hw { return (true, name) }
        }
        // Fall back to the first encoder of this type (software).
        for enc in list {
            guard let typeNum = enc[kVTVideoEncoderList_CodecType as String] as? NSNumber,
                  CMVideoCodecType(typeNum.int32Value) == want else { continue }
            let name = (enc[kVTVideoEncoderList_DisplayName as String] as? String) ?? "unknown"
            return (false, name)
        }
        return (false, "none")
    }

    /// Runs the transcode synchronously (call off the main thread).
    /// `progress` returns false to cancel; the partial file is then removed.
    @discardableResult
    public func transcode(to outURL: URL, options: Options,
                          progress: (Progress) -> Bool = { _ in true }) throws -> Result {
        let info = reader.info
        let srcW = info.width, srcH = info.height
        // Encoded frame size (downscaled if requested), clamped to the source.
        let w = min(max(2, options.outputWidth), srcW)
        let h = min(max(2, options.outputHeight), srcH)
        let first = options.firstFrame
        let last = max(options.lastFrame, first)
        let total = last - first + 1

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            // Tag the output Rec.709 so editors/players interpret it correctly
            // (untagged files are guessed and can look off). We develop to 709.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !options.codec.isProRes {
            let hevcFactor = options.codec == .hevc ? 0.6 : 1.0
            let bitsPerSecond = options.quality.bitsPerPixel * hevcFactor
                * Double(w) * Double(h) * options.fps
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(max(200_000, bitsPerSecond)),
                AVVideoExpectedSourceFrameRateKey: Int(options.fps.rounded()),
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        // Vertical mode: bake the rotation into the track's preferred transform, so
        // players and editors (QuickTime, Resolve, Premiere) and social uploads show
        // it upright. Frames stay w×h; the transform rotates the display.
        if options.rotate != 0 {
            input.transform = CGAffineTransform(rotationAngle: CGFloat(-options.rotate) * .pi / 180)
        }
        guard writer.canAdd(input) else {
            throw PhantomError.protocolError("cannot configure \(options.codec.rawValue) writer")
        }
        writer.add(input)

        // Our own Metal-compatible, IOSurface-backed pixel buffer pool — the
        // GPU writes the graded frame straight into these, then we hand them to
        // the encoder. (The adaptor's default pool isn't Metal-compatible.)
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
        let bufAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: options.codec.cvPixelFormat,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                      bufAttrs as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw PhantomError.protocolError("cannot create pixel buffer pool")
        }

        guard writer.startWriting() else {
            throw PhantomError.protocolError("writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        func abort(_ error: Error?) throws -> Never {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            if let error { throw error }
            throw PhantomError.protocolError("transcode cancelled")
        }

        let timescale = CMTimeScale(min(max(options.fps.rounded() * 1000, 1000), 120_000))
        let frameDurValue = CMTimeValue((Double(timescale) / options.fps).rounded())
        let params = MetalDebayer.params(info: info, settings: options.settings)

        // Background prefetch keeps disk I/O overlapped with GPU + encode.
        let prefetch = FramePrefetcher(reader: reader, first: first, count: total, depth: 5)
        prefetch.start()

        let t0 = Date()
        var bytesRead = 0
        var cancelled = false

        for i in 0..<total {
            guard let (raw, err) = prefetch.next() else { break }
            if let err { prefetch.stop(); try abort(err) }
            guard let raw else { break }
            bytesRead += raw.count

            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { prefetch.stop(); try abort(writer.error) }
                usleep(1000)
            }

            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
            guard let buffer = pb,
                  let tex = debayer.makeTexture(from: buffer, pixelFormat: options.codec.metalPixelFormat) else {
                prefetch.stop()
                try abort(PhantomError.protocolError("pixel buffer / texture allocation failed"))
            }
            do {
                try debayer.render(rawPacked: raw, params: params, into: tex)
            } catch { prefetch.stop(); try abort(error) }

            let pts = CMTime(value: frameDurValue * CMTimeValue(i), timescale: timescale)
            if !input.append(sampleBuffer: buffer, presentationTime: pts) {
                prefetch.stop()
                try abort(writer.error ?? PhantomError.protocolError("frame append failed at \(i)"))
            }

            let elapsed = max(Date().timeIntervalSince(t0), 0.001)
            let done = i + 1
            let prog = Progress(
                fraction: Double(done) / Double(total),
                framesDone: done, totalFrames: total,
                fps: Double(done) / elapsed,
                mbPerSec: Double(bytesRead) / 1_048_576.0 / elapsed)
            if !progress(prog) { cancelled = true; break }
        }
        prefetch.stop()
        if cancelled { try abort(nil) }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outURL)
            throw writer.error ?? PhantomError.protocolError("transcode failed to finish")
        }

        let seconds = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
        let hw = Self.hardwareEncoder(for: options.codec)
        return Result(
            frames: total, seconds: seconds,
            fps: Double(total) / max(seconds, 0.001),
            mbPerSec: Double(bytesRead) / 1_048_576.0 / max(seconds, 0.001),
            outputBytes: size, hardwareEncoder: hw.available, encoderName: hw.name)
    }

    /// Concatenates many cines into a single .mov — a back-to-back review
    /// string (e.g. to upload a whole shoot day to Frame.io). Every clip is
    /// graded and scaled to one common output size (from the first clip + the
    /// resolution preset) and laid end to end on one timeline at a single rate.
    /// `inputs` are written in the given order — sort before calling.
    @discardableResult
    public static func transcodeStitched(inputs: [StitchInput], to outURL: URL,
                                         codec: Codec, fps: Double = 0,
                                         quality: Quality = .balanced,
                                         resolution: Resolution = .full,
                                         progress: (Progress) -> Bool = { _ in true }) throws -> Result {
        guard !inputs.isEmpty else { throw PhantomError.protocolError("no clips to stitch") }
        let debayer = try MetalDebayer()

        // Open every clip's header up front to fix the common size, timeline
        // rate, clamped trims and total frame count.
        struct Clip { let reader: CineReader; let first: Int; let last: Int; var count: Int { last - first + 1 } }
        var clips: [Clip] = []
        for input in inputs {
            let reader = try CineReader(url: input.url)
            let n = reader.info.frameCount
            let first = max(0, min(input.firstFrame, n - 1))
            let last = max(first, min(input.lastFrame, n - 1))
            clips.append(Clip(reader: reader, first: first, last: last))
        }
        let info0 = clips[0].reader.info
        let dims = fitDimensions(srcW: info0.width, srcH: info0.height, targetHeight: resolution.targetHeight)
        let w = dims.w, h = dims.h
        let timelineFps = fps > 0 ? fps : (info0.playbackFPS > 0 ? info0.playbackFPS : 24)
        let total = clips.reduce(0) { $0 + $1.count }

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isProRes {
            let hevcFactor = codec == .hevc ? 0.6 : 1.0
            let bps = quality.bitsPerPixel * hevcFactor * Double(w) * Double(h) * timelineFps
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(max(200_000, bps)),
                AVVideoExpectedSourceFrameRateKey: Int(timelineFps.rounded()),
            ]
        }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw PhantomError.protocolError("cannot configure \(codec.rawValue) writer")
        }
        writer.add(writerInput)

        let bufAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: codec.cvPixelFormat,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                      bufAttrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw PhantomError.protocolError("cannot create pixel buffer pool")
        }
        guard writer.startWriting() else {
            throw PhantomError.protocolError("writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        func abort(_ error: Error?) throws -> Never {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            if let error { throw error }
            throw PhantomError.protocolError("stitch cancelled")
        }

        let timescale = CMTimeScale(min(max(timelineFps.rounded() * 1000, 1000), 120_000))
        let frameDurValue = CMTimeValue((Double(timescale) / timelineFps).rounded())

        let t0 = Date()
        var bytesRead = 0
        var globalIndex = 0     // running position on the stitched timeline
        var cancelled = false

        outer: for clip in clips {
            let info = clip.reader.info
            let frame0 = try clip.reader.readFrame(clip.first)
            var settings = Debayer16.RenderSettings(info: info)
            if let wb = Debayer16.autoWhiteBalance(frame: frame0, cfa: info.cfa,
                                                   blackLevel16: info.blackLevel16) {
                settings.wbRed = wb.red; settings.wbBlue = wb.blue
            }
            let params = MetalDebayer.params(info: info, settings: settings)
            let prefetch = FramePrefetcher(reader: clip.reader, first: clip.first, count: clip.count, depth: 5)
            prefetch.start()

            for _ in 0..<clip.count {
                guard let (raw, err) = prefetch.next() else { break }
                if let err { prefetch.stop(); try abort(err) }
                guard let raw else { break }
                bytesRead += raw.count

                while !writerInput.isReadyForMoreMediaData {
                    if writer.status == .failed { prefetch.stop(); try abort(writer.error) }
                    usleep(1000)
                }

                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
                guard let buffer = pb,
                      let tex = debayer.makeTexture(from: buffer, pixelFormat: codec.metalPixelFormat) else {
                    prefetch.stop(); try abort(PhantomError.protocolError("pixel buffer / texture allocation failed"))
                }
                do { try debayer.render(rawPacked: raw, params: params, into: tex) }
                catch { prefetch.stop(); try abort(error) }

                let pts = CMTime(value: frameDurValue * CMTimeValue(globalIndex), timescale: timescale)
                if !writerInput.append(sampleBuffer: buffer, presentationTime: pts) {
                    prefetch.stop(); try abort(writer.error ?? PhantomError.protocolError("frame append failed"))
                }
                globalIndex += 1

                let elapsed = max(Date().timeIntervalSince(t0), 0.001)
                let prog = Progress(fraction: Double(globalIndex) / Double(total),
                                    framesDone: globalIndex, totalFrames: total,
                                    fps: Double(globalIndex) / elapsed,
                                    mbPerSec: Double(bytesRead) / 1_048_576.0 / elapsed)
                if !progress(prog) { cancelled = true; prefetch.stop(); break outer }
            }
            prefetch.stop()
        }
        if cancelled { try abort(nil) }

        writerInput.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outURL)
            throw writer.error ?? PhantomError.protocolError("stitch failed to finish")
        }

        let seconds = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
        let hw = hardwareEncoder(for: codec)
        return Result(frames: total, seconds: seconds, fps: Double(total) / max(seconds, 0.001),
                      mbPerSec: Double(bytesRead) / 1_048_576.0 / max(seconds, 0.001),
                      outputBytes: size, hardwareEncoder: hw.available, encoderName: hw.name)
    }
}

// MARK: - append helper

private extension AVAssetWriterInput {
    /// Wraps a CVPixelBuffer into a CMSampleBuffer and appends it. Avoids the
    /// pixel-buffer adaptor so we can feed buffers from our own Metal pool.
    func append(sampleBuffer pixelBuffer: CVPixelBuffer, presentationTime pts: CMTime) -> Bool {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc) == noErr, let formatDesc else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: formatDesc, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else { return false }
        return append(sample)
    }
}

// MARK: - bounded background frame reader

/// Reads raw packed frames from disk on a background thread, a few ahead of
/// the consumer, so disk I/O overlaps GPU + encode. Preserves frame order.
private final class FramePrefetcher: @unchecked Sendable {
    private let reader: CineReader
    private let first: Int
    private let count: Int
    private let depth: Int
    private let cond = NSCondition()
    private var queue: [(Data?, Error?)] = []
    private var produced = 0
    private var stopped = false
    private let workQ = DispatchQueue(label: "cine.prefetch")

    init(reader: CineReader, first: Int, count: Int, depth: Int) {
        self.reader = reader; self.first = first; self.count = count; self.depth = depth
    }

    func start() {
        workQ.async { [self] in
            var i = 0
            while i < count {
                cond.lock()
                while queue.count >= depth && !stopped { cond.wait() }
                if stopped { cond.unlock(); return }
                cond.unlock()

                let item: (Data?, Error?)
                do { item = (try reader.readRawFrame(first + i), nil) }
                catch { item = (nil, error) }

                cond.lock()
                queue.append(item)
                cond.signal()
                cond.unlock()
                if item.1 != nil { return }   // stop on read error
                i += 1
            }
        }
    }

    /// Blocks for the next frame in order; returns nil once everything is
    /// consumed. The tuple's error is non-nil on a read failure.
    func next() -> (Data?, Error?)? {
        if produced >= count { return nil }
        cond.lock()
        while queue.isEmpty && !stopped { cond.wait() }
        if queue.isEmpty { cond.unlock(); return nil }
        let item = queue.removeFirst()
        cond.signal()
        cond.unlock()
        produced += 1
        return item
    }

    func stop() {
        cond.lock(); stopped = true; cond.broadcast(); cond.unlock()
    }
}
