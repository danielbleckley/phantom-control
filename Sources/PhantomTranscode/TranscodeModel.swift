import SwiftUI
import CoreGraphics
import Metal
import UniformTypeIdentifiers
import PhantomCore

/// Thread-safe cancel flag shared with the background worker.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func reset() { lock.lock(); value = false; lock.unlock() }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Renders downscaled preview frames for timeline scrubbing and playback,
/// through the SAME GPU debayer + grade path as the export (so the preview
/// matches the output exactly) — fast enough for real-time playback at 4K.
/// Caches one open reader + grade params per file; GPU-debayers the raw packed
/// frame into a small BGRA texture and reads it back as a CGImage. Falls back
/// to the CPU debayer if no Metal device is available. Runs on its own serial
/// queue; the view throttles scrubbing.
final class PreviewRenderer: @unchecked Sendable {
    private let q = DispatchQueue(label: "phantom.preview", qos: .userInteractive)
    private let debayer: MetalDebayer? = try? MetalDebayer()
    private var reader: CineReader?
    private var readerURL: URL?
    private var settings = Debayer16.RenderSettings()
    private var params: MetalDebayer.GradeParams?
    private var previewTex: MTLTexture?

    func render(url: URL, frame: Int, maxWidth: Int = 960,
                completion: @escaping @MainActor (Int, CGImage?) -> Void) {
        q.async {
            if self.readerURL != url {
                self.reader = try? CineReader(url: url)
                self.readerURL = url
                self.params = nil
                if let reader = self.reader {
                    var s = Debayer16.RenderSettings(info: reader.info)
                    let ref = min(reader.info.frameCount - 1, max(0, reader.info.frameCount / 3))
                    if let f = try? reader.readFrame(ref),
                       let wb = Debayer16.autoWhiteBalance(frame: f, cfa: reader.info.cfa,
                                                           blackLevel16: reader.info.blackLevel16) {
                        s.wbRed = wb.red; s.wbBlue = wb.blue
                    }
                    self.settings = s
                    self.params = MetalDebayer.params(info: reader.info, settings: s)
                }
            }
            guard let reader = self.reader else {
                Task { @MainActor in completion(frame, nil) }; return
            }
            let i = min(max(frame, 0), reader.info.frameCount - 1)
            let img = self.renderGPU(reader: reader, frame: i, maxWidth: maxWidth)
                ?? self.renderCPU(reader: reader, frame: i, maxWidth: maxWidth)
            Task { @MainActor in completion(frame, img) }
        }
    }

    /// GPU path: raw packed → Metal debayer/grade/scale → BGRA → CGImage.
    private func renderGPU(reader: CineReader, frame: Int, maxWidth: Int) -> CGImage? {
        guard let debayer, let params else { return nil }
        let info = reader.info
        guard let raw = try? reader.readRawFrame(frame) else { return nil }
        let pw = max(2, min(maxWidth, info.width) & ~1)
        let ph = max(2, Int((Double(pw) * Double(info.height) / Double(info.width)).rounded()) & ~1)
        if previewTex == nil || previewTex!.width != pw || previewTex!.height != ph {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: pw, height: ph, mipmapped: false)
            d.usage = [.shaderWrite, .shaderRead]
            d.storageMode = .shared
            previewTex = debayer.device.makeTexture(descriptor: d)
        }
        guard let tex = previewTex else { return nil }
        do { try debayer.render(rawPacked: raw, params: params, into: tex) } catch { return nil }
        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        bytes.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!, bytesPerRow: pw * 4,
                         from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        }
        return Debayer16.cgImage(bgra8: bytes, width: pw, height: ph)
    }

    /// CPU fallback (no Metal device).
    private func renderCPU(reader: CineReader, frame: Int, maxWidth: Int) -> CGImage? {
        guard let f = try? reader.readFrame(frame),
              let full = Debayer16.render(frame: f, cfa: reader.info.cfa, settings: settings)
        else { return nil }
        return Thumb.downscale(full, maxWidth: maxWidth)
    }
}

/// Structured outcome of one successful export — the data the PDF report draws.
struct ExportResult {
    var outputBytes: Int
    var fps: Double
    var hardware: Bool
    var encoderName: String
    var width: Int
    var height: Int
    var codecName: String
    var seconds: Double
    var framesWritten: Int
    var finishedAt: Date
}

/// One file in the batch queue — its own isolated per-file state (trim,
/// progress). Nothing is shared between jobs, so two files never bleed state.
@MainActor
final class TranscodeJob: ObservableObject, Identifiable {
    enum Status: Equatable {
        case loading, ready, running, done, failed(String), cancelled
        var label: String {
            switch self {
            case .loading: return "Reading…"
            case .ready: return "Ready"
            case .running: return "Transcoding…"
            case .done: return "Done"
            case .failed(let m): return "Failed: \(m)"
            case .cancelled: return "Cancelled"
            }
        }
    }

    let id = UUID()
    let url: URL

    @Published var status: Status = .loading
    @Published var info: CineFileInfo?
    @Published var thumbnail: CGImage?
    @Published var progress: Double = 0
    @Published var fps: Double = 0
    @Published var mbPerSec: Double = 0
    @Published var outputURL: URL?
    @Published var resultSummary: String?
    /// Structured result of the last successful export (feeds the PDF report).
    @Published var result: ExportResult?
    /// When the clip was shot — cine trigger timestamp, else file date. Used
    /// to order a stitched timeline by date.
    @Published var dateShot: Date?

    /// In/out trim, inclusive 0-based frame indices. outFrame defaults to last.
    @Published var inFrame: Int = 0
    @Published var outFrame: Int = 0

    init(url: URL) { self.url = url }

    var frameCount: Int { info?.frameCount ?? 0 }
    var trimmedCount: Int { max(0, min(outFrame, frameCount - 1) - max(inFrame, 0) + 1) }

    var isActive: Bool { status == .running || status == .loading }
    var canRun: Bool {
        switch status { case .ready, .failed, .cancelled: return info != nil; default: return false }
    }
}

@MainActor
final class TranscodeQueueModel: ObservableObject {
    @Published var jobs: [TranscodeJob] = []
    @Published var codec: GPUTranscoder.Codec = .proRes422HQ
    @Published var resolution: GPUTranscoder.Resolution = .full
    @Published var quality: GPUTranscoder.Quality = .balanced
    @Published var outputFolder: URL?            // nil → alongside each source file
    @Published var selection: TranscodeJob.ID?
    @Published var isRunning = false
    @Published var encoderNote: String = ""
    /// Stitched-timeline export status/progress (nil status = not stitching).
    @Published var stitchStatus: String?
    @Published var stitchProgress: Double = 0

    private let cancelFlag = CancelFlag()
    private let workQueue = DispatchQueue(label: "phantom.transcode.queue", qos: .userInitiated)
    let preview = PreviewRenderer()

    init() { refreshEncoderNote() }

    func refreshEncoderNote() {
        let hw = GPUTranscoder.hardwareEncoder(for: codec)
        encoderNote = hw.available ? "\(hw.name) · hardware" : "\(hw.name) · software"
    }

    var selectedJob: TranscodeJob? { jobs.first { $0.id == selection } }

    /// Output dimensions for a job under the current resolution preset.
    func outputDimensions(for job: TranscodeJob) -> (w: Int, h: Int)? {
        guard let info = job.info else { return nil }
        return GPUTranscoder.fitDimensions(srcW: info.width, srcH: info.height,
                                           targetHeight: resolution.targetHeight)
    }

    /// Estimated output size in bytes for a job under the current settings.
    func estimatedBytes(for job: TranscodeJob) -> Int? {
        guard let dims = outputDimensions(for: job) else { return nil }
        return GPUTranscoder.estimatedBytes(codec: codec, width: dims.w, height: dims.h,
                                            frames: job.trimmedCount, quality: quality)
    }

    // MARK: intake

    func addFiles(_ urls: [URL]) {
        let cineURLs = urls.filter { $0.pathExtension.lowercased() == "cine" }
        for url in cineURLs where !jobs.contains(where: { $0.url == url }) {
            let job = TranscodeJob(url: url)
            jobs.append(job)
            if selection == nil { selection = job.id }
            load(job)
        }
    }

    func remove(_ job: TranscodeJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
        if selection == job.id { selection = jobs.first?.id }
    }

    func clearFinished() {
        let finished = jobs.filter { if case .done = $0.status { return true }; return false }
        let ids = Set(finished.map { $0.id })
        jobs.removeAll { ids.contains($0.id) }
        if let sel = selection, ids.contains(sel) { selection = jobs.first?.id }
    }

    /// Opens the file, reads header, renders a preview thumbnail (off-main).
    private func load(_ job: TranscodeJob) {
        let url = job.url
        workQueue.async {
            do {
                let reader = try CineReader(url: url)
                let info = reader.info
                let idx = min(info.frameCount - 1, max(0, info.frameCount / 3))
                let frame = try reader.readFrame(idx)
                var settings = Debayer16.RenderSettings(info: info)
                if let wb = Debayer16.autoWhiteBalance(frame: frame, cfa: info.cfa,
                                                       blackLevel16: info.blackLevel16) {
                    settings.wbRed = wb.red; settings.wbBlue = wb.blue
                }
                let full = Debayer16.render(frame: frame, cfa: info.cfa, settings: settings)
                let thumb = full.flatMap { Thumb.downscale($0, maxWidth: 480) }
                // Date shot: prefer the cine trigger timestamp (epoch secs),
                // fall back to the file's creation date.
                let date: Date
                if info.triggerSecs > 946_684_800 {   // sane epoch (>= year 2000)
                    date = Date(timeIntervalSince1970: TimeInterval(info.triggerSecs))
                } else {
                    date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
                        .flatMap { $0 } ?? Date()
                }
                Task { @MainActor in
                    job.info = info
                    job.inFrame = 0
                    job.outFrame = info.frameCount - 1
                    job.thumbnail = thumb
                    job.dateShot = date
                    job.status = .ready
                }
            } catch {
                Task { @MainActor in job.status = .failed("\(error.localizedDescription)") }
            }
        }
    }

    // MARK: run queue

    /// Export every runnable job in the queue.
    func startAll() { start(jobs.filter { $0.canRun }) }

    /// Export only the currently selected job.
    func startSelected() { if let job = selectedJob { start([job]) } }

    /// Export a single job (used by the right-click menu).
    func export(_ job: TranscodeJob) { start([job]) }

    private func start(_ requested: [TranscodeJob]) {
        guard !isRunning else { return }
        let runnable = requested.filter { $0.canRun }
        guard !runnable.isEmpty else { return }
        isRunning = true
        cancelFlag.reset()

        let codec = self.codec
        let resolution = self.resolution
        let quality = self.quality
        let folder = self.outputFolder
        let plans = runnable.map { (job: $0, inF: max(0, $0.inFrame),
                                    outF: min($0.outFrame, $0.frameCount - 1)) }

        workQueue.async { [weak self] in
            guard let self else { return }
            for plan in plans {
                if self.cancelFlag.isCancelled { break }
                self.run(job: plan.job, inFrame: plan.inF, outFrame: plan.outF,
                         codec: codec, resolution: resolution, quality: quality, folder: folder)
            }
            Task { @MainActor in self.isRunning = false }
        }
    }

    func cancel() { cancelFlag.cancel() }

    // MARK: PDF report

    /// Whether a report can be produced (≥ 1 clip that finished exporting).
    var canReport: Bool {
        jobs.contains { if case .done = $0.status { return true }; return false }
    }

    /// Prompts for a location and writes a PDF transcode report covering every
    /// loaded clip (thumbnail, source specs, trim, output details, totals).
    func exportReport() {
        let entries: [ReportPDF.Entry] = jobs.compactMap { job in
            guard let info = job.info else { return nil }
            let statusText: String
            var ok = false
            switch job.status {
            case .done: statusText = "Exported"; ok = true
            case .failed(let m): statusText = "Failed: \(m)"
            case .cancelled: statusText = "Cancelled"
            default: statusText = "Not exported yet"
            }
            return ReportPDF.Entry(
                filename: job.url.lastPathComponent, thumbnail: job.thumbnail,
                sourceW: info.width, sourceH: info.height, sourceFrames: info.frameCount,
                bitDepth: info.realBPP, isColor: info.isColor, cameraModel: info.cameraModel,
                serial: info.serial, recordedFps: info.frameRate, dateShot: job.dateShot,
                inFrame: job.inFrame, outFrame: job.outFrame, framesUsed: job.trimmedCount,
                statusText: statusText, ok: ok,
                outputName: job.outputURL?.lastPathComponent, result: job.result)
        }
        guard !entries.isEmpty else { return }
        let settings = ReportPDF.Settings(
            codec: codec.rawValue, resolution: resolution.rawValue,
            quality: codec.isProRes ? "—" : quality.rawValue,
            outputFolder: outputFolder?.path ?? "Beside each source file")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Transcode Report.pdf"
        panel.message = "Save a PDF report of the transcode batch"
        panel.begin { resp in
            guard resp == .OK, let out = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = ReportPDF.generate(title: "Phantom Transcode — Transcode Report",
                                            settings: settings, entries: entries, to: out)
                Task { @MainActor in if ok { NSWorkspace.shared.activateFileViewerSelecting([out]) } }
            }
        }
    }

    // MARK: stitched timeline export

    /// Whether a stitched timeline can be exported (≥ 2 loaded clips).
    var canStitch: Bool { jobs.filter { $0.info != nil }.count >= 2 }

    /// Prompts for an output file, then exports all loaded clips as one
    /// back-to-back .mov ordered by filename or date shot.
    func exportStitched(byDate: Bool) {
        guard !isRunning else { return }
        let ready = jobs.filter { $0.info != nil }
        guard !ready.isEmpty else { return }
        let sorted = byDate
            ? ready.sorted { ($0.dateShot ?? .distantPast) < ($1.dateShot ?? .distantPast) }
            : ready.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "Timeline.mov"
        panel.message = "Export \(sorted.count) clips as one back-to-back timeline"
        panel.begin { resp in
            guard resp == .OK, let out = panel.url else { return }
            self.runStitch(sorted, to: out)
        }
    }

    private func runStitch(_ ordered: [TranscodeJob], to outURL: URL) {
        guard !isRunning else { return }
        isRunning = true
        stitchProgress = 0
        stitchStatus = "Stitching \(ordered.count) clips…"
        cancelFlag.reset()

        let codec = self.codec, resolution = self.resolution, quality = self.quality
        let inputs = ordered.map {
            GPUTranscoder.StitchInput(url: $0.url, firstFrame: max(0, $0.inFrame),
                                      lastFrame: min($0.outFrame, $0.frameCount - 1))
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                var lastUI = Date.distantPast
                let result = try GPUTranscoder.transcodeStitched(
                    inputs: inputs, to: outURL, codec: codec, fps: 0,
                    quality: quality, resolution: resolution) { p in
                    let now = Date()
                    if now.timeIntervalSince(lastUI) > 0.05 {
                        lastUI = now
                        Task { @MainActor in
                            self.stitchProgress = p.fraction
                            self.stitchStatus = String(format: "Stitching… %.0f%% · %.0f fps",
                                                       p.fraction * 100, p.fps)
                        }
                    }
                    return !self.cancelFlag.isCancelled
                }
                Task { @MainActor in
                    let size = Double(result.outputBytes) / 1_048_576.0
                    self.stitchProgress = 1
                    self.stitchStatus = String(format: "✓ Timeline: %d frames · %@ · %.0f MB",
                                               result.frames,
                                               result.hardwareEncoder ? "HW" : "SW", size)
                    self.isRunning = false
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                }
            } catch {
                let cancelled = self.cancelFlag.isCancelled
                Task { @MainActor in
                    self.stitchStatus = cancelled ? "Timeline cancelled"
                        : "Timeline failed: \(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }

    /// Runs one job synchronously on the worker queue.
    nonisolated private func run(job: TranscodeJob, inFrame: Int, outFrame: Int,
                                 codec: GPUTranscoder.Codec, resolution: GPUTranscoder.Resolution,
                                 quality: GPUTranscoder.Quality, folder: URL?) {
        let url = job.url
        Task { @MainActor in
            job.status = .running; job.progress = 0; job.fps = 0; job.mbPerSec = 0
        }
        do {
            let reader = try CineReader(url: url)
            let info = reader.info
            let first = max(0, min(inFrame, info.frameCount - 1))
            let last = max(first, min(outFrame, info.frameCount - 1))
            let frame0 = try reader.readFrame(first)
            var settings = Debayer16.RenderSettings(info: info)
            if let wb = Debayer16.autoWhiteBalance(frame: frame0, cfa: info.cfa,
                                                   blackLevel16: info.blackLevel16) {
                settings.wbRed = wb.red; settings.wbBlue = wb.blue
            }
            let options = GPUTranscoder.Options(codec: codec, fps: 0,
                                                firstFrame: first, lastFrame: last,
                                                settings: settings, resolution: resolution,
                                                quality: quality, info: info)
            let dir = folder ?? url.deletingLastPathComponent()
            let outURL = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("mov")

            var lastUI = Date.distantPast
            let result = try GPUTranscoder(reader: reader).transcode(to: outURL, options: options) { p in
                let now = Date()
                if now.timeIntervalSince(lastUI) > 0.05 {     // throttle UI to ~20 Hz
                    lastUI = now
                    Task { @MainActor in
                        job.progress = p.fraction; job.fps = p.fps; job.mbPerSec = p.mbPerSec
                    }
                }
                return !self.cancelFlag.isCancelled
            }
            let outW = min(options.outputWidth, info.width)
            let outH = min(options.outputHeight, info.height)
            Task { @MainActor in
                job.progress = 1
                job.outputURL = outURL
                job.resultSummary = String(format: "%.0f fps · %@ · %@",
                                           result.fps, formatBytes(result.outputBytes),
                                           result.hardwareEncoder ? "HW" : "SW")
                job.result = ExportResult(
                    outputBytes: result.outputBytes, fps: result.fps,
                    hardware: result.hardwareEncoder, encoderName: result.encoderName,
                    width: outW, height: outH, codecName: codec.rawValue,
                    seconds: result.seconds, framesWritten: result.frames,
                    finishedAt: Date())
                job.status = .done
            }
        } catch {
            let cancelled = self.cancelFlag.isCancelled
            Task { @MainActor in
                job.status = cancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - helpers

enum Thumb {
    /// Downscales a CGImage to `maxWidth` keeping aspect (for queue thumbnails).
    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(w)
        let nw = maxWidth, nh = max(1, Int(Double(h) * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}

/// Human-readable byte size (used for the estimated-size readout).
func formatBytes(_ bytes: Int) -> String {
    let b = Double(bytes)
    if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
    if b >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
    if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
    return "\(bytes) B"
}
