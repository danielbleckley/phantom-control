import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo

/// GPU port of the CineReader unpack + Debayer16 demosaic/grade pipeline.
///
/// Two compute passes on Apple-Silicon unified memory:
///   1. `unpack` — 10-bit packed (Rec.709-companded → 12-bit via cineLinLUT),
///      12-bit P12L, or raw16 → a single-channel 16-bit Bayer plane,
///      left-justified to 16 bits exactly like CineReader.
///   2. `demosaic` — bilinear GBRG (CFA 3) demosaic + black/white-level
///      normalization, per-channel white-balance gain and display gamma,
///      written straight into a CVPixelBuffer-backed Metal texture (no CPU
///      round-trip). Math mirrors Debayer16.makeLUTs / toneValue.
///
/// The shader is compiled from source at startup so the package needs no
/// prebuilt .metallib — keeps the hand-rolled .app bundle simple.
public final class MetalDebayer {

    /// Mirrors the Metal `GradeParams` struct (all 32-bit, 4-byte aligned).
    public struct GradeParams {
        var width: UInt32
        var height: UInt32
        var biCompression: UInt32   // 0 raw16, 256 packed10, 1024 packed12L
        var cfa: UInt32             // 0 mono, 3 GBRG
        var shift: UInt32           // raw16 left-justify shift (16 - realBPP)
        var black: Float
        var scale: Float            // 1 / (white - black)
        var gainR: Float
        var gainG: Float
        var gainB: Float
        var invGamma: Float
        var knee: Float             // highlight-rolloff knee (1.0 = hard clip)
    }

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let unpackPSO: MTLComputePipelineState
    private let demosaicPSO: MTLComputePipelineState
    private let lutBuffer: MTLBuffer
    public let textureCache: CVMetalTextureCache

    // Reused across frames; grown on demand.
    private var packedBuffer: MTLBuffer?
    private var bayerBuffer: MTLBuffer?
    // Full-resolution graded texture, used only when the output is downscaled.
    private var fullTexture: MTLTexture?
    private lazy var scaler = MPSImageLanczosScale(device: device)

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PhantomError.protocolError("no Metal device available")
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw PhantomError.protocolError("cannot create Metal command queue")
        }
        self.queue = queue

        let opts = MTLCompileOptions()
        // Fast math on: the grade's pow()/exp() run on the GPU's special-function
        // units, which are a big slice of the pass on Intel iGPUs and base-M
        // chips — full precision there can halve transcode fps. The precision
        // cost is under one code value in 8-bit output (sub-perceptual), so the
        // GPU develop still matches the CPU path to the eye.
        opts.fastMathEnabled = true
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: opts)
        } catch {
            throw PhantomError.protocolError("Metal shader compile failed: \(error)")
        }
        guard let unpackFn = library.makeFunction(name: "cine_unpack"),
              let demosaicFn = library.makeFunction(name: "cine_demosaic") else {
            throw PhantomError.protocolError("Metal kernels missing from library")
        }
        self.unpackPSO = try device.makeComputePipelineState(function: unpackFn)
        self.demosaicPSO = try device.makeComputePipelineState(function: demosaicFn)

        // cineLinLUT (1024 × UInt16) uploaded once.
        guard let lut = cineLinLUT.withUnsafeBytes({ raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }) else {
            throw PhantomError.protocolError("cannot upload cine LUT")
        }
        self.lutBuffer = lut

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw PhantomError.protocolError("cannot create Metal texture cache")
        }
        self.textureCache = cache
    }

    /// Wraps a CVPixelBuffer as a Metal texture (write target for the grade).
    public func makeTexture(from pixelBuffer: CVPixelBuffer,
                            pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            pixelFormat, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return tex
    }

    /// Builds grade params from a cine file + render settings (faithful to
    /// Debayer16.makeLUTs: gain = channel WB × overall gain, gamma applied).
    public static func params(info: CineFileInfo,
                              settings: Debayer16.RenderSettings) -> GradeParams {
        let black = Float(settings.blackLevel16)
        let white = Float(max(settings.whiteLevel16, settings.blackLevel16 + 1))
        let scale = 1.0 / (white - black)
        let invGamma = 1.0 / max(settings.gamma, 0.1)
        return GradeParams(
            width: UInt32(info.width), height: UInt32(info.height),
            biCompression: UInt32(info.biCompression), cfa: UInt32(info.cfa),
            shift: UInt32(max(0, 16 - info.realBPP)),
            black: black, scale: scale,
            gainR: settings.wbRed * settings.gain,
            gainG: settings.wbGreen * settings.gain,
            gainB: settings.wbBlue * settings.gain,
            invGamma: invGamma,
            knee: settings.highlightKnee)
    }

    /// Runs unpack + demosaic/grade for one frame into `outTexture`.
    /// `rawPacked` is the still-packed pixel bytes from CineReader.readRawFrame.
    /// Blocks until the GPU finishes so the pixel buffer is ready to encode.
    public func render(rawPacked: Data, params p: GradeParams,
                       into outTexture: MTLTexture) throws {
        let w = Int(p.width), h = Int(p.height)
        let n = w * h

        // Upload packed bytes (pad so per-pixel bit reads never run past the end).
        let needPacked = rawPacked.count + 8
        if packedBuffer == nil || packedBuffer!.length < needPacked {
            packedBuffer = device.makeBuffer(length: needPacked, options: .storageModeShared)
        }
        guard let packed = packedBuffer else {
            throw PhantomError.protocolError("cannot allocate packed GPU buffer")
        }
        _ = rawPacked.withUnsafeBytes { src in
            memcpy(packed.contents(), src.baseAddress!, rawPacked.count)
        }

        let needBayer = n * MemoryLayout<UInt16>.size
        if bayerBuffer == nil || bayerBuffer!.length < needBayer {
            bayerBuffer = device.makeBuffer(length: needBayer, options: .storageModePrivate)
        }
        guard let bayer = bayerBuffer else {
            throw PhantomError.protocolError("cannot allocate Bayer GPU buffer")
        }

        // When the output is smaller than the source, grade into a full-res
        // intermediate and Lanczos-downscale into the output (high quality);
        // otherwise grade straight into the output texture.
        let scaling = outTexture.width != w || outTexture.height != h
        let gradeTarget: MTLTexture
        if scaling {
            if fullTexture == nil || fullTexture!.width != w || fullTexture!.height != h
                || fullTexture!.pixelFormat != outTexture.pixelFormat {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: outTexture.pixelFormat, width: w, height: h, mipmapped: false)
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .private
                fullTexture = device.makeTexture(descriptor: desc)
            }
            guard let full = fullTexture else {
                throw PhantomError.protocolError("cannot allocate full-res GPU texture")
            }
            gradeTarget = full
        } else {
            gradeTarget = outTexture
        }

        guard let cmd = queue.makeCommandBuffer() else {
            throw PhantomError.protocolError("cannot create command buffer")
        }
        var params = p

        // Pass 1: unpack → Bayer plane.
        guard let enc1 = cmd.makeComputeCommandEncoder() else {
            throw PhantomError.protocolError("cannot create compute encoder")
        }
        enc1.setComputePipelineState(unpackPSO)
        enc1.setBuffer(packed, offset: 0, index: 0)
        enc1.setBuffer(lutBuffer, offset: 0, index: 1)
        enc1.setBuffer(bayer, offset: 0, index: 2)
        enc1.setBytes(&params, length: MemoryLayout<GradeParams>.stride, index: 3)
        dispatch(enc1, pso: unpackPSO, width: w, height: h)
        enc1.endEncoding()

        // Pass 2: demosaic + grade → full-res grade target.
        guard let enc2 = cmd.makeComputeCommandEncoder() else {
            throw PhantomError.protocolError("cannot create compute encoder")
        }
        enc2.setComputePipelineState(demosaicPSO)
        enc2.setBuffer(bayer, offset: 0, index: 0)
        enc2.setBytes(&params, length: MemoryLayout<GradeParams>.stride, index: 1)
        enc2.setTexture(gradeTarget, index: 0)
        dispatch(enc2, pso: demosaicPSO, width: w, height: h)
        enc2.endEncoding()

        // Pass 3 (only when downscaling): Lanczos scale → output texture.
        if scaling {
            scaler.encode(commandBuffer: cmd, sourceTexture: gradeTarget, destinationTexture: outTexture)
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error {
            throw PhantomError.protocolError("GPU render failed: \(err)")
        }
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, pso: MTLComputePipelineState,
                          width w: Int, height h: Int) {
        let tw = min(pso.threadExecutionWidth, 16)
        let th = max(1, min(pso.maxTotalThreadsPerThreadgroup / tw, 16))
        let tg = MTLSize(width: tw, height: th, depth: 1)
        let grid = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    }

    // MARK: - Metal shader source

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GradeParams {
        uint  width;
        uint  height;
        uint  biCompression;   // 0 raw16, 256 packed10, 1024 packed12L
        uint  cfa;             // 0 mono, 3 GBRG
        uint  shift;           // raw16 left-justify (16 - realBPP)
        float black;
        float scale;           // 1/(white-black)
        float gainR;
        float gainG;
        float gainB;
        float invGamma;
        float knee;            // highlight-rolloff knee (1.0 = hard clip)
    };

    // One thread per pixel: unpack a packed/raw bitstream to a 16-bit,
    // left-justified Bayer value — bit-identical to CineReader's CPU decoders.
    kernel void cine_unpack(device const uchar  *packed [[buffer(0)]],
                            device const ushort *lut    [[buffer(1)]],
                            device ushort       *bayer  [[buffer(2)]],
                            constant GradeParams &P      [[buffer(3)]],
                            uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= P.width || gid.y >= P.height) return;
        uint i = gid.y * P.width + gid.x;

        if (P.biCompression == 256u) {
            // 10-bit packed, MSB-first; companded → linear via LUT, then <<4.
            uint bitpos = i * 10u;
            uint bytePos = bitpos >> 3;
            uint bitIn = bitpos & 7u;
            uint acc = (uint(packed[bytePos]) << 16) |
                       (uint(packed[bytePos + 1]) << 8) |
                        uint(packed[bytePos + 2]);
            uint code = (acc >> (14u - bitIn)) & 0x3FFu;
            bayer[i] = ushort(uint(lut[code]) << 4);
        } else if (P.biCompression == 1024u) {
            // 12-bit packed (P12L), MSB-first, already linear; <<4.
            uint bitpos = i * 12u;
            uint bytePos = bitpos >> 3;
            uint bitIn = bitpos & 7u;
            uint acc = (uint(packed[bytePos]) << 16) |
                       (uint(packed[bytePos + 1]) << 8) |
                        uint(packed[bytePos + 2]);
            uint code = (acc >> (12u - bitIn)) & 0xFFFu;
            bayer[i] = ushort(code << 4);
        } else {
            // raw16: little-endian, bottom-up rows, right-justified → flip + <<shift.
            uint srcRow = P.height - 1u - gid.y;
            uint srcIdx = (srcRow * P.width + gid.x) * 2u;
            uint v = uint(packed[srcIdx]) | (uint(packed[srcIdx + 1]) << 8);
            bayer[i] = ushort((v << P.shift) & 0xFFFFu);
        }
    }

    static inline uint clampU(int v, uint hi) {
        return uint(clamp(v, 0, int(hi)));
    }

    // Normalized tone curve — mirrors Debayer16.toneValue.
    static inline float tone(uint raw, float gain, constant GradeParams &P) {
        float v = (float(raw) - P.black) * P.scale * gain;
        v = max(v, 0.0);
        v = pow(v, P.invGamma);
        // Highlight shoulder: roll values above the knee toward 1 smoothly.
        if (P.knee < 1.0 && v > P.knee) {
            float s = 1.0 - P.knee;
            v = P.knee + s * (1.0 - exp(-(v - P.knee) / s));
        }
        return min(v, 1.0);
    }

    kernel void cine_demosaic(device const ushort *bayer    [[buffer(0)]],
                              constant GradeParams &P        [[buffer(1)]],
                              texture2d<float, access::write> out [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]])
    {
        uint W = P.width, H = P.height;
        if (gid.x >= W || gid.y >= H) return;
        uint x = gid.x, y = gid.y;

        uint r, g, b;
        if (P.cfa == 0u) {
            uint v = bayer[y * W + x];
            r = v; g = v; b = v;
        } else {
            // Clamped neighbor rows/cols (edge replication), GBRG bilinear.
            uint xl = clampU(int(x) - 1, W - 1u);
            uint xr = clampU(int(x) + 1, W - 1u);
            uint yu = clampU(int(y) - 1, H - 1u);
            uint yd = clampU(int(y) + 1, H - 1u);
            uint rowC = y * W, rowU = yu * W, rowD = yd * W;
            uint cC = bayer[rowC + x];
            bool oddRow = (y & 1u) == 1u;
            bool oddCol = (x & 1u) == 1u;
            if (!oddRow) {
                if (!oddCol) {                 // G site, blue row
                    g = cC;
                    b = (uint(bayer[rowC + xl]) + bayer[rowC + xr]) >> 1;
                    r = (uint(bayer[rowU + x])  + bayer[rowD + x])  >> 1;
                } else {                       // B site
                    b = cC;
                    g = (uint(bayer[rowC + xl]) + bayer[rowC + xr] +
                         uint(bayer[rowU + x])  + bayer[rowD + x]) >> 2;
                    r = (uint(bayer[rowU + xl]) + bayer[rowU + xr] +
                         uint(bayer[rowD + xl]) + bayer[rowD + xr]) >> 2;
                }
            } else {
                if (!oddCol) {                 // R site
                    r = cC;
                    g = (uint(bayer[rowC + xl]) + bayer[rowC + xr] +
                         uint(bayer[rowU + x])  + bayer[rowD + x]) >> 2;
                    b = (uint(bayer[rowU + xl]) + bayer[rowU + xr] +
                         uint(bayer[rowD + xl]) + bayer[rowD + xr]) >> 2;
                } else {                       // G site, red row
                    g = cC;
                    r = (uint(bayer[rowC + xl]) + bayer[rowC + xr]) >> 1;
                    b = (uint(bayer[rowU + x])  + bayer[rowD + x])  >> 1;
                }
            }
        }

        float4 c = float4(tone(r, P.gainR, P),
                          tone(g, P.gainG, P),
                          tone(b, P.gainB, P),
                          1.0);
        out.write(c, gid);
    }
    """
}
