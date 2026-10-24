import Foundation
import AVFoundation
import CoreVideo

/// Transcodes a .cine file to a QuickTime .mov via AVAssetWriter/VideoToolbox.
/// ProRes is fed 16-bit ARGB frames (full grading latitude); H.264 gets BGRA8.
public final class CineTranscoder {

    public enum Codec: String, CaseIterable, Sendable {
        case proRes422HQ = "ProRes 422 HQ"
        case proRes422 = "ProRes 422"
        case proRes422LT = "ProRes 422 LT"
        case h264 = "H.264"

        var avCodec: AVVideoCodecType {
            switch self {
            case .proRes422HQ: return .proRes422HQ
            case .proRes422: return .proRes422
            case .proRes422LT: return .proRes422LT
            case .h264: return .h264
            }
        }
        var pixelFormat: OSType {
            self == .h264 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64ARGB
        }
    }

    public struct Options {
        public var codec: Codec
        public var fps: Double            // output timebase (e.g. 24)
        public var firstFrame: Int        // 0-based, inclusive
        public var lastFrame: Int         // 0-based, inclusive
        public var settings: Debayer16.RenderSettings

        public init(codec: Codec = .proRes422HQ, fps: Double = 0,
                    firstFrame: Int = 0, lastFrame: Int = .max,
                    settings: Debayer16.RenderSettings? = nil, info: CineFileInfo) {
            self.codec = codec
            self.fps = fps > 0 ? fps : (info.playbackFPS > 0 ? info.playbackFPS : 24)
            self.firstFrame = max(0, firstFrame)
            self.lastFrame = min(lastFrame, info.frameCount - 1)
            self.settings = settings ?? Debayer16.RenderSettings(info: info)
        }
    }

    private let reader: CineReader

    public init(reader: CineReader) {
        self.reader = reader
    }

    /// Runs the transcode synchronously (call from a background queue).
    /// `progress` is called with 0…1; return false to cancel — the partial
    /// output file is deleted on cancel or error.
    public func transcode(to outURL: URL, options: Options,
                          progress: (Double) -> Bool = { _ in true }) throws {
        let info = reader.info
        let w = info.width, h = info.height
        let first = options.firstFrame
        let last = max(options.lastFrame, first)
        let total = last - first + 1

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        if options.codec == .h264 {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: min(60_000_000, w * h * 8),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(options.fps.rounded()),
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: options.codec.pixelFormat,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else {
            throw PhantomError.protocolError("cannot configure \(options.codec.rawValue) writer")
        }
        writer.add(input)
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
        let frameDuration = CMTime(value: CMTimeValue((Double(timescale) / options.fps).rounded()), timescale: timescale)

        for i in 0..<total {
            if !progress(Double(i) / Double(total)) { try abort(nil) }

            let frame: CineFrame16
            let rgb: [UInt16]
            do {
                frame = try reader.readFrame(first + i)
                rgb = Debayer16.demosaicRGB48(frame: frame, cfa: info.cfa)
            } catch { try abort(error) }

            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { try abort(writer.error) }
                usleep(2000)
            }

            guard let pool = adaptor.pixelBufferPool else { try abort(writer.error) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
            guard let buffer = pb else {
                try abort(PhantomError.protocolError("pixel buffer allocation failed"))
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            if options.codec.pixelFormat == kCVPixelFormatType_64ARGB {
                Debayer16.writeARGB16BE(rgb48: rgb, width: w, height: h,
                                        settings: options.settings, to: base, bytesPerRow: bpr)
            } else {
                Debayer16.writeBGRA8(rgb48: rgb, width: w, height: h,
                                     settings: options.settings, to: base, bytesPerRow: bpr)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let pts = CMTime(value: frameDuration.value * CMTimeValue(i), timescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                try abort(writer.error ?? PhantomError.protocolError("frame append failed at \(i)"))
            }
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outURL)
            throw writer.error ?? PhantomError.protocolError("transcode failed to finish")
        }
        _ = progress(1.0)
    }
}
