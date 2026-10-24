import SwiftUI
import Foundation
import AppKit
import PhantomCore

/// A second, independent device: a Phantom CineStation reached over its own
/// network port (typically the 10G fiber) — separate from the live camera. It
/// speaks the same control protocol, so it reuses `CameraModel.readMag` to browse
/// its CineMag. This runs ALONGSIDE the live camera; the camera keeps shooting on
/// its 1G link while the mag is browsed/pulled over 10G.
@MainActor
final class CineStationModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "cinestationHost") ?? "172.16.10.251" {
        didSet { UserDefaults.standard.set(host, forKey: "cinestationHost") }
    }
    @Published var connected = false
    @Published var connecting = false
    @Published var deviceName = ""
    @Published var boundInterface = ""
    @Published var linkSpeed = ""
    @Published var status = "Not connected"
    @Published var takes: [CameraModel.MagTake] = []
    @Published var magInfo = ""
    @Published var magUsed: Double = 0
    @Published var magSize: Double = 0
    @Published var loadingMag = false

    /// The main camera model — shared save folder/project, sidecar writer, and
    /// DIT-report generator, so CineStation pulls live in the same offload world.
    weak var cam: CameraModel?

    private var conn: CameraConnection?
    private let queue = DispatchQueue(label: "phantom.cinestation")

    /// Known CineStation addresses to auto-try: the 10G fiber XIP and the 1G
    /// control IP. The stored/typed host is tried first, then these — so it
    /// connects whether the CineStation is on fiber or the 1G adapter.
    static let knownHosts = ["172.16.10.251", "100.100.125.51"]

    // MARK: - Offload options (mirror the camera's Save-tab options)

    @Published var verifyDownloads = UserDefaults.standard.object(forKey: "csVerify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(verifyDownloads, forKey: "csVerify") }
    }
    @Published var makeProxy = UserDefaults.standard.object(forKey: "csProxy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(makeProxy, forKey: "csProxy") }
    }
    @Published var perClipPDF = UserDefaults.standard.object(forKey: "csClipPDF") as? Bool ?? true {
        didSet { UserDefaults.standard.set(perClipPDF, forKey: "csClipPDF") }
    }
    @Published var convertCodec: String = UserDefaults.standard.string(forKey: "csConvert") ?? "None" {
        didSet { UserDefaults.standard.set(convertCodec, forKey: "csConvert") }
    }
    /// "None" + the GPU transcoder's codecs (raw values double as display names).
    static let convertChoices = ["None"] + GPUTranscoder.Codec.allCases.map(\.rawValue)

    func connect() {
        guard !connecting, !connected else { return }
        var candidates = [host]
        for h in CineStationModel.knownHosts where !candidates.contains(h) { candidates.append(h) }
        connecting = true
        status = "Looking for a CineStation…"
        queue.async { [weak self] in
            for host in candidates {
                // Pin the connection to the interface on this host's subnet so its
                // traffic stays on the right NIC — important when both the camera
                // and CineStation share the 100.100 subnet on different adapters.
                let iface = CineStationModel.interface(forHost: host)
                let c = CameraConnection(host: host, boundInterface: iface)
                do {
                    try c.connect()
                    let info = try c.get("info")
                    let name = PhantomProtocol.find("name", in: info)?.stringValue ?? "CineStation"
                    let model = PhantomProtocol.find("model", in: info)?.stringValue ?? ""
                    let mag = try CameraModel.readMag(on: c)
                    Task { @MainActor in
                        guard let self else { return }
                        self.conn = c
                        self.connected = true
                        self.connecting = false
                        self.host = host
                        self.boundInterface = iface ?? "routing"
                        self.deviceName = model.isEmpty ? "CineStation \(name)" : "\(model) · \(name)"
                        self.status = "Connected"
                        self.apply(mag)
                    }
                    return
                } catch { c.close(); continue }
            }
            Task { @MainActor in
                guard let self else { return }
                self.connecting = false
                self.connected = false
                self.status = "No CineStation found (tried \(candidates.joined(separator: ", "))). Check its cable/IP."
            }
        }
    }

    func disconnect() {
        let c = conn; conn = nil
        connected = false
        deviceName = ""
        status = "Not connected"
        takes = []; magInfo = ""
        queue.async { c?.close() }
    }

    func refreshMag() {
        guard let c = conn, !loadingMag else { return }
        loadingMag = true
        queue.async { [weak self] in
            let mag = try? CameraModel.readMag(on: c)
            Task { @MainActor in
                guard let self else { return }
                self.loadingMag = false
                if let mag { self.apply(mag) }
            }
        }
    }

    private func apply(_ mag: (takes: [CameraModel.MagTake], info: String, used: Double, size: Double, debugFields: String)) {
        takes = mag.takes; magInfo = mag.info; magUsed = mag.used; magSize = mag.size
        fetchThumbnails()
    }

    // MARK: - Take thumbnails (mid-frame of each take via ximg fmt:flash)

    @Published var thumbs: [Int: CGImage] = [:]
    /// Thumbnail row height in points — Finder-style size slider (persisted).
    @Published var thumbHeight: Double = UserDefaults.standard.object(forKey: "csThumbHeight") as? Double ?? 45 {
        didSet { UserDefaults.standard.set(thumbHeight, forKey: "csThumbHeight") }
    }
    private var thumbFetchRunning = false

    /// Pulls the middle frame of every take that doesn't have a thumbnail yet
    /// (one ximg fmt:flash read each, ~5 MB — a couple of seconds for a full
    /// mag over the fiber), develops it, and caches a small poster. Runs on its
    /// own connection and yields immediately if a download or erase starts.
    func fetchThumbnails() {
        guard connected, !thumbFetchRunning, downloadingTake == nil, !erasing else { return }
        let missing = takes.filter { thumbs[$0.id] == nil && $0.width > 0 && $0.height > 0 }
        guard !missing.isEmpty else { return }
        thumbFetchRunning = true
        let host = self.host
        let iface = CineStationModel.interface(forHost: host)
        Thread.detachNewThread { [weak self] in
            func ui(_ b: @escaping @MainActor () -> Void) { Task { @MainActor in b() } }
            defer { ui { [weak self] in self?.thumbFetchRunning = false } }
            guard let nic = XimgReceiver.autodetect(cameraIP: host) else { return }
            let c = CameraConnection(host: host, boundInterface: iface)
            do {
                try c.connect()
                try c.startDataChannel()
                for take in missing {
                    // Downloads own the wire (and the BPF stream) — step aside.
                    if self == nil || self?.downloadingTake != nil || self?.erasing == true { break }
                    let mid = take.firstFrame + (take.lastFrame - take.firstFrame) / 2
                    guard let packed = try? c.grabFlashFrame(cine: take.id, frame: mid,
                                                             width: take.width, height: take.height,
                                                             nic: nic) else { continue }
                    let pixels = CineReader.unpackPacked10(packed, width: take.width, height: take.height)
                    let data16 = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
                    // Flex-verified SDI-ish develop: WB boost R/B over green + 2.2γ.
                    guard let full = Debayer.halfResBGRA16(
                        data: data16, width: take.width, height: take.height,
                        wb: .init(red: 2.0, green: 1.0, blue: 1.68),
                        gain: 1.0, blackLevel: 0.03, whiteLevel: 1.0,
                        contrast: 1.0, saturation: 1.0, gamma: 2.2) else { continue }
                    // 480px wide keeps the poster sharp even at the slider's
                    // biggest size on a retina display (36 takes ≈ 20 MB cached).
                    let small = MagOffload.rotateCW(CineStationModel.downscale(full, maxWidth: 480),
                                                    degrees: ExportRotation.current)
                    ui { [weak self] in self?.thumbs[take.id] = small }
                }
            } catch { }
            c.close()
        }
    }

    /// Cheap CG downscale so 36 cached thumbnails stay a few MB, not hundreds.
    nonisolated private static func downscale(_ img: CGImage, maxWidth: Int) -> CGImage {
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

    // MARK: - Download (ximg fmt:flash over 10G) + batch queue

    @Published var downloadingTake: Int?           // take id currently downloading
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var downloadedTakes: Set<Int> = []
    @Published var queuedTakes: [Int] = []         // pending take ids (Download All)
    @Published var batchTotal = 0                  // takes in the current batch
    @Published var clipPDFs: [Int: URL] = [:]      // take id → its per-clip PDF
    @Published var lastReportURL: URL?             // combined batch DIT report
    // Per-take trim range (trigger-relative frame numbers). Absent = whole take.
    @Published var trimIn: [Int: Int] = [:]
    @Published var trimOut: [Int: Int] = [:]
    private var cancelDownload = false
    private var batchActive = false

    func cancelActiveDownload() {
        cancelDownload = true
        queuedTakes = []
        batchActive = false
    }

    /// End-of-day: queue every not-yet-downloaded take, pull them one after
    /// another with the chosen options, then roll a combined DIT report.
    func downloadAll() {
        guard connected, downloadingTake == nil, !erasing else { return }
        let pending = takes.map(\.id).filter { !downloadedTakes.contains($0) }
        guard !pending.isEmpty else { return }
        queuedTakes = pending
        batchTotal = pending.count
        batchActive = true
        pumpQueue()
    }

    private func pumpQueue() {
        guard downloadingTake == nil else { return }
        guard !queuedTakes.isEmpty else {
            if batchActive {
                batchActive = false
                finishBatchReport()
            }
            fetchThumbnails()   // resume a thumbnail pass the download interrupted
            return
        }
        let next = queuedTakes.removeFirst()
        if let take = takes.first(where: { $0.id == next }) { download(take) } else { pumpQueue() }
    }

    /// After a Download All finishes: one combined DIT report (PDF + CSV) over
    /// everything in the project folder — camera clips and CineStation pulls.
    private func finishBatchReport() {
        guard let cam else { downloadStatus = "Batch complete."; return }
        downloadStatus = "Building DIT report…"
        let clips = cam.projectClips()
        guard !clips.isEmpty else { downloadStatus = "Batch complete."; return }
        cam.exportReport(clips) { [weak self] pdf in
            self?.lastReportURL = pdf
            self?.downloadStatus = "Batch complete — report: \(pdf.lastPathComponent)"
        }
    }

    /// Pulls one CineMag take to disk as a .cine over the 10G ximg fast path
    /// (`fmt:flash`), then runs the selected offload steps: verify (MD5 →
    /// .cine.md5 sidecar), poster thumbnail, GPU proxy (.mov), optional format
    /// conversion, metadata sidecars, and a per-clip PDF. Lands in the same
    /// project folder as camera downloads, so it shows in the Clips browser.
    func download(_ take: CameraModel.MagTake) {
        guard downloadingTake == nil, connected, !erasing else { return }
        let host = self.host
        let iface = CineStationModel.interface(forHost: host)
        let wantIn = trimIn[take.id], wantOut = trimOut[take.id]
        cancelDownload = false
        downloadingTake = take.id
        downloadProgress = 0
        downloadStatus = "Connecting…"
        let dest = CineStationModel.downloadDestination(for: take)
        let doVerify = verifyDownloads
        let doProxy = makeProxy
        let doPDF = perClipPDF
        let convertName = convertCodec
        Thread.detachNewThread { [weak self] in
            func ui(_ b: @escaping @MainActor () -> Void) { Task { @MainActor in b() } }
            let c = CameraConnection(host: host, boundInterface: iface)
            do {
                try c.connect()
                try c.startDataChannel()
                let fc = try c.get("fc\(take.id)")
                guard let res = PhantomProtocol.find("res", in: fc)?.sizeValue else {
                    throw PhantomError.protocolError("no res for take \(take.label)")
                }
                let fullFirst = PhantomProtocol.find("firstfr", in: fc)?.intValue ?? take.firstFrame
                let fullLast  = PhantomProtocol.find("lastfr", in: fc)?.intValue ?? take.lastFrame
                // Apply the trim (clamped to the take's real bounds) if one is set.
                let first = min(max(wantIn ?? fullFirst, fullFirst), fullLast)
                let last  = max(min(wantOut ?? fullLast, fullLast), first)
                _ = try c.command("set fc\(take.id).in:\(first)")
                _ = try c.command("set fc\(take.id).out:\(last)")
                guard let nic = XimgReceiver.autodetect(cameraIP: host) else {
                    throw PhantomError.protocolError("No 10G interface on the CineStation's subnet — the mag download needs the ximg fast path.")
                }
                // Identity + develop (serial, cfa, model, shot time) live in the
                // fcN take struct — the camera that shot it — not the CineStation.
                let meta = CineMetadata(
                    width: res.width, height: res.height,
                    frameRate: PhantomProtocol.find("rate", in: fc)?.intValue ?? 24,
                    exposureNs: PhantomProtocol.find("exp", in: fc)?.intValue ?? 0,
                    serial: PhantomProtocol.find("serial", in: fc)?.intValue ?? 0,
                    cfa: PhantomProtocol.find("cfa", in: fc)?.intValue ?? 3,
                    firstImageNo: first, totalFrames: last - first + 1, firstMovieImage: first,
                    triggerSecs: UInt32(truncatingIfNeeded: PhantomProtocol.find("secs", in: fc)?.intValue ?? 0),
                    triggerFrac: UInt32(truncatingIfNeeded: PhantomProtocol.find("frac", in: fc)?.intValue ?? 0),
                    cameraModel: PhantomProtocol.find("model", in: fc)?.stringValue ?? "Cinestation",
                    // The SHOOTING camera's hwver from the take struct — never the
                    // CineStation's own. 0 when absent, leaving CameraVersion unset
                    // rather than labelling the footage with the wrong body.
                    cameraVersion: PhantomProtocol.find("hwver", in: fc)?.intValue ?? 0,
                    cineName: dest.deletingPathExtension().lastPathComponent)
                let t0 = Date()
                try c.downloadCineXimg(cine: take.id, to: dest, meta: meta,
                                       firstFrame: first, lastFrame: last, nic: nic, flash: true,
                                       cancelled: { [weak self] in self?.cancelDownload ?? true }) { done, total in
                    let mbps = Double(done * res.width * res.height) * 1.25 / max(Date().timeIntervalSince(t0), 0.01) / 1e6
                    ui { [weak self] in
                        self?.downloadProgress = Double(done) / Double(max(total, 1))
                        self?.downloadStatus = String(format: "%@  %d/%d fr  %.0f MB/s", take.label, done, total, mbps)
                    }
                }
                c.close()

                // Verify BEFORE anything trusts the file.
                var vr = CineVerify.Result(ok: true, message: "not verified", md5: nil)
                if doVerify {
                    ui { [weak self] in self?.downloadProgress = 0; self?.downloadStatus = "Verifying \(take.label)…" }
                    vr = CineVerify.verify(url: dest, expectedFrames: last - first + 1) { p in
                        ui { [weak self] in self?.downloadProgress = p }
                    }
                    if let md5 = vr.md5 { CineVerify.writeChecksum(md5, for: dest) }
                }
                if vr.ok { ClipThumbnail.generate(for: dest) }

                // Post-steps on the verified file: GPU proxy + optional convert.
                if vr.ok, doProxy, !(self?.cancelDownload ?? true) {
                    let proxyURL = dest.deletingPathExtension().appendingPathExtension("mov")
                    try? Self.gpuTranscode(src: dest, to: proxyURL, codec: .h264,
                                           resolution: .hd1080, label: "Proxy") { [weak self] pct, fps in
                        ui { self?.downloadProgress = pct
                             self?.downloadStatus = String(format: "Proxy %@… %d%%  (%.0f fps)", take.label, Int(pct * 100), fps) }
                        return !(self?.cancelDownload ?? true)
                    }
                }
                if vr.ok, let codec = GPUTranscoder.Codec(rawValue: convertName), !(self?.cancelDownload ?? true) {
                    let suffix = convertName.replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: ".", with: "")
                    let outURL = dest.deletingPathExtension()
                        .appendingPathExtension("\(suffix).mov")
                    try? Self.gpuTranscode(src: dest, to: outURL, codec: codec,
                                           resolution: .full, label: convertName) { [weak self] pct, fps in
                        ui { self?.downloadProgress = pct
                             self?.downloadStatus = String(format: "%@ %@… %d%%  (%.0f fps)", convertName, take.label, Int(pct * 100), fps) }
                        return !(self?.cancelDownload ?? true)
                    }
                }

                ui { [weak self] in
                    guard let self else { return }
                    self.downloadingTake = nil
                    if vr.ok {
                        self.downloadedTakes.insert(take.id)
                        // Metadata sidecars (XML + MHL) so the clip carries full
                        // shoot metadata into the Clips browser and DIT report.
                        self.cam?.writeClipSidecars(url: dest, cine: meta, md5: vr.md5, first: first, last: last)
                        if doPDF { self.makeClipPDF(for: take, at: dest) }
                        let verifyTail = doVerify ? "  ✓ verified (md5 \(vr.md5?.prefix(8) ?? ""))" : ""
                        self.downloadStatus = "\(take.label) → \(dest.lastPathComponent)\(verifyTail)"
                    } else {
                        self.downloadStatus = "⚠️ \(take.label) verify FAILED: \(vr.message)"
                        NSSound.beep()
                    }
                    self.pumpQueue()
                }
            } catch {
                c.close()
                try? FileManager.default.removeItem(at: dest)
                ui { [weak self] in
                    guard let self else { return }
                    self.downloadingTake = nil
                    self.downloadStatus = "\(take.label) failed: \(error)"
                    if self.cancelDownload { self.queuedTakes = []; self.batchActive = false }
                    else { self.pumpQueue() }   // batch: keep going past one bad take
                }
            }
        }
    }

    /// GPU transcode helper for the offload post-steps (proxy / conversion).
    /// nonisolated: runs on the download thread, never touches model state.
    nonisolated private static func gpuTranscode(src: URL, to out: URL, codec: GPUTranscoder.Codec,
                                     resolution: GPUTranscoder.Resolution, label: String,
                                     progress: @escaping (Double, Double) -> Bool) throws {
        let reader = try CineReader(url: src)
        let opts = GPUTranscoder.Options(codec: codec, fps: reader.info.playbackFPS,
                                         resolution: resolution, quality: .balanced,
                                         info: reader.info)
        try GPUTranscoder(reader: reader).transcode(to: out, options: opts) { p in
            progress(p.fraction, p.fps)
        }
    }

    /// One-page DIT PDF for a single downloaded take, written beside the .cine.
    /// Fields come from the take itself (not a disk re-read of the sidecar —
    /// Dropbox-synced folders can lag on immediate re-reads), topped up with
    /// whatever the sidecar parse returns.
    private func makeClipPDF(for take: CameraModel.MagTake, at dest: URL) {
        let parsed = CameraModel.parseSidecar(dest.appendingPathExtension("xml"))
        var fields = parsed
        // Guarantee the report row's key fields even if the sidecar read missed.
        let have = Set(parsed.map(\.0))
        func add(_ k: String, _ v: String) { if !have.contains(k), !v.isEmpty { fields.append((k, v)) } }
        if take.width > 0 { add("Resolution", "\(take.width)×\(take.height)") }
        if take.fps > 0 { add("FrameRate", String(format: "%g fps", take.fps)) }
        if let angle = take.shutterAngle { add("ShutterAngle", String(format: "%.1f°", angle)) }
        add("Frames", "\(take.frames)")
        if take.durationSeconds > 0 { add("Duration", String(format: "%.2fs", take.durationSeconds)) }
        if let shot = take.shotDate { add("RecordedTime", ISO8601DateFormatter().string(from: shot)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int).flatMap { $0 } ?? 0
        let thumb = ClipThumbnail.url(for: dest)
        let md5 = (try? String(contentsOf: dest.appendingPathExtension("md5"), encoding: .utf8))?
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
        let entry = ClipEntry(
            url: dest, name: dest.lastPathComponent, sizeBytes: size,
            thumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil,
            fields: fields, md5: md5, date: Date())
        let pdf = dest.deletingPathExtension().appendingPathExtension("pdf")
        let project = cam?.projectName ?? ""
        Thread.detachNewThread { [weak self] in
            DITReport.exportPDF([entry], project: project, to: pdf)
            Task { @MainActor in self?.clipPDFs[take.id] = pdf }
        }
    }

    // MARK: - Erase (CineMag)

    @Published var erasing = false
    @Published var eraseStatus = ""
    /// Per-take delete needs a live protocol probe on a sacrificial mag before we
    /// expose it (CineMag flash is append-structured; PCC only offers whole-mag
    /// erase). Flipped on once the probe confirms a working command.
    @Published var supportsTakeDelete = false

    /// Whole-mag erase (`ferase` — the PCC mag-erase command). The take count
    /// zeroes immediately but the physical wipe keeps running: mag.state stays
    /// 8 (erasing) with mag.progress counting DOWN the blocks left, then state
    /// returns to 4 (ready). Verified live on the Flex (~1-2 min for 264 GB).
    func eraseMag() {
        guard let c = conn, !erasing, downloadingTake == nil else { return }
        erasing = true
        eraseStatus = "Erasing CineMag…"
        queue.async { [weak self] in
            do {
                _ = try c.command("ferase", timeout: 10.0)
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 1.0)
                    let state = PhantomProtocol.find("state", in: (try? c.get("mag.state")) ?? [:])?.intValue ?? -1
                    let left = PhantomProtocol.find("progress", in: (try? c.get("mag.progress")) ?? [:])?.intValue ?? -1
                    if left > 0 {
                        Task { @MainActor in self?.eraseStatus = "Erasing CineMag… \(left) blocks left" }
                    }
                    if state >= 0, state != 8, left <= 0 { break }
                }
                let mag = try? CameraModel.readMag(on: c)
                Task { @MainActor in
                    guard let self else { return }
                    self.erasing = false
                    self.eraseStatus = ""
                    self.downloadedTakes = []
                    self.clipPDFs = [:]
                    if let mag { self.apply(mag) }
                    self.downloadStatus = "CineMag erased."
                }
            } catch {
                Task { @MainActor in
                    self?.erasing = false
                    self?.eraseStatus = ""
                    self?.downloadStatus = "Erase failed: \(error)"
                }
            }
        }
    }

    // MARK: - Paths / interfaces

    /// `<saveFolder>/<project>/<name>.cine` — same place camera downloads land, so
    /// CineStation pulls also appear in the Clips browser / DIT report.
    static func downloadDestination(for take: CameraModel.MagTake) -> URL {
        let base = UserDefaults.standard.string(forKey: "saveFolder")
            ?? (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        var dir = URL(fileURLWithPath: base)
        let proj = (UserDefaults.standard.string(forKey: "projectName") ?? "").trimmingCharacters(in: .whitespaces)
        if !proj.isEmpty { dir.appendPathComponent(proj) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = take.name.isEmpty ? "CineStation_\(take.label)" : take.name.replacingOccurrences(of: "/", with: "-")
        var url = dir.appendingPathComponent(stem).appendingPathExtension("cine")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)_\(i)").appendingPathExtension("cine"); i += 1
        }
        return url
    }

    /// The folder downloads land in right now (for the "Saving to" bar).
    static func currentSaveFolder() -> URL {
        let base = UserDefaults.standard.string(forKey: "saveFolder")
            ?? (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        var dir = URL(fileURLWithPath: base)
        let proj = (UserDefaults.standard.string(forKey: "projectName") ?? "").trimmingCharacters(in: .whitespaces)
        if !proj.isEmpty { dir.appendPathComponent(proj) }
        return dir
    }

    // MARK: - Network setup (the 10G alias doesn't survive reboots)

    /// True when no Mac interface is on the CineStation's subnet — the state
    /// after every reboot, since the alias IP isn't persistent.
    var needsNetworkSetup: Bool {
        !connected && CineStationModel.interface(forHost: host) == nil
    }

    /// PCC-style one-click fix: put an address on the CineStation's subnet onto
    /// the free wired port (the 10G fiber adapter typically has NO IPv4 after a
    /// reboot — that's how we find it). Asks for the Mac password once.
    func setupNetwork() {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return }
        guard let iface = CineStationModel.setupCandidateInterface() else {
            status = "No free wired port found — is the CineStation's adapter plugged in?"
            return
        }
        let myIP = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3] == 1 ? 2 : 1)"
        let osa = "do shell script \"ifconfig \(iface) alias \(myIP) netmask 255.255.0.0\" " +
                  "with administrator privileges with prompt " +
                  "\"Phantom Control wants to add a network address (\(myIP)) on \(iface) " +
                  "so it can reach the CineStation at \(host).\""
        status = "Setting up \(iface) for \(host) — enter your Mac password…"
        queue.async { [weak self] in
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", osa]
            try? p.run(); p.waitUntilExit()
            let ok = p.terminationStatus == 0
            Thread.sleep(forTimeInterval: 1.5)   // let the interface settle
            Task { @MainActor in
                guard let self else { return }
                self.status = ok ? "Network configured — connecting…" : "Network setup cancelled"
                if ok { self.connect() }
            }
        }
    }

    /// An up-and-running en* interface with no usable IPv4 — a wired adapter
    /// waiting to be configured (e.g. the Sonnet fiber after a reboot).
    static func setupCandidateInterface() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var running = Set<String>(), hasIPv4 = Set<String>()
        var ptr = addrs
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let flags = Int32(bitPattern: UInt32(cur.pointee.ifa_flags))
            if (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 { running.insert(name) }
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                if !String(cString: buf).hasPrefix("169.254") { hasIPv4.insert(name) }
            }
        }
        // en0 is Wi-Fi/builtin — never alias that.
        return running.subtracting(hasIPv4).subtracting(["en0"]).sorted().first
    }

    /// The local en interface whose IPv4 shares a /16 with `host` (e.g. en24 at
    /// 172.16.10.1 for a CineStation at 172.16.10.251). nil → let routing decide.
    static func interface(forHost host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = "\(parts[0]).\(parts[1])."
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            if String(cString: buf).hasPrefix(prefix) { return name }
        }
        return nil
    }
}

/// The CineStation offload window — connect, browse the CineMag, and pull takes
/// with the full offload treatment (verify, proxy, convert, sidecars, reports).
/// Styled to match the main window's dark panels.
struct CineStationView: View {
    @EnvironmentObject var model: CineStationModel
    @EnvironmentObject var cam: CameraModel
    @ObservedObject private var theme = AppTheme.shared
    @State private var confirmErase = false
    @State private var eraseText = ""
    @State private var trimmingTake: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.needsNetworkSetup {
                HStack {
                    Button {
                        model.setupNetwork()
                    } label: {
                        Label("Set Up Network for \(model.host)",
                              systemImage: "network.badge.shield.half.filled")
                            .font(.caption)
                    }
                    .help("Adds an address on the CineStation's subnet to the free wired port (asks for your password once). Needed again after every Mac restart.")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            saveBar
            optionsBar
            actionBar
            Divider()
            if model.connected {
                if model.takes.isEmpty {
                    empty("No takes on this CineMag.")
                } else {
                    List(model.takes) { take in
                        VStack(spacing: 0) {
                            takeRow(take)
                            if trimmingTake == take.id { trimmer(take) }
                        }
                    }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                }
            } else {
                empty(model.connecting ? "Connecting…" : "Not connected — enter the CineStation's IP and Connect.")
            }
            footer
        }
        .background(theme.chrome(0.12))
        .themed()
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { if !model.connected { model.connect() } }   // auto-try on open
        .sheet(isPresented: $confirmErase) { eraseSheet }
    }

    // MARK: - Header (device + IP, like the camera tab)

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(model.connected ? Color.green : Color.gray).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.connected ? model.deviceName : "CineStation")
                    .font(.headline).lineLimit(1)
                if model.connected {
                    Text("\(model.host)  ·  via \(model.boundInterface)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.connected {
                TextField("172.16.x.x", text: $model.host)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
                    .disabled(model.connecting)
            }
            if model.connected {
                Button { model.refreshMag() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(model.loadingMag)
                .help("Re-read the CineMag")
                Button("Disconnect") { model.disconnect() }
            } else {
                Button(model.connecting ? "Connecting…" : "Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connecting)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.chrome(0.16))
    }

    // MARK: - Where clips land

    private var saveBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text("Saving to:")
                .font(.callout).foregroundStyle(.secondary)
            Text(savePathDisplay)
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head)
                .help(CineStationModel.currentSaveFolder().path)
            Spacer()
            Button("Choose…") { cam.chooseSaveFolder() }
                .font(.callout)
            Button {
                let dir = CineStationModel.currentSaveFolder()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open the save folder in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var savePathDisplay: String {
        let folder = URL(fileURLWithPath: cam.saveFolderPath).lastPathComponent
        let proj = cam.projectName.trimmingCharacters(in: .whitespaces)
        return proj.isEmpty ? folder : "\(folder) / \(proj)"
    }

    // MARK: - Offload options

    private var optionsBar: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $model.verifyDownloads) {
                Label("Verify (MD5)", systemImage: "checkmark.shield")
            }
            .help("Re-open each .cine after download, confirm the frame count, and hash it. Writes a .md5 sidecar.")
            Toggle(isOn: $model.makeProxy) {
                Label("Proxy (.mov)", systemImage: "film.stack")
            }
            .help("GPU-encode a 1080p H.264 viewing copy beside each .cine")
            Toggle(isOn: $model.perClipPDF) {
                Label("Clip PDF", systemImage: "doc.richtext")
            }
            .help("Write a one-page DIT report beside each downloaded clip")
            Spacer()
            Picker("Convert:", selection: $model.convertCodec) {
                ForEach(CineStationModel.convertChoices, id: \.self) { Text($0) }
            }
            .frame(width: 210)
            .help("Also convert each download to an editing format (GPU, full resolution)")
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Batch actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                model.downloadAll()
            } label: {
                Label(downloadAllLabel, systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
            .disabled(!model.connected || model.downloadingTake != nil || model.erasing
                      || model.takes.allSatisfy { model.downloadedTakes.contains($0.id) })

            if let pdf = model.lastReportURL {
                Button {
                    NSWorkspace.shared.open(pdf)
                } label: {
                    Label("Report", systemImage: "doc.richtext.fill")
                }
                .controlSize(.large)
                .help("Open the combined DIT report from the last Download All")
            }

            Button(role: .destructive) {
                eraseText = ""
                confirmErase = true
            } label: {
                Label("Erase Mag…", systemImage: "trash")
            }
            .controlSize(.large)
            .tint(.red)
            .disabled(!model.connected || model.erasing || model.downloadingTake != nil || model.takes.isEmpty)
            .help("Permanently erase the entire CineMag (all takes)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var downloadAllLabel: String {
        let remaining = model.takes.filter { !model.downloadedTakes.contains($0.id) }.count
        if !model.queuedTakes.isEmpty || (model.downloadingTake != nil && model.batchTotal > 0) {
            let done = model.batchTotal - model.queuedTakes.count - (model.downloadingTake != nil ? 1 : 0)
            return "Downloading… \(min(done + 1, model.batchTotal)) of \(model.batchTotal)"
        }
        if remaining == 0 && !model.takes.isEmpty { return "All takes downloaded ✓" }
        return "Download All (\(remaining) take\(remaining == 1 ? "" : "s"))"
    }

    // MARK: - Take rows

    private func takeRow(_ take: CameraModel.MagTake) -> some View {
        HStack(spacing: 10) {
            // Mid-frame poster, pulled live off the mag over the fiber.
            Group {
                if let t = model.thumbs[take.id] {
                    Image(t, scale: 1, label: Text(take.label))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(theme.viewerBackdrop(0.2))
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: model.thumbHeight * 1.6, height: model.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(take.label)
                .font(.caption.bold().monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.purple.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(take.detail).font(.callout)
                if !take.subline.isEmpty {
                    Text(take.subline).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let pdf = model.clipPDFs[take.id] {
                Button { NSWorkspace.shared.open(pdf) } label: {
                    Image(systemName: "doc.richtext")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open this clip's PDF report")
            }
            Button {
                trimmingTake = (trimmingTake == take.id) ? nil : take.id
            } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(.plain)
            .foregroundStyle(trimmingTake == take.id ? Color.accentColor : .secondary)
            .disabled(model.downloadingTake != nil || model.erasing)
            .help("Preview and trim this take before downloading")
            downloadControl(take)
        }
        .padding(.vertical, 2)
    }

    /// Inline preview + trim panel for one take (scrub, mark in/out, download).
    private func trimmer(_ take: CameraModel.MagTake) -> some View {
        let host = model.host
        let iface = CineStationModel.interface(forHost: host)
        let nic = XimgReceiver.autodetect(cameraIP: host)
        return TakeTrimmerView(
            take: take, host: host, iface: iface,
            grab: { conn, cine, frame, w, h in
                guard let nic else { throw PhantomError.protocolError("no 10G interface for preview") }
                return try conn.grabFlashFrame(cine: cine, frame: frame, width: w, height: h, nic: nic)
            },
            trimIn: Binding(get: { model.trimIn[take.id] ?? take.firstFrame },
                            set: { model.trimIn[take.id] = $0 }),
            trimOut: Binding(get: { model.trimOut[take.id] ?? take.lastFrame },
                             set: { model.trimOut[take.id] = $0 }),
            onDownloadTrimmed: { trimmingTake = nil; model.download(take) },
            onClose: { trimmingTake = nil })
        .padding(.vertical, 4)
    }

    /// Idle → down-arrow button; queued → clock; in-flight → progress ring;
    /// done → green check.
    @ViewBuilder
    private func downloadControl(_ take: CameraModel.MagTake) -> some View {
        if model.downloadingTake == take.id {
            HStack(spacing: 6) {
                ProgressView(value: model.downloadProgress).frame(width: 70)
                Button { model.cancelActiveDownload() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Cancel (also stops a running Download All)")
            }
        } else if model.queuedTakes.contains(take.id) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .help("Queued — will download next")
        } else if model.downloadedTakes.contains(take.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Downloaded and verified this session")
        } else {
            Button { model.download(take) } label: {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(model.downloadingTake != nil || model.erasing)
            .help("Download this take to \(savePathDisplay)")
        }
    }

    // MARK: - Footer / status

    @ViewBuilder
    private var footer: some View {
        if !model.downloadStatus.isEmpty || model.erasing || model.connected {
            Divider()
            HStack(spacing: 8) {
                if model.downloadingTake != nil || model.erasing {
                    ProgressView().controlSize(.small)
                }
                Text(model.erasing ? model.eraseStatus
                     : (model.downloadStatus.isEmpty ? model.magInfo : model.downloadStatus))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                // Finder-style thumbnail size slider.
                if model.connected && !model.takes.isEmpty {
                    Image(systemName: "photo")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Slider(value: $model.thumbHeight, in: 28...110)
                        .frame(width: 110)
                        .controlSize(.mini)
                        .help("Thumbnail size")
                    Image(systemName: "photo")
                        .font(.system(size: 14)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.chrome(0.16))
        }
    }

    // MARK: - Erase confirmation (type-to-confirm)

    private var eraseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Erase entire CineMag?", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundStyle(.red)
            Text("This permanently deletes ALL \(model.takes.count) takes on the CineMag in \(model.deviceName.isEmpty ? "the CineStation" : model.deviceName). There is no undo. Make sure every take is safely backed up first.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type ERASE to confirm", text: $eraseText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { confirmErase = false }
                    .keyboardShortcut(.cancelAction)
                Button("Erase CineMag", role: .destructive) {
                    confirmErase = false
                    model.eraseMag()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(eraseText != "ERASE")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
