import Foundation
import VideoToolbox
import CoreMedia

/// Low-latency H.264 encoder (VideoToolbox, hardware) for the LAN video feed —
/// turns SDI pixel buffers into AVCC NAL units + an avcC config the browser's
/// WebCodecs `VideoDecoder` can play. See STREAMING_PROJECT.md.
final class H264Encoder {
    /// The decoder config carried on every keyframe (codec string + avcC box).
    struct Config { let codec: String; let width: Int; let height: Int; let avcc: [UInt8] }

    /// Called from VideoToolbox's encode thread with one finished frame. `config`
    /// is non-nil on keyframes (so a freshly-connected client can configure).
    var onFrame: ((_ payload: [UInt8], _ keyframe: Bool, _ config: Config?) -> Void)?
    var bitrate = 4_000_000

    private var session: VTCompressionSession?
    private var w = 0, h = 0
    private var forceKey = false

    /// Make the next encoded frame a keyframe (called when a new client connects).
    func requestKeyframe() { forceKey = true }

    /// Change the target bitrate live (applies to the running session too).
    func setBitrate(_ bps: Int) {
        bitrate = max(500_000, bps)
        if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) }
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        if session == nil || pw != w || ph != h { setup(pw, ph) }
        guard let session else { return }
        var props: CFDictionary?
        if forceKey {
            forceKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.handle(sample)
        }
    }

    func stop() { teardown() }
    deinit { teardown() }

    // MARK: -

    private func setup(_ width: Int, _ height: Int) {
        teardown()
        w = width; h = height
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return }
        // Low-latency: real-time, no B-frames (no reorder), short GOP.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        forceKey = true   // first frame after (re)create must be a keyframe
    }

    private func teardown() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil; w = 0; h = 0
    }

    private func handle(_ sample: CMSampleBuffer) {
        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        var cfg: Config?
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sample) { cfg = makeConfig(fmt) }
        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let ptr, len > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: len)
        memcpy(&bytes, ptr, len)
        onFrame?(bytes, keyframe, cfg)
    }

    /// Builds the avcC config record + the WebCodecs codec string from the
    /// sample's SPS/PPS.
    private func makeConfig(_ fmt: CMFormatDescription) -> Config? {
        var spsPtr: UnsafePointer<UInt8>?; var spsLen = 0; var count = 0; var nalLen: Int32 = 0
        var ppsPtr: UnsafePointer<UInt8>?; var ppsLen = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
                parameterSetSizeOut: &spsLen, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLen) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
                parameterSetSizeOut: &ppsLen, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr,
              let spsPtr, let ppsPtr, spsLen >= 4 else { return nil }
        let sps = [UInt8](UnsafeBufferPointer(start: spsPtr, count: spsLen))
        let pps = [UInt8](UnsafeBufferPointer(start: ppsPtr, count: ppsLen))
        var avcc: [UInt8] = [0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1]
        avcc += [UInt8(spsLen >> 8), UInt8(spsLen & 0xFF)] + sps
        avcc += [0x01, UInt8(ppsLen >> 8), UInt8(ppsLen & 0xFF)] + pps
        let codec = String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
        return Config(codec: codec, width: w, height: h, avcc: avcc)
    }
}
