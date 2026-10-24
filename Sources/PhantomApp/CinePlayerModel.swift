import SwiftUI
import AVFoundation
import PhantomCore

/// Model for one open .cine file: decode, playback clock, and export.
@MainActor
final class CinePlayerModel: ObservableObject {
    @Published var image: CGImage?
    @Published var frameIndex = 0
    @Published var isPlaying = false
    @Published var loopPlayback = true
    @Published var playbackFPS: Double = 24
    @Published var statusLine = ""
    @Published var errorMessage: String?

    // Look controls (defaults seeded from the file when opened)
    @Published var wbRed: Float = 1.0
    @Published var wbBlue: Float = 1.0
    @Published var gain: Float = 1.0

    // Export
    @Published var exportProgress: Double?
    @Published var exportStatus = ""
    @Published var exportCodec: CineTranscoder.Codec = .proRes422HQ
    @Published var exportFPS: Double = 24

    private(set) var reader: CineReader?
    var info: CineFileInfo? { reader?.info }
    let url: URL

    private let decodeQueue = DispatchQueue(label: "cine.decode", qos: .userInteractive)
    private var playTimer: DispatchSourceTimer?
    private var decodeBusy = false
    private var pendingFrame: Int?
    private var exportCancelled = false

    init(url: URL) {
        self.url = url
        open()
    }

    private func open() {
        do {
            let reader = try CineReader(url: url)
            self.reader = reader
            let s = Debayer16.RenderSettings(info: reader.info)
            wbRed = s.wbRed; wbBlue = s.wbBlue
            playbackFPS = reader.info.playbackFPS
            exportFPS = reader.info.playbackFPS
            statusLine = "\(reader.info.width)×\(reader.info.height)  \(reader.info.frameCount) frames  recorded \(Int(reader.info.frameRate)) fps"
            showFrame(0)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private var settings: Debayer16.RenderSettings {
        guard let info else { return Debayer16.RenderSettings() }
        var s = Debayer16.RenderSettings(info: info)
        s.wbRed = wbRed; s.wbBlue = wbBlue; s.gain = gain
        return s
    }

    /// Decode + display a frame. Coalesces: if a decode is in flight the
    /// latest request wins (keeps scrubbing responsive on big frames).
    func showFrame(_ index: Int) {
        guard let reader else { return }
        let clamped = max(0, min(index, reader.info.frameCount - 1))
        frameIndex = clamped
        if decodeBusy { pendingFrame = clamped; return }
        decodeBusy = true
        let s = settings
        decodeQueue.async { [weak self] in
            let img: CGImage?
            do {
                let frame = try reader.readFrame(clamped)
                img = Debayer16.render(frame: frame, cfa: reader.info.cfa, settings: s)
            } catch {
                img = nil
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let img { self.image = img }
                self.decodeBusy = false
                if let next = self.pendingFrame, next != clamped {
                    self.pendingFrame = nil
                    self.showFrame(next)
                } else {
                    self.pendingFrame = nil
                }
            }
        }
    }

    func rerender() { showFrame(frameIndex) }

    func autoWhiteBalance() {
        guard let reader else { return }
        let idx = frameIndex
        decodeQueue.async { [weak self] in
            guard let frame = try? reader.readFrame(idx),
                  let wb = Debayer16.autoWhiteBalance(frame: frame, cfa: reader.info.cfa,
                                                      blackLevel16: reader.info.blackLevel16)
            else { return }
            Task { @MainActor [weak self] in
                self?.wbRed = wb.red
                self?.wbBlue = wb.blue
                self?.rerender()
            }
        }
    }

    // MARK: playback

    func play() {
        guard let reader, reader.info.frameCount > 1 else { return }
        stop()
        isPlaying = true
        let fps = max(min(playbackFPS, 120), 1)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let reader = self.reader else { return }
                var next = self.frameIndex + 1
                if next >= reader.info.frameCount {
                    if self.loopPlayback { next = 0 } else { self.stop(); return }
                }
                self.showFrame(next)
            }
        }
        timer.resume()
        playTimer = timer
    }

    func stop() {
        playTimer?.cancel()
        playTimer = nil
        isPlaying = false
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func step(_ delta: Int) {
        stop()
        showFrame(frameIndex + delta)
    }

    // MARK: export

    func export(to outURL: URL) {
        guard let reader else { return }
        exportCancelled = false
        exportProgress = 0
        exportStatus = "Exporting \(exportCodec.rawValue)…"
        let options = CineTranscoder.Options(codec: exportCodec, fps: exportFPS,
                                             settings: settings, info: reader.info)
        let total = reader.info.frameCount
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            do {
                try CineTranscoder(reader: reader).transcode(to: outURL, options: options) { p in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard let self else { return false }
                            self.exportProgress = p
                            let fps = Double(p) * Double(total) / max(Date().timeIntervalSince(t0), 0.001)
                            self.exportStatus = String(format: "Exporting… %d%%  (%.0f fps)", Int(p * 100), fps)
                            return !self.exportCancelled
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    self?.exportProgress = nil
                    self?.exportStatus = "Saved \(outURL.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.exportProgress = nil
                    self.exportStatus = self.exportCancelled ? "Export cancelled" : "Export failed: \(error)"
                }
            }
        }
    }

    func cancelExport() { exportCancelled = true }

    nonisolated func shutdown() {
        Task { @MainActor in
            self.stop()
            self.cancelExport()
        }
    }
}
