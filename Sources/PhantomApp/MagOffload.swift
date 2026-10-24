import Foundation
import AppKit
import CoreImage
import PhantomCore

/// Shared offload helpers used by BOTH mag browsers — the CineStation window
/// (10G ximg) and the camera's Manage CineMag sheet (TCP img flash). They differ
/// only in how packed-10 pixels arrive; everything downstream (develop a thumbnail,
/// GPU proxy/convert, downscale) is identical, so it lives here once.
enum MagOffload {
    /// Develops a raw packed-10 flash frame into a small poster thumbnail.
    /// Fixed Flex-ish develop (WB boost R/B over green + 2.2γ) — good enough to
    /// tell takes apart; the graded look comes from the downloaded .cine.
    nonisolated static func developThumbnail(packed10: Data, width: Int, height: Int,
                                             maxWidth: Int = 480) -> CGImage? {
        guard width >= 2, height >= 2 else { return nil }
        let pixels = CineReader.unpackPacked10(packed10, width: width, height: height)
        let data16 = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let full = Debayer.halfResBGRA16(
            data: data16, width: width, height: height,
            wb: .init(red: 2.0, green: 1.0, blue: 1.68),
            gain: 1.0, blackLevel: 0.03, whiteLevel: 1.0,
            contrast: 1.0, saturation: 1.0, gamma: 2.2) else { return nil }
        return rotateCW(downscale(full, maxWidth: maxWidth), degrees: ExportRotation.current)
    }

    /// Rotate a CGImage clockwise by 0/90/180/270°, using the SAME transform the
    /// live viewer uses (CIImage, −degrees), so a baked thumbnail matches the
    /// rotated feed and exports. Vertical mode.
    private static let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated static func rotateCW(_ img: CGImage, degrees: Int) -> CGImage {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0 else { return img }
        let ci = CIImage(cgImage: img)
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(-d) * .pi / 180))
        let anchored = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                            y: -ci.extent.origin.y))
        return ciCtx.createCGImage(anchored, from: anchored.extent) ?? img
    }

    /// Cheap CG downscale so a full mag of cached thumbnails stays a few MB.
    nonisolated static func downscale(_ img: CGImage, maxWidth: Int) -> CGImage {
        guard img.width > maxWidth else { return img }
        let w = maxWidth
        let h = max(1, img.height * maxWidth / img.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// GPU transcode a downloaded .cine → .mov (proxy or delivery format).
    nonisolated static func gpuTranscode(src: URL, to out: URL, codec: GPUTranscoder.Codec,
                                         resolution: GPUTranscoder.Resolution,
                                         progress: @escaping (Double, Double) -> Bool) throws {
        let reader = try CineReader(url: src)
        // Neutral, gradeable Rec.709 delivery look (matches how DaVinci decodes
        // a Phantom cine): clean blacks, rolled-off highlights, properly tagged
        // — so proxies/exports edit and grade like PCC/Resolve.
        let opts = GPUTranscoder.Options(codec: codec, fps: reader.info.playbackFPS,
                                         settings: .neutralRec709(info: reader.info),
                                         resolution: resolution, quality: .balanced,
                                         info: reader.info)
        try GPUTranscoder(reader: reader).transcode(to: out, options: opts) { p in
            progress(p.fraction, p.fps)
        }
    }

    /// "None" + the GPU transcoder's codecs (raw values double as display names).
    static let convertChoices = ["None"] + GPUTranscoder.Codec.allCases.map(\.rawValue)
}
