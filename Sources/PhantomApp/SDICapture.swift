import Foundation
import AVFoundation
import SwiftUI

/// Manages the USB-C SDI capture device (UltraStudio, Decklink-style UVC boxes, etc.)
/// as the primary monitor source.
final class SDICaptureManager: NSObject, ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String?
    @Published var isRunning = false
    @Published var authorized = false
    @Published var statusMessage = "SDI idle"

    /// Sample buffers actually delivered since the last start.
    ///
    /// `isRunning` only means the session OPENED — it is `true` for a session
    /// that is holding the capture hardware and delivering nothing, which is
    /// exactly what a Blackmagic box does when no input mode matches the wire.
    /// Everything user-facing must key off `isLive`, not `isRunning`, or the
    /// app claims "SDI live" over a black picture (and suppresses its own
    /// Ethernet-fallback banner) while locking every other app out of the card.
    @Published private(set) var framesReceived = 0

    /// True once real frames have arrived. THIS is "there is a picture".
    @Published private(set) var isLive = false

    /// What the driver is actually delivering, once the first frame lands
    /// (e.g. "1920×1080 2vuy"). Nil until then.
    @Published private(set) var activeFormatLabel: String?

    let session = AVCaptureSession()

    // MARK: Frame-arrival tracking

    private let frameLock = NSLock()
    private var rawFrameCount = 0
    private var lastPublishAt = Date.distantPast
    private var activeDeviceName = ""

    /// Called from `SDIProcessor`'s sample-buffer delegate on its own queue.
    /// Hot path: takes a lock, bumps a counter, and hops to main at most twice a
    /// second (plus once on the very first frame). No allocation, no string
    /// formatting per frame.
    func noteFrameArrived(width: Int, height: Int, pixelFormat: OSType) {
        frameLock.lock()
        rawFrameCount += 1
        let n = rawFrameCount
        let now = Date()
        let publish = (n == 1) || now.timeIntervalSince(lastPublishAt) > 0.5
        if publish { lastPublishAt = now }
        frameLock.unlock()
        guard publish else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framesReceived = n
            guard !self.isLive else { return }
            // First frame: the negotiation worked. Stand down the watchdog.
            self.watchdog?.cancel()
            self.watchdog = nil
            self.isLive = true
            let fourCC = Self.fourCCString(pixelFormat)
            let label = "\(width)×\(height) \(fourCC)"
            self.activeFormatLabel = label
            self.statusMessage = "SDI live: \(self.activeDeviceName) · \(label)"
            NSLog("[SDI] first frame from %@ — %@", self.activeDeviceName, label)
        }
    }

    private static func fourCCString(_ f: OSType) -> String {
        let bytes = [UInt8((f >> 24) & 0xff), UInt8((f >> 16) & 0xff),
                     UInt8((f >> 8) & 0xff), UInt8(f & 0xff)]
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(f)" : s
    }

    override init() {
        super.init()
        refreshDevices()
        // SDI capture boxes drop out when the camera changes video format
        // (resolution/log toggles) or USB hiccups — heal automatically.
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let msg = err?.localizedDescription ?? "unknown"
            // Log the FULL error — domain/code/userInfo is what actually
            // identifies a capture failure; localizedDescription alone is
            // usually a generic string that tells a remote tester nothing.
            NSLog("[SDI] runtime error: domain=%@ code=%ld userInfo=%@",
                  err?.domain ?? "?", err?.code ?? 0, String(describing: err?.userInfo ?? [:]))
            self?.statusMessage = "SDI error: \(msg) — restarting…"
            self?.scheduleRestart()
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRunning else { return }
            self.statusMessage = "Capture device reconnected — starting…"
            self.scheduleRestart()
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStopRunning, object: session, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRunning {
                // Stopped without us asking — signal break. Recover.
                self.isRunning = false
                self.statusMessage = "SDI signal dropped — restarting…"
                self.scheduleRestart()
            }
        }
    }

    private var restartPending = false

    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.restartPending = false
            self?.refreshDevices()
            // Go through the authorization gate, not straight to start(). The
            // direct start() let a user who had DENIED camera access reach a
            // running, device-holding, zero-frame session labelled "SDI live".
            // For an authorized user this takes the .authorized branch and
            // calls start() immediately, so behaviour is unchanged.
            self?.requestAccessAndStart()
        }
    }

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            start()
        case .notDetermined:
            statusMessage = "Asking for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorized = granted
                    if granted {
                        self?.start()
                    } else {
                        self?.statusMessage = "Permission denied — enable in System Settings → Privacy → Camera"
                    }
                }
            }
        default:
            authorized = false
            statusMessage = "Permission blocked — enable in System Settings → Privacy → Camera"
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func select(deviceID: String) {
        selectedDeviceID = deviceID
        requestAccessAndStart()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        // ONLY real wired USB capture boxes (AVMATRIX, UltraStudio, etc.).
        // Exclude the built-in webcam AND Continuity Camera — macOS lumps the
        // iPhone in with .external, so an isContinuityCamera check is required
        // to stop the app ever auto-grabbing the phone or the MacBook camera.
        devices = discovery.devices.filter {
            $0.deviceType == .external && !$0.isContinuityCamera
        }
        // Drop a stale selection if it's no longer a valid capture device.
        if let id = selectedDeviceID, !devices.contains(where: { $0.uniqueID == id }) {
            selectedDeviceID = nil
        }
        if selectedDeviceID == nil { selectedDeviceID = devices.first?.uniqueID }
    }

    func start() {
        refreshDevices()
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.uniqueID == id }) else {
            isRunning = false
            statusMessage = devices.isEmpty ? "No capture device found — check USB" : "No device selected"
            return
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                // Previously silent: the session would run with NO input and
                // report success. Never observed in the field, but it produces
                // the same black-picture symptom, so name it.
                session.commitConfiguration()
                isRunning = false
                statusMessage = "\(device.localizedName) could not be added as a capture input (in use by another app?)"
                NSLog("[SDI] canAddInput == false for %@", device.localizedName)
                return
            }
            // NOTE: sessionPreset is deliberately left alone. `.high` is
            // AVCaptureSession's default, so assigning it was a no-op, and
            // `.inputPriority` is unavailable on macOS. Format control on this
            // platform happens through device.activeFormat — see the watchdog.
        } catch {
            session.commitConfiguration()
            isRunning = false
            statusMessage = "Could not open \(device.localizedName): \(error.localizedDescription)"
            return
        }
        session.commitConfiguration()
        let name = device.localizedName
        activeDeviceName = name

        // Fresh negotiation attempt: reset frame accounting and the format walk.
        frameLock.lock(); rawFrameCount = 0; lastPublishAt = .distantPast; frameLock.unlock()
        framesReceived = 0
        isLive = false
        activeFormatLabel = nil
        watchdog?.cancel(); watchdog = nil
        formatCandidates = []
        formatAttempt = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                let running = self.session.isRunning
                self.isRunning = running
                // NOT "live" — the session is merely open. Frames decide that.
                self.statusMessage = running
                    ? "SDI opened — waiting for frames from \(name)…"
                    : "Failed to start \(name)"
                if running {
                    NSLog("[SDI] session started on %@ — awaiting frames", name)
                    self.armWatchdog(for: device)
                } else {
                    NSLog("[SDI] session failed to start on %@", name)
                }
            }
        }
    }

    // MARK: - Frame watchdog + format negotiation
    //
    // The app performs no format negotiation of its own: it adds the device
    // input and trusts AVFoundation's default. A UVC box (AVMATRIX, Atomos
    // Connect/Ninja, AtomX Cast) self-converts whatever SDI it detects into one
    // fixed USB stream, so the default always works. A Blackmagic CoreMediaIO
    // device instead exposes DISCRETE raw input modes — if none of them matches
    // the signal on the wire (a 50 Hz European feed being the obvious case), the
    // session opens, holds the card, and delivers nothing forever.
    //
    // This walk only ever runs when ZERO frames have arrived, so it is
    // unreachable on any device that already works. That is what makes it safe
    // to ship without the hardware to test it on.

    private var watchdog: DispatchWorkItem?
    private var formatCandidates: [AVCaptureDevice.Format] = []
    private var formatAttempt = 0
    private let maxFormatAttempts = 8

    private func armWatchdog(for device: AVCaptureDevice, seconds: Double = 3.0) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.framesReceived == 0 else { return }
            self.tryNextFormat(on: device)
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func tryNextFormat(on device: AVCaptureDevice) {
        if formatCandidates.isEmpty {
            // Build the candidate list once, on the first timeout. 1920×1080
            // first (overwhelmingly the likely SDI feed), then largest first.
            formatCandidates = device.formats.sorted { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let aHD = (da.width == 1920 && da.height == 1080)
                let bHD = (db.width == 1920 && db.height == 1080)
                if aHD != bHD { return aHD }
                return Int(da.width) * Int(da.height) > Int(db.width) * Int(db.height)
            }
            NSLog("[SDI] no frames after 3s on %@ — %d formats offered, walking up to %d",
                  device.localizedName, formatCandidates.count, maxFormatAttempts)
            for (i, f) in formatCandidates.prefix(maxFormatAttempts).enumerated() {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let r = f.videoSupportedFrameRateRanges
                    .map { String(format: "%.2f–%.2f", $0.minFrameRate, $0.maxFrameRate) }
                    .joined(separator: ",")
                NSLog("[SDI]   [%d] %dx%d %@ rates=%@", i, d.width, d.height,
                      Self.fourCCString(CMFormatDescriptionGetMediaSubType(f.formatDescription)), r)
            }
        }

        let limit = min(formatCandidates.count, maxFormatAttempts)
        guard formatAttempt < limit else {
            // Exhausted every candidate. Say so plainly AND release the card —
            // holding a device we can't read from is what locked Media Express
            // out until the app was quit.
            statusMessage = "No video from \(activeDeviceName) after trying \(limit) format\(limit == 1 ? "" : "s"). Check the camera's SDI output format. Device released."
            NSLog("[SDI] format walk exhausted after %d attempts — releasing device", limit)
            stop()
            return
        }

        let fmt = formatCandidates[formatAttempt]
        formatAttempt += 1
        let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let rates = fmt.videoSupportedFrameRateRanges
            .map { String(format: "%.0f", $0.maxFrameRate) }
            .joined(separator: "/")
        do {
            try device.lockForConfiguration()
            device.activeFormat = fmt
            device.unlockForConfiguration()
            statusMessage = "No frames yet — trying \(d.width)×\(d.height) @ \(rates) (\(formatAttempt)/\(limit))…"
            NSLog("[SDI] attempt %d/%d: set activeFormat %dx%d rates=%@",
                  formatAttempt, limit, d.width, d.height, rates)
        } catch {
            NSLog("[SDI] lockForConfiguration failed on attempt %d: %@",
                  formatAttempt, String(describing: error))
            statusMessage = "Could not set capture format on \(activeDeviceName): \(error.localizedDescription)"
        }
        armWatchdog(for: device)
    }

    /// Stops the session and RELEASES the capture hardware so other apps
    /// (Blackmagic Media Express, Desktop Video Setup) can open it.
    ///
    /// Ordering matters: `isRunning` must be cleared BEFORE `stopRunning()`.
    /// The `DidStopRunning` observer treats `isRunning == true` as "stopped
    /// without us asking" and schedules a restart 1.5 s later — so clearing the
    /// flag afterwards made the app re-claim the very card it had just let go.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        isRunning = false
        isLive = false
        framesReceived = 0
        frameLock.lock(); rawFrameCount = 0; frameLock.unlock()
        statusMessage = "SDI stopped — capture device released"
        NSLog("[SDI] stop() — releasing capture device")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                // Drop the input too: stopRunning alone can keep the device claimed.
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.commitConfiguration()
            }
        }
    }

    /// Full teardown + clean rebuild — the reliable fix when the AVMATRIX feed
    /// goes hit-and-miss (USB hiccup, signal-format change, or a stale session
    /// after the permission grant cached). Stops, drops inputs, re-enumerates,
    /// then restarts after the device settles.
    func forceReconnect() {
        statusMessage = "Reconnecting SDI…"
        // Clear the flag FIRST — otherwise stopRunning() below trips the
        // DidStopRunning observer while isRunning is still true, which queues a
        // second, competing restart on top of the one this function schedules.
        watchdog?.cancel()
        watchdog = nil
        isRunning = false
        isLive = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async {
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.commitConfiguration()
                self.isRunning = false
                // Let the USB device re-enumerate before re-opening it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.selectedDeviceID = nil          // force a fresh pick
                    self.refreshDevices()
                    self.requestAccessAndStart()
                }
            }
        }
    }

    // MARK: - Proxy recording (records the SDI feed to a .mov)

    private let movieOutput = AVCaptureMovieFileOutput()
    @Published var isProxyRecording = false
    /// Fires once the recorder is ACTUALLY capturing (delegate didStart) — so the
    /// caller can roll playback only then and not miss the first frames.
    private var onProxyStarted: (() -> Void)?

    func startProxyRecording(to url: URL, onStarted: (() -> Void)? = nil) {
        guard isRunning else { onStarted?(); return }
        onProxyStarted = onStarted
        if !session.outputs.contains(movieOutput) {
            session.beginConfiguration()
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
        }
        try? FileManager.default.removeItem(at: url)
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isProxyRecording = true
    }

    func stopProxyRecording() {
        guard isProxyRecording else { return }
        movieOutput.stopRecording()
    }
}

extension SDICaptureManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { [weak self] in
            self?.onProxyStarted?()
            self?.onProxyStarted = nil
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isProxyRecording = false
            self?.statusMessage = error == nil
                ? "Proxy saved: \(outputFileURL.lastPathComponent)"
                : "Proxy failed: \(error!.localizedDescription)"
        }
    }
}

/// AVCaptureVideoPreviewLayer wrapped for SwiftUI.
struct SDIPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .black
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
