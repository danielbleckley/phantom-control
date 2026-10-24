import Foundation
import SwiftUI
import AppKit
import AVFoundation
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PhantomCore
import LANVideoStream

struct CineSlot: Identifiable {
    enum State { case live, empty, ready, waitTrigger, postTrigger, stored }
    let id: Int          // cine index (0 = live)
    var flags: [String]
    var frameCount: Int = 0
    var firstFrame: Int = 0
    var lastFrame: Int = 0

    var state: State {
        if id == 0 { return .live }
        if flags.contains("INV") { return .empty }
        if flags.contains("STR") { return .stored }
        if flags.contains("WTR") { return .waitTrigger }
        if flags.contains("TRG") { return .postTrigger }
        if flags.contains("RDY") { return .ready }
        return .empty
    }

    var color: Color {
        switch state {
        case .live: return .cyan
        case .empty: return Color(white: 0.35)
        case .ready: return .blue
        case .waitTrigger: return .red
        case .postTrigger: return .orange
        case .stored: return .green
        }
    }

    var label: String { id == 0 ? "LIVE" : "C\(id)" }
}

/// Production metadata entered by the user (Capture One-style tethering fields),
/// embedded into each downloaded clip's sidecar. Persists across clips/sessions.
struct ShootMetadata: Codable, Equatable {
    var client = ""
    var job = ""
    var production = ""
    var director = ""
    var dp = ""
    var cameraOp = ""
    var lens = ""
    var focalLength = ""
    var aperture = ""        // T-stop / f-stop
    var ndFilter = ""
    var scene = ""
    var take = ""
    var notes = ""

    /// User fields as (label, value) pairs — only the non-empty ones.
    var pairs: [(String, String)] {
        [("Client", client), ("Job", job), ("Production", production),
         ("Director", director), ("DP", dp), ("CameraOperator", cameraOp),
         ("Lens", lens), ("FocalLength", focalLength), ("Aperture", aperture),
         ("NDFilter", ndFilter), ("Scene", scene), ("Take", take), ("Notes", notes)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// A downloaded clip in the project folder, for the clip browser / DIT report.
struct ClipEntry: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let sizeBytes: Int
    let thumb: URL?
    let fields: [(String, String)]   // parsed from the .cine.xml sidecar, in order
    let md5: String?
    var date: Date = .distantPast    // file creation date, for sorting
    var lookup: [String: String] { Dictionary(fields, uniquingKeysWith: { a, _ in a }) }
    var sizeGB: Double { Double(sizeBytes) / 1_000_000_000 }
    /// Sibling SDI-proxy .mov (written next to the .cine on download). It's small,
    /// hardware-decodable, and carries the camera's baked-in color — so it plays
    /// back smooth and graded, unlike the raw .cine.
    var proxyURL: URL? {
        let mov = url.deletingPathExtension().appendingPathExtension("mov")
        return FileManager.default.fileExists(atPath: mov.path) ? mov : nil
    }
}

/// One configurable frame guide (aspect box) drawn over the picture.
struct FrameGuide: Identifiable, Equatable, Codable {
    var id = UUID()
    var enabled = true
    var ratioName = "16:9"
    var customRatio: Double = 1.78
    var scale: Double = 1.0           // fraction of the largest box at this ratio
    var offsetX: Double = 0           // −0.5…0.5, fraction of frame width
    var offsetY: Double = 0
    var colorName = "white"
    var lineOpacity: Double = 0.9
    var dimOutside: Double = 0        // 0…1, dim the area outside this box

    var ratio: Double {
        if ratioName == "Custom" { return max(0.2, customRatio) }
        return CameraModel.frameGuidePresets.first { $0.name == ratioName }?.ratio ?? 16.0 / 9.0
    }
    var color: Color {
        CameraModel.gridColors.first { $0.0 == colorName }?.1 ?? .white
    }
    /// The pixel resolution of this guide's crop, given the source frame size —
    /// e.g. a 9:16 guide on a 4096×2304 frame is 1296×2304 at 100% scale.
    func cropResolution(srcW: Int, srcH: Int) -> (w: Int, h: Int) {
        let r = ratio, W = Double(srcW), H = Double(srcH)
        var w: Double, h: Double
        if r > W / H { w = W; h = W / r } else { h = H; w = H * r }
        return (Int((w * scale).rounded()), Int((h * scale).rounded()))
    }
}

@MainActor
final class CameraModel: ObservableObject {
    enum Mode: String, CaseIterable { case live = "Live", play = "Play" }
    enum ViewerSource: String, CaseIterable { case sdi = "SDI", ethernet = "Ethernet" }

    // Connection. Seeded from the last camera used; discovery + known-IP probe
    // fill it on launch. Not a hardcoded address, so the app ships clean.
    @Published var host: String = UserDefaults.standard.string(forKey: "lastHost") ?? "" {
        didSet { if !host.isEmpty { UserDefaults.standard.set(host, forKey: "lastHost") } }
    }
    @Published var connected = false
    @Published var statusLine = "Not connected"
    @Published var cameraTitle = ""

    // Viewer
    @Published var mode: Mode = .live
    @Published var viewerSource: ViewerSource = .ethernet
    @Published var viewerImage: CGImage?
    /// Live Ethernet frame rate, WHOLE-fps for the on-screen readout. Only
    /// republished when the integer changes (see `ethernetFPSExact`) so the
    /// counter doesn't invalidate the whole UI on every frame.
    @Published var ethernetFPS: Double = 0
    /// Precise smoothed frame rate (accumulator + flicker timing). Not published.
    private var ethernetFPSExact: Double = 0

    /// Ethernet-preview quality vs frame rate. Speed = 8-bit (fast, ~8fps).
    /// Quality = 12-bit P16 (~half the fps, but no banding when the raw range
    /// is stretched — PCC-style). Switching re-runs the auto-tune for the new
    /// bit depth. Live viewer only; recordings/downloads are always full.
    enum FeedMode: String, CaseIterable, Identifiable {
        case speed = "More FPS"
        case quality = "Better Image"
        var id: String { rawValue }
    }
    // Default to the higher-quality 12-bit feed ("Better Image") so the live
    // Ethernet preview shows the most accurate colour/detail out of the box.
    // Testers on slower links can switch to "More FPS" for a snappier preview.
    @Published var feedMode: FeedMode = .quality {
        didSet { if oldValue != feedMode { autoTunedMode = nil } }
    }

    // Camera state
    @Published var cines: [CineSlot] = []
    @Published var selectedCine: Int = 1 {
        didSet {
            if selectedCine != oldValue {
                refreshCapacity(force: true)
                playbackSource = .ram(selectedCine)
            }
        }
    }

    // Live settings (defc)
    @Published var resWidth: Int = 2560
    @Published var resHeight: Int = 1440
    @Published var frameRate: Int = 1000
    /// The frame rate the camera is actually at (from telemetry / last committed).
    /// Lets `applyFrameRate` distinguish a real user change from a telemetry echo
    /// so the black-shade reminder only fires when the rate genuinely changes.
    private var committedFrameRate = 0
    @Published var shutterAngle: Double = 180
    @Published var postTriggerFrames: Int = 0
    @Published var totalFrames: Int = 0     // capacity of selected cine at current settings
    @Published var partitionCount: Int = 1
    @Published var capacityFrames: Int = 0  // frspace/frsize of selected partition
    @Published var applyToAllCines = true   // PCC "lock" off = changes hit all empty cines
    @Published var recordingCine: Int? = nil // cine currently in WTR (recording) state
    /// Cines whose CURRENT contents are safely on the laptop or CineMag. Cleared
    /// when a partition re-records (so it only ever marks the clip you saved).
    /// Drives the "this clip isn't downloaded yet" overwrite warning.
    @Published var savedCines: Set<Int> = []

    /// Verify each download (re-open the .cine, check frame count, hash it) and
    /// write an md5 sidecar/manifest. Off-loads aren't marked safe unless it passes.
    @Published var verifyDownloads: Bool = (UserDefaults.standard.object(forKey: "verifyDownloads") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(verifyDownloads, forKey: "verifyDownloads") }
    }
    /// Whether to write the .xml metadata + .mhl checksum sidecars on download.
    @Published var writeSidecars: Bool = (UserDefaults.standard.object(forKey: "writeSidecars") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(writeSidecars, forKey: "writeSidecars") }
    }
    /// Outcome of the most recent verified download — drives the status icon above
    /// the Verify toggle, and (on failure) the must-acknowledge alert.
    struct VerifyStatus: Equatable { let ok: Bool; let clip: String; let message: String }
    @Published var lastVerify: VerifyStatus?
    @Published var verifyFailedAlert: VerifyStatus?     // non-nil → show the alert

    /// A transient banner shown when a (non-verified) download finishes.
    struct DownloadToast: Equatable { let ok: Bool; let title: String; let detail: String }
    @Published var downloadToast: DownloadToast?
    private var toastDismiss: DispatchWorkItem?
    func showDownloadToast(ok: Bool, title: String, detail: String) {
        if !ok { NSSound.beep() }
        toastDismiss?.cancel()
        downloadToast = DownloadToast(ok: ok, title: title, detail: detail)
        let item = DispatchWorkItem { [weak self] in self?.downloadToast = nil }
        toastDismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 4 : 12), execute: item)  // failures linger
    }
    func dismissDownloadToast() { toastDismiss?.cancel(); downloadToast = nil }

    /// Production metadata fields, persisted as JSON so they carry across clips.
    @Published var meta = ShootMetadata() {
        didSet { if let d = try? JSONEncoder().encode(meta) { UserDefaults.standard.set(d, forKey: "shootMeta") } }
    }
    func loadShootMeta() {
        if let d = UserDefaults.standard.data(forKey: "shootMeta"),
           let m = try? JSONDecoder().decode(ShootMetadata.self, from: d) { meta = m }
    }

    /// True if recording into / clearing cine `n` would destroy a stored clip
    /// that hasn't been saved to the laptop or CineMag yet.
    func cineUnsaved(_ n: Int) -> Bool {
        guard let slot = cines.first(where: { $0.id == n }) else { return false }
        return slot.state == .stored && !savedCines.contains(n)
    }

    var recordSeconds: Double { frameRate > 0 ? Double(capacityFrames) / Double(frameRate) : 0 }
    var preTriggerFrames: Int { max(capacityFrames - postTriggerFrames, 0) }

    // Playback
    /// What the playback deck is controlling: a RAM partition or a CineMag take.
    enum PlaybackSource: Equatable {
        case ram(Int)       // partition number
        case mag(Int)       // take index (0-based)
    }
    @Published var playbackSource: PlaybackSource = .ram(1)
    @Published var playFrame: Double = 0
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0
    @Published var isPlaying = false
    @Published var loopPlayback = true
    /// Playback speed multiplier (1 = real time). Drives frame-skip / extra
    /// pacing on the software (ethernet) path and a `rate` field on the
    /// camera-side `vplay` (SDI). Reads live during playback.
    @Published var playbackSpeed: Double = 1.0
    /// Offline-clip playback routed to the EXISTING Video Out monitor (instead of
    /// a separate window). When `offlineClipURL` is set, the Video Out window
    /// shows `offlineImage` (the decoded .cine) instead of the live/RAM feed.
    /// Stops — back to live — when the Clips window closes or the camera reclaims
    /// the screen (Go Live / RAM playback).
    @Published var offlineImage: CGImage?         // raw .cine fallback frame
    @Published var offlineClipURL: URL?           // which clip is on Video Out (nil = none)
    @Published var offlineClip: ClipEntry?        // its metadata (for the heads-up overlay)
    var isPlayingOffline: Bool { offlineClipURL != nil }
    var isPlayingProxy: Bool { proxyPlayer != nil }
    /// Shared AVPlayer for the SDI-proxy path — Video Out + the Clip Playback
    /// window both bind to it, so they stay perfectly in sync.
    @Published var proxyPlayer: AVPlayer?
    @Published var proxyFrame = 0                  // estimated clip frame at the playhead
    @Published var proxyFrac: Double = 0           // 0…1 position (for a custom scrubber)
    @Published var proxyPlaying = true
    private var proxyTimeObserver: Any?

    func proxyTogglePlay() {
        guard let p = proxyPlayer else { return }
        if p.rate == 0 { p.play(); proxyPlaying = true } else { p.pause(); proxyPlaying = false }
    }
    func proxySeek(toFraction frac: Double) {
        guard let p = proxyPlayer, let item = p.currentItem else { return }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return }
        let t = CMTime(seconds: max(0, min(frac, 1)) * dur, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private var proxyEndObserver: NSObjectProtocol?
    /// The decoder driving the raw .cine fallback — exposed so the Clip Playback
    /// window can scrub / transport it (separate from the RAM deck).
    @Published private(set) var offlinePlayer: CinePlayerModel?
    private var offlineImageCancel: AnyCancellable?
    private var lastOfflineClip: ClipEntry?
    /// Force the clean raw .cine (no baked SDI overlays) instead of the proxy —
    /// flips the current clip live. Good when the client shouldn't see overlays.
    @Published var preferRawPlayback = false {
        didSet { if oldValue != preferRawPlayback, let c = offlineClip { playClipOnVideoOut(c) } }
    }
    /// Proxy generation (transcode a .cine → sibling .mov) progress, nil = idle.
    @Published var proxyGenProgress: Double?
    @Published var proxyGenClip: URL?
    /// True while the user is dragging the playhead — the play loop holds still.
    @Published var isScrubbing = false
    @Published var proxyOnDownload = true

    // HQ mode (per-partition on the camera; limits max frame rate)
    @Published var hqMode = false

    // MARK: Per-camera capabilities (auto-detected at connect — the UI adapts)
    @Published var capabilities: Set<String> = []   // tokens from info.features
    @Published var supportsLog = false              // video.adj.log (VEO log modes)
    @Published var supportsDark = false             // cam.dark (BlackShade shutter)
    @Published var supportsQuiet = false            // cam.quiet (fan mode)
    @Published var supportsWBTemp = false           // video.adj.wbtemp (Kelvin WB)
    @Published var supportsCinesVar = false         // cam.cines (direct partition count)
    /// SDI/HDMI output standard (`video.system`): the codes the camera reports as
    /// supported (`info.videosystems`) and the one currently active.
    @Published var availableVideoSystems: [Int] = []
    @Published var currentVideoSystem = 0
    @Published var shutterClosed = false
    @Published var quietMode = false

    func toggleShutterClosed() {
        shutterClosed.toggle()
        sendSimple("set cam.dark \(shutterClosed ? 1 : 0)",
                   label: shutterClosed ? "shutter CLOSED (BlackShade)" : "shutter open")
    }

    func toggleQuiet() {
        quietMode.toggle()
        sendSimple("set cam.quiet \(quietMode ? 1 : 0)", label: "quiet fan \(quietMode ? "on" : "off")")
    }

    /// VEO log modes live on the video out: 0 off, 1 Log1, 2 Log2.
    /// Log replaces the tone curve that IS the VEO's EI mechanism — so while
    /// log is active the ISO/EI control is locked (Buddy: matches the body UI).
    @Published var logMode = 0
    func setLogMode(_ n: Int) {
        logMode = n
        sendSimple("set video.adj.log \(n)", label: "log mode → \(n)")
    }

    func setWBTemp(_ kelvin: Int) {
        sendSimple("set video.adj.wbtemp \(kelvin)", label: "WB \(kelvin)K")
        // The camera recomputes video.adj.red/blue from the Kelvin — re-read so
        // the Match-SDI Ethernet develop doesn't go stale against the SDI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshCameraColor()
        }
    }

    // MARK: - Clean EI + Gain (VEO-class bodies: VEO, Flex 4K — supportsWBTemp)
    //
    // These bodies have NO dedicated EI variable. EI is TWO knobs on `video.adj`:
    //   • tone — a PRE-CALIBRATED "EI#### x1 y1 x2 y2 …" curve sets the CLEAN native EI
    //            ladder (250…1250); the camera's own EI menu loads exactly these curves.
    //            CRITICAL: the bare label ("EI800") does NOT apply the curve — the camera
    //            keeps the name but renders NEUTRAL, so the calibrated x,y POINTS must be
    //            sent. Gain stays pinned at 1.0 across the entire clean ladder.
    //   • gain — global video gain (float, unity 1.0). Extra DIGITAL push (adds noise),
    //            used ONLY to exceed the clean ceiling (e.g. EI 1600, 3200).
    // Effective (body-displayed) EI = cleanEI × gain.   info.baseei (250) = true native ISO.
    //
    // The curves below are the camera's own factory EI tone curves, as observed in the
    // develop metadata of PCC-written .cine files and cross-checked byte-for-byte against
    // a live Flex 4K capture at EI500. They are baseei multiples (1.25×…5.0× = the
    // standard ⅓-stop series); ×250 gives these ISO labels. 250 is the native neutral curve.
    @Published var cleanEI = 0            // clean EI from the tone-curve label (0 = unknown)
    @Published var eiGain: Double = 1.0   // video.adj.gain as a float (unity 1.0)

    /// Clean ISO ladder selectable purely via calibrated tone curves (gain 1.0).
    static let cleanEILadder = [250, 320, 400, 500, 640, 800, 1000, 1250]
    /// Top of the clean ladder — the extra-gain push only unlocks here.
    static let cleanEICeiling = 1250

    /// Calibrated EI tone curves: EI → full `video.adj.tone` string. 250 is the native
    /// neutral curve (no points), handled specially in setCleanEI.
    static let eiToneCurves: [Int: String] = [
        320:  "EI320 0.082 0.100 0.344 0.400 0.702 0.800",
        400:  "EI400 0.068 0.100 0.299 0.400 0.460 0.600 0.622 0.800",
        500:  "EI500 0.056 0.100 0.120 0.200 0.258 0.400 0.403 0.600 0.476 0.700",
        640:  "EI640 0.045 0.100 0.098 0.200 0.218 0.400 0.346 0.600 0.412 0.700",
        800:  "EI800 0.037 0.100 0.082 0.200 0.187 0.400 0.300 0.600 0.359 0.700 0.810 0.980",
        1000: "EI1000 0.030 0.100 0.068 0.200 0.159 0.400 0.260 0.600 0.313 0.700 0.700 0.970",
        1250: "EI1250 0.024 0.100 0.056 0.200 0.134 0.400 0.224 0.600 0.271 0.700 0.600 0.960",
    ]

    /// Effective (body-displayed) EI = clean EI × gain. 0 until known.
    var effectiveEI: Int {
        guard cleanEI > 0 else { return 0 }
        return Int((Double(cleanEI) * eiGain).rounded())
    }

    /// The extra-gain control is live only once EI is pinned at the clean ceiling.
    var gainUnlocked: Bool { cleanEI >= Self.cleanEICeiling }

    /// True when we can drive this EI cleanly (250 = native neutral; else a calibrated curve).
    func haveToneCurve(_ ei: Int) -> Bool { ei == 250 || Self.eiToneCurves[ei] != nil }

    /// Above-ceiling effective-EI options reachable with extra gain (⅓-stop ladder).
    var gainEIChoices: [Int] {
        Self.standardEILadder.filter { $0 > Self.cleanEICeiling && $0 <= 6400 }
    }
    /// Gain multiplier that yields a given effective EI above the ceiling.
    func gainForEI(_ effEI: Int) -> Double { Double(effEI) / Double(Self.cleanEICeiling) }

    /// Extract the clean EI from a `video.adj.tone` value:
    /// "EI500 0.056 …" → 500. nil if there's no "EI####" label (neutral/numeric curve).
    static func parseToneEI(_ s: String) -> Int? {
        let seps: Set<Character> = [" ", "\"", ":", ","]
        for tok in s.split(whereSeparator: { seps.contains($0) }) {
            if tok.hasPrefix("EI"), let n = Int(tok.dropFirst(2)), n > 0 { return n }
        }
        return nil
    }

    /// Select a CLEAN EI (VEO-class): load the calibrated tone curve AND pin gain to 1.0,
    /// so the curve — not digital gain — sets the native EI and the image stays clean.
    /// EI 250 is the sensor's native neutral (tone:0). Never send a bare "EI####" label
    /// with no points — the camera would render it neutral.
    func setCleanEI(_ ei: Int) {
        cleanEI = ei          // optimistic — the picker reflects the choice at once
        eiGain = 1.0          // the clean range always runs unity gain
        let curve = Self.eiToneCurves[ei]
        runCommandAsync { conn -> (Int, Double) in
            // `tone` MUST be a QUOTED STRING on these bodies — the colon form
            // (`set video.adj.tone:0`) errors "expecting quoted string" (verified live),
            // which is why EI 250 silently failed. EI 250 = native neutral → empty curve
            // (""), which clears any loaded EI curve. Calibrated EIs send their points; a
            // missing curve falls back to the bare label (accepted; renders neutral).
            let tone = ei == 250 ? "" : (curve ?? "EI\(ei)")
            _ = try? conn.command("set video.adj.tone \"\(tone)\"")
            _ = try? conn.command("set video.adj.gain 1.0")
            // Read back what the camera actually holds so the UI self-corrects.
            let toneStr = PhantomProtocol.find("tone", in: (try? conn.get("video.adj.tone")) ?? [:])?.stringValue ?? ""
            let g = PhantomProtocol.find("gain", in: (try? conn.get("video.adj.gain")) ?? [:])?.doubleValue ?? 1.0
            // Neutral (250) has no "EI####" label to parse — trust the requested EI.
            let readEI = ei == 250 ? 250 : (Self.parseToneEI(toneStr) ?? ei)
            return (readEI, g > 0 ? g : 1.0)
        } onResult: { [weak self] res in
            guard let self, let (readEI, g) = res else { return }
            self.cleanEI = readEI
            self.eiGain = g
            if ei == 250 {
                self.appendLog("clean EI → 250 (native neutral curve, gain 1.0)")
            } else if curve != nil {
                self.appendLog("clean EI → \(readEI) (calibrated tone curve, gain 1.0)")
            } else {
                self.appendLog("EI \(ei): no calibrated curve — sent label only (renders neutral); gain 1.0")
            }
        }
    }

    /// Push ABOVE the clean ceiling with extra digital gain (VEO-class). Only meaningful at
    /// the ceiling EI (1250); gain 1.0 = no push. Effective EI = ceiling × gain. Leaves the
    /// tone curve (and therefore the clean EI) untouched.
    func setGain(_ gain: Double) {
        let g0 = max(1.0, gain)
        eiGain = g0           // optimistic
        runCommandAsync { conn -> Double in
            _ = try? conn.command("set video.adj.gain \(g0)")
            return PhantomProtocol.find("gain", in: (try? conn.get("video.adj.gain")) ?? [:])?.doubleValue ?? -1
        } onResult: { [weak self] g in
            guard let self, let g, g > 0 else { return }
            self.eiGain = g
            self.appendLog(String(format: "gain → %.2f× (effective EI %d)", g, self.effectiveEI))
        }
    }

    // MARK: App-side presets
    struct Preset: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var width: Int, height: Int, rate: Int, postTrigger: Int
        var shutter: Double
        var hq: Bool
    }
    @Published var presets: [Preset] = {
        guard let data = UserDefaults.standard.data(forKey: "presets"),
              let p = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return p
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(data, forKey: "presets")
            }
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let p = Preset(name: name, width: resWidth, height: resHeight, rate: frameRate,
                       postTrigger: postTriggerFrames, shutter: shutterAngle, hq: hqMode)
        presets.removeAll { $0.name == name }
        presets.append(p)
        appendLog("preset saved: \(name)")
    }

    func apply(preset: Preset) {
        loadingFromCamera = true
        resWidth = preset.width; resHeight = preset.height
        frameRate = preset.rate; postTriggerFrames = preset.postTrigger
        shutterAngle = preset.shutter; hqMode = preset.hq
        loadingFromCamera = false
        applySettings()
        appendLog("preset applied: \(preset.name)")
    }

    // MARK: Auto-save & batch download queue
    @Published var autoSaveTriggered = false {
        didSet { if autoSaveTriggered { autoSaveToMag = false; autoSaveMagRestart = false } }
    }
    /// Trigger → fsave the shot onto the CineMag → clear the RAM partition →
    /// re-armed. The camera-side twin of auto-save (no Ethernet download).
    @Published var autoSaveToMag = false {
        didSet {
            if autoSaveToMag {
                autoSaveTriggered = false; autoSaveMagRestart = false
            }
        }
    }
    /// CONTINUOUS record — the CAMERA ITSELF saves each triggered partition to the
    /// CineMag and immediately re-arms it (`auto.flashsave` + `auto.acqrestart`).
    /// With multiple partitions it cycles through them non-stop: trigger → save →
    /// re-arm → roll, hands-free, no app in the loop. This is PCC's continuous-
    /// record / acquisition-restart, done in firmware. Persisted ON THE CAMERA.
    @Published var autoSaveMagRestart = false {
        didSet {
            guard autoSaveMagRestart != oldValue else { return }
            if autoSaveMagRestart {
                autoSaveTriggered = false; autoSaveToMag = false
            }
            if !suppressAutoModeCommand { setContinuousMagRecord(autoSaveMagRestart) }
        }
    }
    private var suppressAutoModeCommand = false

    /// Pushes the camera's native continuous-record flags. off = both cleared.
    private func setContinuousMagRecord(_ on: Bool) {
        guard connected else { return }
        let v = on ? 1 : 0
        runCommandAsync { conn -> String in
            _ = try? conn.command("set auto.flashsave \(v)")
            _ = try? conn.command("set auto.acqrestart \(v)")
            return "ok"
        } onResult: { [weak self] _ in
            self?.appendLog(on ? "continuous mag record ON — camera saves + re-arms each partition (auto.flashsave + acqrestart)"
                               : "continuous mag record OFF")
        }
    }

    /// Reads the camera's persisted continuous-record flags on connect so the
    /// toggle reflects reality (they're saved on the camera — a prior session or
    /// PCC may have left them on).
    func refreshAutoMode() {
        runCommandAsync { conn -> Bool in
            let fs = PhantomProtocol.find("flashsave", in: (try? conn.get("auto.flashsave")) ?? [:])?.intValue ?? 0
            let ar = PhantomProtocol.find("acqrestart", in: (try? conn.get("auto.acqrestart")) ?? [:])?.intValue ?? 0
            return fs != 0 && ar != 0
        } onResult: { [weak self] on in
            guard let self, let on, on != self.autoSaveMagRestart else { return }
            self.suppressAutoModeCommand = true
            self.autoSaveMagRestart = on
            self.suppressAutoModeCommand = false
        }
    }
    @Published var queuedDownloads = 0
    @Published var magSavingCine: Int?          // partition currently writing to mag
    /// After an auto-save→mag: false = clear the partition (re-arm, default);
    /// true = keep the shot in RAM too (partition stays stored).
    @Published var magSaveKeepsRAM = UserDefaults.standard.bool(forKey: "magSaveKeepRAM") {
        didSet { UserDefaults.standard.set(magSaveKeepsRAM, forKey: "magSaveKeepRAM") }
    }
    private var knownStored: Set<Int> = []
    private var downloadQueue: [(cine: Int, delete: Bool)] = []
    private var magSaveQueue: [Int] = []

    /// Watches for freshly stored shots and, depending on the auto-save mode,
    /// downloads each to the Mac OR saves each onto the CineMag — then clears
    /// the partition so the camera re-arms. Trigger after trigger, hands free.
    func autoSaveSweep(storedNow: Set<Int>) {
        defer { knownStored = storedNow }
        guard autoSaveTriggered || autoSaveToMag else { return }
        let fresh = storedNow.subtracting(knownStored)
        if autoSaveToMag {
            for n in fresh.sorted() where !magSaveQueue.contains(n) && magSavingCine != n {
                magSaveQueue.append(n)
                appendLog("auto-save→mag queued C\(n)")
            }
            pumpMagSave()
            return
        }
        for n in fresh.sorted() where !downloadQueue.contains(where: { $0.cine == n }) {
            downloadQueue.append((n, true))
            appendLog("auto-save queued C\(n)")
        }
        queuedDownloads = downloadQueue.count
        pumpAutoSave()
    }

    private func pumpMagSave() {
        guard magSavingCine == nil, !magSaveQueue.isEmpty else { return }
        // Never fsave to the mag while a Mac download is running — the Flex
        // jams if it does both. Wait it out and retry.
        guard downloadProgress == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pumpMagSave() }
            return
        }
        magSaveCine(magSaveQueue.removeFirst())
    }

    /// fsave C<n> onto the CineMag, wait until the write actually lands
    /// (mag.takes goes up and the mag is idle again), and only THEN clear the
    /// RAM partition. If the save can't be confirmed, the partition is kept.
    private func magSaveCine(_ n: Int) {
        magSavingCine = n
        magBusy = "Saving C\(n) → CineMag…"
        runCommandAsync { conn -> (Int, String) in
            let c = try conn.get("c\(n)")
            let first = PhantomProtocol.find("firstfr", in: c)?.intValue ?? 0
            let last = PhantomProtocol.find("lastfr", in: c)?.intValue ?? 0
            let before = PhantomProtocol.find("takes", in: (try? conn.get("mag.takes")) ?? [:])?.intValue ?? -1
            let reply = try conn.command("fsave {cine:\(n), firstframe:\(first), lastframe:\(last)}", timeout: 15)
            return (before, reply)
        } onResult: { [weak self] result in
            guard let self else { return }
            guard let (before, reply) = result, reply.contains("Ok") else {
                self.magBusy = nil
                self.magOpResult = "Mag save C\(n) refused: \((result?.1 ?? "no reply").trimmingCharacters(in: .whitespacesAndNewlines)) — partition kept."
                self.appendLog("auto-save→mag C\(n) REFUSED")
                self.magSavingCine = nil
                self.pumpMagSave()
                return
            }
            self.pollMagSave(n, takesBefore: before, deadline: Date().addingTimeInterval(600))
        }
    }

    private func pollMagSave(_ n: Int, takesBefore: Int, deadline: Date) {
        runCommandAsync { conn -> (Int, Int) in
            let takes = PhantomProtocol.find("takes", in: (try? conn.get("mag.takes")) ?? [:])?.intValue ?? -1
            let prog = PhantomProtocol.find("progress", in: (try? conn.get("mag.progress")) ?? [:])?.intValue ?? -1
            return (takes, prog)
        } onResult: { [weak self] r in
            guard let self else { return }
            let takes = r?.0 ?? -1
            let prog = r?.1 ?? -1
            // Landed: the take count went up and the mag isn't mid-write.
            if takesBefore >= 0, takes > takesBefore, prog <= 0 || prog >= 100 {
                if self.magSaveKeepsRAM {
                    // Keep the shot in RAM too — mark it saved, don't re-arm.
                    self.savedCines.insert(n)
                    self.appendLog("auto-save→mag: C\(n) safely on mag (take #\(takes)) — kept in RAM")
                    self.magBusy = nil
                    self.magSavingCine = nil
                    self.refreshMag()
                    self.pumpMagSave()
                    return
                }
                self.runCommandAsync { conn in
                    try conn.command("del {cine:\(n)}")
                } onResult: { [weak self] _ in
                    guard let self else { return }
                    self.appendLog("auto-save→mag: C\(n) safely on mag (take #\(takes)) — partition cleared, re-armed")
                    self.magBusy = nil
                    self.magSavingCine = nil
                    self.refreshMag()
                    self.pumpMagSave()
                }
            } else if Date() > deadline {
                self.magBusy = nil
                self.magOpResult = "Mag save C\(n): couldn't confirm it landed — partition KEPT (not cleared)."
                self.appendLog("auto-save→mag C\(n): TIMEOUT waiting for mag write — partition kept")
                self.magSavingCine = nil
                self.pumpMagSave()
            } else {
                if prog > 0 { self.magBusy = "Saving C\(n) → CineMag… \(prog)%" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.pollMagSave(n, takesBefore: takesBefore, deadline: deadline)
                }
            }
        }
    }

    /// End-of-day card dump: queues every stored RAM partition for download
    /// (no deletion — your shots stay on the camera).
    func downloadAllStored() {
        let stored = cines.filter { $0.id > 0 && $0.state == .stored }.map(\.id)
        guard !stored.isEmpty else {
            appendLog("dump all: no stored shots in RAM")
            return
        }
        for n in stored where !downloadQueue.contains(where: { $0.cine == n }) {
            downloadQueue.append((n, false))
        }
        queuedDownloads = downloadQueue.count
        appendLog("dump all: queued \(stored.map { "C\($0)" }.joined(separator: ", "))")
        pumpAutoSave()
    }

    private func pumpAutoSave() {
        queuedDownloads = downloadQueue.count
        guard downloadProgress == nil, let job = downloadQueue.first else { return }
        downloadQueue.removeFirst()
        queuedDownloads = downloadQueue.count
        downloadCine(job.cine, deleteAfter: job.delete)
    }

    // MARK: SDI look & OSD
    @Published var cameraOSD = true

    func toggleOSD() {
        cameraOSD.toggle()
        sendSimple("set video.osddis:\(cameraOSD ? 0 : 1)", label: "camera OSD \(cameraOSD ? "on" : "off")")
    }

    /// Tone presets baked into the camera: 0 off/linear, 1 medium, 2 strong, 3 highs.
    func setTone(_ idx: Int) {
        // A tone preset replaces whatever curve was loaded — including a
        // calibrated clean-EI curve, i.e. it undoes the EI selection. Reflect that.
        cleanEI = 0
        if supportsWBTemp {
            // VEO-class bodies (Flex 4K): `video.adj.tone` is the SAME register as the
            // clean-EI curve and accepts ONLY a QUOTED STRING — the colon/numeric form
            // (`set video.adj.tone:0`) errors "expecting quoted string" (verified live
            // 2026-07-13; same root cause as the EI250 bug). Only idx 0 (Linear/off) has
            // a known write: the empty curve clears any loaded tone/EI curve → native
            // neutral (reads back "", refreshCameraColor then infers cleanEI = baseei).
            // The medium/strong/highs preset curve strings aren't published anywhere we
            // can read for these bodies (only the EI#### curves are), so those items are
            // hidden on supportsWBTemp bodies (see ContentView). This guard is
            // belt-and-braces: never send a command the camera will reject.
            guard idx == 0 else {
                appendLog("SDI tone preset \(idx) unavailable on this body")
                return
            }
            sendSimple("set video.adj.tone \"\"", label: "SDI tone → linear (neutral)")
        } else {
            // Flex 2K and other bodies accept the numeric preset form.
            sendSimple("set video.adj.tone:\(idx)", label: "SDI tone → \(idx)")
        }
    }

    // MARK: Sync / Genlock — what drives the camera's frame clock.
    // VEO Sync source (cam.syncimg): 0 Internal, 1 External (F-Sync pulse),
    // 2 IRIG (timecode), 3 LockToVideo. genlockstatus tells if it's locked.
    enum SyncMode: Int, CaseIterable, Identifiable {
        case internalClock = 0, externalFSync = 1, irig = 2, lockToVideo = 3
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .internalClock: return "Internal"
            case .externalFSync: return "External (F-Sync)"
            case .irig: return "IRIG timecode"
            case .lockToVideo: return "Lock to Video"
            }
        }
        var short: String {
            switch self {
            case .internalClock: return "Internal"
            case .externalFSync: return "F-Sync"
            case .irig: return "IRIG"
            case .lockToVideo: return "LockToVideo"
            }
        }
    }
    @Published var syncMode: SyncMode = .internalClock
    @Published var genlockLocked = false        // info.genlockstatus != 0

    func setSyncMode(_ m: SyncMode) {
        syncMode = m
        sendSimple("set cam.syncimg \(m.rawValue)", label: "sync source → \(m.short)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshGenlock() }
    }

    /// Reads the sync source + lock status from the camera (polled while shown).
    func refreshGenlock() {
        runCommandAsync { conn -> (Int, Bool) in
            let mode = PhantomProtocol.find("syncimg", in: try conn.get("cam.syncimg"))?.intValue ?? 0
            let status = PhantomProtocol.find("genlockstatus", in: try conn.get("info.genlockstatus"))?.intValue ?? 0
            return (mode, status != 0)
        } onResult: { [weak self] r in
            guard let self, let (mode, locked) = r else { return }
            if let m = SyncMode(rawValue: mode) { self.syncMode = m }
            self.genlockLocked = locked
        }
    }

    // MARK: Timecode
    /// Auto-jam the camera's clock to this Mac's time-of-day on every connect.
    @Published var syncTCOnConnect: Bool = UserDefaults.standard.bool(forKey: "syncTCOnConnect") {
        didSet { UserDefaults.standard.set(syncTCOnConnect, forKey: "syncTCOnConnect") }
    }
    /// Timecode format (`cam.tcmode`): 0 = IRIG, 1 = SMPTE.
    @Published var tcMode: Int = 0
    /// Time zone the camera's time-of-day is stamped in — empty = match this Mac.
    /// Lets you set the camera to the SHOOT's location, not the laptop's zone.
    @Published var tcTimeZoneID: String = UserDefaults.standard.string(forKey: "tcTimeZoneID") ?? "" {
        didSet { UserDefaults.standard.set(tcTimeZoneID, forKey: "tcTimeZoneID") }
    }
    var tcTimeZone: TimeZone { tcTimeZoneID.isEmpty ? .current : (TimeZone(identifier: tcTimeZoneID) ?? .current) }

    /// Jam the camera's real-time clock to time-of-day in the selected zone. The
    /// Phantom clock is UTC and this body has no `cam.tz`, so we bake the zone's
    /// offset into the epoch — the camera then shows that zone's local time on its
    /// OSD / timecode. (Fresh Flex 4K bodies boot at a year-2000 default. NOTE:
    /// this only affects FUTURE recordings — already-shot takes keep their TC.)
    func syncTimecodeToTimeOfDay() {
        let now = Date()
        let epoch = Int(now.timeIntervalSince1970) + tcTimeZone.secondsFromGMT(for: now)
        // BARE form only — `setrtc { value: N }` returns Ok! but silently ignores
        // the value; `setrtc <N>` actually sets the timebase (verified live on the
        // Flex 4K: it jumps immediately, no reboot).
        let f = DateFormatter(); f.timeStyle = .medium; f.timeZone = tcTimeZone
        sendSimple("setrtc \(epoch)",
                   label: "timecode → \(f.string(from: now)) (\(tcTimeZoneID.isEmpty ? "this Mac" : tcTimeZoneID))")
    }

    /// Timecode format on the camera (`cam.tcmode`): 0 = IRIG, 1 = SMPTE.
    func setTCMode(_ n: Int) {
        tcMode = n
        sendSimple("set cam.tcmode \(n)", label: "timecode mode → \(n == 1 ? "SMPTE" : "IRIG")")
    }

    /// Read the timecode format back from the camera (called on connect).
    func refreshTimecode() {
        runCommandAsync { conn -> Int in
            PhantomProtocol.find("tcmode", in: (try? conn.get("cam.tcmode")) ?? [:])?.intValue ?? 0
        } onResult: { [weak self] mode in
            guard let self, let mode else { return }
            if mode != self.tcMode { self.tcMode = mode }
        }
    }

    // MARK: Viewer assists
    @Published var focusPeaking = false
    @Published var showGrid = false
    @Published var gridDivisions = 3      // 2 = halves, 3 = thirds, 4 = quarters
    @Published var gridCrosshair = true
    @Published var gridColorName = "white"
    @Published var gridOpacity: Double = 0.35
    static let gridColors: [(String, Color)] = [
        ("white", .white), ("red", .red), ("yellow", .yellow),
        ("green", .green), ("cyan", .cyan), ("black", .black)
    ]
    var gridColor: Color {
        Self.gridColors.first(where: { $0.0 == gridColorName })?.1 ?? .white
    }

    // Frame guides: a configurable list of aspect-ratio boxes (ratio, scale,
    // position, color, line opacity, outside dim) — a SmallHD/RED-style guide
    // system edited in the Frame Guides window.
    @Published var frameGuideList: [FrameGuide] = [] {
        didSet {   // persist so the day's guide setup survives app restarts
            if let data = try? JSONEncoder().encode(frameGuideList) {
                UserDefaults.standard.set(data, forKey: "frameGuideList")
            }
        }
    }
    func loadFrameGuides() {
        if let data = UserDefaults.standard.data(forKey: "frameGuideList"),
           let list = try? JSONDecoder().decode([FrameGuide].self, from: data) {
            frameGuideList = list
        }
    }
    /// Master on/off for all frame guides (the Guides pill left-click toggle).
    @Published var guidesVisible: Bool = (UserDefaults.standard.object(forKey: "guidesVisible") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(guidesVisible, forKey: "guidesVisible") }
    }
    @Published var videoOutOverlays = true     // show grid/guides on the Video Out window
    /// Bumped to ask the Video Out window to go full screen on its display (the
    /// "Full Screen on 2nd display" item in the Video Out menu). SDIOutputView
    /// observes this and toggles the window to fill the screen.
    @Published var videoOutFullScreenTick = 0

    // Onion-skin overlay: a saved reference frame layered over the live image at
    // reduced opacity, so products can be realigned to exactly where they were.
    @Published var overlayImage: CGImage?
    @Published var overlayName = ""
    @Published var overlayOpacity: Double = 0.5
    @Published var overlayEnabled = false

    // Blink (SmallHD-style): flash between the live feed and the reference to spot
    // misalignment. Speed 0 = off, 1 = on 2s/off 2s … 10 = on/off ~2×/sec.
    @Published var overlayBlinkSpeed: Int = 0 { didSet { restartBlinkTimer() } }
    @Published private var overlayBlinkHidden = false
    private var blinkTimer: Timer?

    /// Opacity actually drawn — folds in the blink's hidden phase.
    var effectiveOverlayOpacity: Double {
        guard overlayEnabled else { return 0 }
        return (overlayBlinkSpeed > 0 && overlayBlinkHidden) ? 0 : overlayOpacity
    }

    private func restartBlinkTimer() {
        blinkTimer?.invalidate(); blinkTimer = nil; overlayBlinkHidden = false
        guard overlayBlinkSpeed > 0 else { return }
        let interval = 2.0 / Double(overlayBlinkSpeed)   // speed 1 → 2s/phase, speed 10 → 0.2s
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.overlayBlinkHidden.toggle() }
        }
    }

    /// `<saveFolder>/<project>/Screenshots` — created on demand.
    func screenshotsFolder() -> URL {
        var dir = URL(fileURLWithPath: saveFolderPath)
        let proj = Self.sanitize(projectName)
        if !proj.isEmpty { dir.appendPathComponent(proj) }
        dir.appendPathComponent("Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves the current monitor image as a PNG in the project's Screenshots folder.
    func grabScreenshot() {
        // SDI: prefer the processed frame (tools on); else build one from the
        // latest raw SDI frame on demand (tools off — we don't keep a CGImage
        // around then, for smoothness). Ethernet: the live preview image.
        let sdiImg = viewerSource == .sdi && sdi.isRunning
            ? (monitor.processedImage ?? monitor.latestFrameImage())
            : nil
        guard let img = sdiImg ?? viewerImage else {
            appendLog("screenshot: no image on the monitor to grab"); return
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let url = screenshotsFolder().appendingPathComponent("grab_\(fmt.string(from: Date())).png")
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        do { try (out as Data).write(to: url); appendLog("screenshot → \(url.lastPathComponent)") }
        catch { appendLog("screenshot failed: \(error)") }
    }

    /// The project's saved screen grabs, newest first (timestamped names sort).
    func screenshotURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: screenshotsFolder(),
                    includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func loadOverlay(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            appendLog("overlay load failed: \(url.lastPathComponent)"); return
        }
        overlayImage = img; overlayName = url.lastPathComponent; overlayEnabled = true
    }

    func clearOverlay() { overlayImage = nil; overlayName = ""; overlayEnabled = false; overlayBlinkSpeed = 0 }

    /// On-set one-tap: capture the current frame and immediately make it the
    /// overlay reference (e.g. lock a prop's position before it's moved).
    func grabScreenshotAndUse() {
        grabScreenshot()
        if let newest = screenshotURLs().first { loadOverlay(newest) }
    }

    /// Imports an external image (e.g. dragged in from Finder) as the overlay,
    /// copying it into the project's Screenshots folder so it persists and shows
    /// up in the Load list.
    func importOverlay(from url: URL) {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let base = Self.sanitize(url.deletingPathExtension().lastPathComponent)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let dest = screenshotsFolder().appendingPathComponent("import_\(base)_\(fmt.string(from: Date())).\(ext)")
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
            loadOverlay(dest)
        } else {
            loadOverlay(url)   // fall back to loading it in place
        }
    }

    static let overlayImageExts = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp"]

    /// Loads the first dropped image file as the overlay. Returns true if it took one.
    static func loadOverlayDrop(_ providers: [NSItemProvider], into model: CameraModel) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, overlayImageExts.contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in model.importOverlay(from: url) }
        }
        return true
    }
    static let frameGuidePresets: [(name: String, ratio: Double)] = [
        ("2.39:1", 2.39), ("2.0:1", 2.0), ("1.85:1", 1.85), ("16:9", 16.0/9.0),
        ("4:3", 4.0/3.0), ("1:1", 1.0), ("4:5", 4.0/5.0), ("9:16", 9.0/16.0), ("Custom", 1.78)
    ]

    // MARK: Camera video-out (border colors, punch-in, sharpening)
    @Published var punchIn = false

    func setVideoVar(_ name: String, _ value: String, label: String? = nil) {
        sendSimple("set video.\(name) \(value)", label: label ?? "video.\(name) = \(value)")
    }

    // MARK: SDI / HDMI video output standard (video.system)

    /// One selectable output standard. `clean` = progressive, the safest for a
    /// USB capture box's auto-detect (PsF / interlaced often "bounce"). Code
    /// values are the Phantom SDK `VideoSystem` enum (verified vs the camera's
    /// own `info.videosystems` list + the Phantom SDK Reference Manual).
    struct VideoSystemOption: Identifiable {
        let id: Int           // the `video.system` code
        let label: String
        let clean: Bool       // true = progressive (recommended for capture)
    }

    /// Full code→format table. We only show the rows the camera reports.
    static let videoSystemTable: [VideoSystemOption] = [
        .init(id: 0,  label: "NTSC",          clean: false),
        .init(id: 1,  label: "PAL",           clean: false),
        .init(id: 4,  label: "720p60",        clean: true),
        .init(id: 12, label: "720p59.94",     clean: true),
        .init(id: 5,  label: "720p50",        clean: true),
        .init(id: 20, label: "1080p30",       clean: true),
        .init(id: 28, label: "1080p29.97",    clean: true),
        .init(id: 21, label: "1080p25",       clean: true),
        .init(id: 36, label: "1080p24",       clean: true),
        .init(id: 44, label: "1080p23.98",    clean: true),
        .init(id: 68, label: "1080i60",       clean: false),
        .init(id: 76, label: "1080i59.94",    clean: false),
        .init(id: 69, label: "1080i50",       clean: false),
        .init(id: 52, label: "1080PsF30",     clean: false),
        .init(id: 60, label: "1080PsF29.97",  clean: false),
        .init(id: 53, label: "1080PsF25",     clean: false),
        .init(id: 84, label: "1080PsF24",     clean: false),
        .init(id: 92, label: "1080PsF23.98",  clean: false),
    ]

    /// The output standards this camera actually offers, in our display order.
    var videoSystemOptions: [VideoSystemOption] {
        let avail = Set(availableVideoSystems)
        let known = Self.videoSystemTable.filter { avail.contains($0.id) }
        return known.isEmpty ? Self.videoSystemTable.filter { $0.clean } : known
    }

    static func videoSystemLabel(_ code: Int) -> String {
        videoSystemTable.first(where: { $0.id == code })?.label ?? "code \(code)"
    }

    /// Sets the camera's SDI/HDMI output standard. The capture box drops its
    /// signal when the format changes, so we re-arm the SDI session right after.
    func setVideoSystem(_ code: Int) {
        currentVideoSystem = code
        setVideoVar("system", "\(code)", label: "SDI output → \(Self.videoSystemLabel(code))")
        // Give the camera a beat to relock the output, then rescan/restart SDI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.sdi.forceReconnect()
        }
    }

    func togglePunchIn() {
        punchIn.toggle()
        setVideoVar("uzoom", punchIn ? "1" : "0", label: "1:1 punch-in \(punchIn ? "on" : "off")")
    }

    /// Camera state borders: protocol hex is 00RRGGBB.
    static let borderColorChoices: [(String, String)] = [
        ("Red", "00FF4040"), ("Gold", "00FFC040"), ("Green", "0040FF40"),
        ("Blue", "000080FF"), ("Orange", "00FF8000"), ("White", "00FFFFFF"),
        ("Hidden", "00000000")
    ]
    static let borderDefaults: [(String, String)] = [
        ("wtr_color", "00FF4040"), ("trg_color", "00FFC040"), ("cst_color", "0040FF40"),
        ("pre_color", "000080FF"), ("acq_color", "00FF8000")
    ]

    func resetBorderColors() {
        for (name, hex) in Self.borderDefaults { setVideoVar(name, hex, label: nil) }
        appendLog("video borders reset to defaults")
    }

    // MARK: Speed ramp (experimental — camera frame rate profile)
    struct RampSegment: Identifiable, Equatable {
        var id = UUID()
        var rate: Int            // fps for this segment
        var durationFrames: Int  // how long this segment runs, in frames
    }
    enum RampPreset: String, CaseIterable, Identifiable {
        case up = "Ramp up", down = "Ramp down", holdBlast = "Hold, then blast", climb = "Three-stage climb"
        var id: String { rawValue }
    }

    /// Speed-ramp segments, in order from the start of the take. Each is a rate +
    /// a duration; the first begins at frame 0 (the trigger) and each following one
    /// begins where the previous ended. Written to `defc.profile` p0…p3 as
    /// cumulative change points. VERIFIED non-functional on the Flex 2K (whole take
    /// records at the fastest rate) — built for VEO / Flex4K.
    @Published var rampSegments: [RampSegment] = []

    /// True on the one body we've PROVEN doesn't ramp — the Flex 2K (Flex-class,
    /// ≤2560-wide sensor). Drives the editor's hard warning.
    var rampKnownBroken: Bool { !supportsCinesVar && xMax <= 2560 }

    /// Max fps the current resolution can shoot — the editor clamps every segment.
    var rampMaxFPS: Int { estimatedMaxFPS(width: resWidth, height: resHeight) }

    /// The frame each segment starts on (segment 0 = 0, then cumulative durations).
    var rampSegmentStarts: [Int] {
        var acc = 0
        return rampSegments.map { seg in defer { acc += max(0, seg.durationFrames) }; return acc }
    }
    /// Total frames / seconds the ramp spans — shown so you can gauge the shot.
    var rampTotalFrames: Int { rampSegments.reduce(0) { $0 + max(0, $1.durationFrames) } }
    var rampTotalSeconds: Double {
        rampSegments.reduce(0.0) { $0 + Double(max(0, $1.durationFrames)) / Double(max(1, $1.rate)) }
    }
    /// Real-time length of one segment (frames ÷ its rate).
    func rampSeconds(for seg: RampSegment) -> Double {
        Double(max(0, seg.durationFrames)) / Double(max(1, seg.rate))
    }

    /// Exposure (ns) holding the current shutter angle at `rate`, clamped to the
    /// FASTEST rate's frame period (the camera enforces this cap with a profile).
    func rampExposure(for rate: Int, fastest: Int) -> Int {
        let want = (shutterAngle / 360.0) * 1e9 / Double(max(rate, 1))
        let cap = 0.997 * 1e9 / Double(max(fastest, 1))
        return Int(min(cap, max(1000.0, want)))
    }

    func loadRampPreset(_ p: RampPreset) {
        let m = rampMaxFPS
        func r(_ x: Int) -> Int { min(x, m) }
        switch p {
        case .up:        rampSegments = [.init(rate: r(250),  durationFrames: 500), .init(rate: r(1000), durationFrames: 500)]
        case .down:      rampSegments = [.init(rate: r(1000), durationFrames: 300), .init(rate: r(250),  durationFrames: 500)]
        case .holdBlast: rampSegments = [.init(rate: r(125),  durationFrames: 250), .init(rate: r(1500), durationFrames: 750)]
        case .climb:     rampSegments = [.init(rate: r(250),  durationFrames: 300), .init(rate: r(1000), durationFrames: 300), .init(rate: r(1500), durationFrames: 400)]
        }
    }

    /// True while a speed ramp is INTENTIONALLY applied. Normal settings changes
    /// release the ramp's exposure clamp only when this is false (so an armed
    /// ramp survives an edit, but a stale one can't quietly cap the shutter).
    var rampArmed = false
    /// The camera currently has a live ramp profile (`defc.profile.atrig 1`),
    /// which caps max exposure to the fastest rate's frame period — read back
    /// from the camera so the shutter cap it imposes is never a mystery.
    @Published var rampActiveOnCamera = false
    /// Whether this body exposes a `defc.profile` speed-ramp block (Flex 2K / VEO).
    /// The **Flex 4K does NOT** — it uses a `defc.ramp` string instead and REJECTS
    /// `set defc.profile.*` with "name profile is unknown". Detected from the defc
    /// read; guards every profile write so we never spam that camera with errors.
    var supportsProfileRamp = true
    /// Drives the "Reset Camera" confirmation from the Help menu.
    @Published var showResetCamera = false

    /// Writes the ramp segments to `defc.profile` p0…p3: each segment becomes a
    /// change point at its cumulative start frame, rates clamped to the sensor max,
    /// exposures auto-set to hold the shutter angle, then `atrig` on.
    func applyRampProfile() {
        guard supportsProfileRamp else {
            appendLog("speed ramp: this body has no defc.profile (Flex 4K uses defc.ramp) — not applied")
            return
        }
        let maxF = rampMaxFPS
        let segs = Array(rampSegments.filter { $0.rate > 0 && $0.durationFrames > 0 }.prefix(4))
        guard !segs.isEmpty else { clearRampProfile(); return }
        let fastest = segs.map { min($0.rate, maxF) }.max() ?? 1
        var acc = 0
        let writes: [(cnt: Int, rate: Int, exp: Int)] = segs.map { seg in
            let rate = min(seg.rate, maxF)
            let cnt = acc
            acc += max(0, seg.durationFrames)
            return (cnt: cnt, rate: rate, exp: rampExposure(for: rate, fastest: fastest))
        }
        let total = acc
        runCommandAsync { conn -> String in
            for (i, w) in writes.enumerated() {
                _ = try? conn.command("set defc.profile.p\(i)cnt \(w.cnt)")
                _ = try? conn.command("set defc.profile.p\(i)rate \(w.rate)")
                _ = try? conn.command("set defc.profile.p\(i)exp \(w.exp)")
            }
            for i in writes.count..<4 {
                _ = try? conn.command("set defc.profile.p\(i)cnt 0")
                _ = try? conn.command("set defc.profile.p\(i)rate 0")
                _ = try? conn.command("set defc.profile.p\(i)exp 0")
            }
            _ = try? conn.command("set defc.profile.atrig 1")
            return "ok"
        } onResult: { [weak self] _ in
            guard let self else { return }
            self.rampArmed = true
            self.rampActiveOnCamera = true
            self.appendLog("ramp: \(writes.count) segment(s), \(total)fr total → " + writes.map { "@\($0.cnt):\($0.rate)fps" }.joined(separator: " "))
        }
    }

    func clearRampProfile() {
        guard supportsProfileRamp else {   // Flex 4K: nothing to clear, just reset local state
            rampArmed = false; rampActiveOnCamera = false
            return
        }
        runCommandAsync { conn -> String in
            for i in 0..<4 {
                _ = try? conn.command("set defc.profile.p\(i)cnt 0")
                _ = try? conn.command("set defc.profile.p\(i)rate 0")
                _ = try? conn.command("set defc.profile.p\(i)exp 0")
            }
            _ = try? conn.command("set defc.profile.atrig 0")
            return "cleared"
        } onResult: { [weak self] _ in
            guard let self else { return }
            self.rampArmed = false
            self.rampActiveOnCamera = false
            self.appendLog("ramp cleared")
        }
    }

    /// Master "clean slate" reset — the closest thing to a factory reset. There is
    /// NO single reset command in the Phantom protocol, so this is a safe SEQUENCE:
    /// clear any speed-ramp profile, go to full resolution at its max frame rate
    /// with a 180° shutter and a SINGLE partition (which erases RAM), and reset
    /// white balance to daylight + base EI. Black reference is deliberately NOT run
    /// automatically — it needs a lens cap on this shutterless body — so the
    /// re-black-shade reminder pops instead so it can be done on purpose.
    func resetCamera() {
        guard connected else { appendLog("reset: not connected to a camera"); return }
        // 1. Target the clean state locally; finishRepartition→applySettings pushes it.
        loadingFromCamera = true
        resWidth = xMax; resHeight = yMax
        let maxFPS = estimatedMaxFPS(width: xMax, height: yMax)   // camera clamps to its true max
        frameRate = maxFPS
        committedFrameRate = maxFPS
        shutterAngle = 180
        postTriggerFrames = 0
        rampSegments = []
        loadingFromCamera = false
        // 2. Clear ramp + reset WB/EI on the camera, then erase RAM → 1 partition.
        let hasProfile = supportsProfileRamp
        runCommandAsync { conn -> String in
            if hasProfile {                                      // Flex 4K has no defc.profile
                for i in 0..<4 {
                    _ = try? conn.command("set defc.profile.p\(i)cnt 0")
                    _ = try? conn.command("set defc.profile.p\(i)rate 0")
                    _ = try? conn.command("set defc.profile.p\(i)exp 0")
                }
                _ = try? conn.command("set defc.profile.atrig 0")    // release exposure clamp
            }
            _ = try? conn.command("set video.adj.gain 1024")     // base EI (1024 = 1×)
            _ = try? conn.command("set video.adj.wbtemp 5600")   // daylight WB (camera recomputes red/blue)
            return "ok"
        } onResult: { [weak self] _ in
            guard let self else { return }
            self.rampArmed = false
            self.rampActiveOnCamera = false
            self.appendLog("reset: ramp cleared · WB→5600K · EI→base · \(self.resWidth)×\(self.resHeight) @\(self.frameRate)fps 180°")
            // Erase RAM + single partition; finishRepartition re-applies res/rate/exp.
            self.setPartitions(1)
            // Prompt a fresh black balance (lens cap) — never auto-run a bad one.
            self.blackRefDone = false
            self.blackShadeReminderRate = self.frameRate
            self.showBlackShadeReminder = true
        }
    }

    // MARK: - Camera Console (raw protocol / "netcat")

    /// One line in the raw-command console: what was sent and what came back.
    struct ConsoleEntry: Identifiable {
        let id = UUID()
        let command: String
        let response: String
        let ok: Bool
    }
    /// Transcript for the advanced raw-command console (File ▸ Camera Console).
    @Published var consoleLog: [ConsoleEntry] = []

    /// Send a raw Phantom protocol command straight to the camera and record the
    /// reply. This is the full "netcat" surface — anything the SDK exposes works:
    /// get/set of ANY var, rec, trig, iload, the cam.* advanced controls, etc.
    /// Runs over the app's existing camera connection (no second socket).
    func runConsoleCommand(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        guard connected else {
            consoleLog.append(ConsoleEntry(command: cmd, response: "— not connected to a camera —", ok: false))
            return
        }
        runCommandAsync { conn -> String in
            try conn.command(cmd, timeout: 8.0)
        } onResult: { [weak self] resp in
            guard let self else { return }
            let r = (resp ?? "(no reply)").trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = !r.uppercased().contains("ERR")
            self.consoleLog.append(ConsoleEntry(command: cmd, response: r, ok: ok))
            self.appendLog("console: \(cmd) → \(ok ? "ok" : "err")")
        }
    }

    func clearConsole() { consoleLog.removeAll() }

    // MARK: Stream Deck & phone remote
    private var remote: RemoteControl?

    /// Secret path prefix that lets the phone in — generated once, kept
    /// between launches so the bookmarked URL on the phone keeps working.
    let remoteToken: String = {
        if let t = UserDefaults.standard.string(forKey: "remoteToken"), !t.isEmpty { return t }
        // No 0/O/1/l — this gets typed by thumb on a phone keyboard.
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let t = String((0..<6).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(t, forKey: "remoteToken")
        return t
    }()

    /// What to open on the phone (shown in the shortcuts popover). Prefers the
    /// Mac's Bonjour name (stable across networks/DHCP) so a home-screen
    /// bookmark keeps working; raw-IP URLs remain as fallbacks below.
    var remoteURLString: String {
        let host = RemoteControl.bonjourHostname()
            ?? RemoteControl.lanIPAddress()
            ?? "<this-Mac's-IP>"
        return "http://\(host):\(remote?.port ?? 8989)/\(remoteToken)/"
    }

    /// Other reachable URLs (Mac on more than one network — e.g. Wi-Fi + a wired
    /// switch), plus the raw-IP form of the primary in case the phone's network
    /// blocks Bonjour. Shown as fallbacks.
    var remoteAltURLs: [String] {
        let port = remote?.port ?? 8989
        var urls = RemoteControl.lanIPCandidates()
            .map { "http://\($0):\(port)/\(remoteToken)/" }
        urls.removeAll { $0 == remoteURLString }
        return urls
    }

    func startRemote() {
        guard remote == nil else { return }
        remote = RemoteControl(token: remoteToken, responder: { [weak self] path in
            guard let self else { return RemoteResponse(status: 503, body: "shutting down") }
            return self.handleRemote(path)
        }, frameProvider: { [weak self] in
            self?.currentViewerJPEG()
        })
        remote?.start()
        // Start the standalone low-latency H.264 streamer on its own port.
        stream = VideoStreamServer(port: Self.streamPort, token: remoteToken)
        stream?.setBitrate(Int(streamBitrateMbps * 1_000_000))
        stream?.start()
        appendLog("remote: phone URL \(remoteURLString)")
    }

    private func handleRemote(_ path: String) -> RemoteResponse {
        // Polled every second by the phone page — answer quietly, no log.
        if path.hasPrefix("/status") {
            return RemoteResponse(contentType: "application/json", body: remoteStatusJSON())
        }
        // Live SDI/viewer frame as a JPEG, for the phone's preview. Polled a few
        // times a second — answer quietly, no log.
        if path.hasPrefix("/frame") {
            if let jpeg = currentViewerJPEG() {
                return RemoteResponse(contentType: "image/jpeg", bodyData: jpeg,
                                      extraHeaders: ["Cache-Control": "no-store"])
            }
            return RemoteResponse(status: 503, body: "no frame")
        }
        // Home-screen icon for "Add to Home Screen".
        if path.hasPrefix("/appicon") {
            if let u = Bundle.main.url(forResource: "apple-touch-icon", withExtension: "png"),
               let data = try? Data(contentsOf: u) {
                return RemoteResponse(contentType: "image/png", bodyData: data)
            }
            return RemoteResponse(status: 404, body: "no icon")
        }
        // Serve a saved screen grab so the phone can browse them for the overlay.
        if path.hasPrefix("/screenshot/") {
            let name = String(path.dropFirst("/screenshot/".count)).removingPercentEncoding ?? ""
            guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
                return RemoteResponse(status: 403, body: "no")
            }
            let url = screenshotsFolder().appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                let ct = name.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
                return RemoteResponse(contentType: ct, bodyData: data, extraHeaders: ["Cache-Control": "no-store"])
            }
            return RemoteResponse(status: 404, body: "no screenshot")
        }
        switch true {
        case path.hasPrefix("/trigger"): trigger()
        case path.hasPrefix("/capture"): capture()
        case path.hasPrefix("/live"): goLive()
        case path == "/play": if !isPlaying { startPlayback() }   // exact: don't swallow /playfrom
        case path.hasPrefix("/pause"): stopPlayback()
        case path.hasPrefix("/seek/"):
            // Phone scrubber: move the SDI image one frame at a time.
            if let f = Int(path.dropFirst("/seek/".count)) {
                if isPlaying { stopPlayback() }
                if mode != .play { mode = .play }
                playFrame = Double(f)
                scrub(to: f)
            }
        case path.hasPrefix("/markin"): markIn()
        case path.hasPrefix("/markout"): markOut()
        case path.hasPrefix("/playfrom/"):
            if let f = Int(path.dropFirst("/playfrom/".count)) {
                if mode != .play { mode = .play }
                playFromFrame(f)
            }
        case path.hasPrefix("/setout/"):
            if let f = Int(path.dropFirst("/setout/".count)) { setOutFrame(f) }
        case path.hasPrefix("/setin/"):
            if let f = Int(path.dropFirst("/setin/".count)) { setInFrame(f) }
        case path.hasPrefix("/autoplayframe/"):
            if let f = Int(path.dropFirst("/autoplayframe/".count)) { autoPlayStartFrame = max(0, f) }
        case path.hasPrefix("/autoplay"):
            if path.hasSuffix("/on") { autoPlayEnabled = true }
            else if path.hasSuffix("/off") { autoPlayEnabled = false }
            else { autoPlayEnabled.toggle() }
        case path.hasPrefix("/partitions/"):
            if let n = Int(path.dropFirst("/partitions/".count)), n >= 1 {
                setPartitions(n)
            }
        case path.hasPrefix("/blackref"): blackReference()
        case path.hasPrefix("/wb"): cameraWhiteBalance()
        case path == "/flicker" || path == "/flicker/on" || path == "/flicker/off":
            let on = path.hasSuffix("/on") ? true
                   : path.hasSuffix("/off") ? false
                   : !monitor.tools.flickerMap
            monitor.tools.flickerMap = on
            monitor.sampleFlicker = on
            if on { monitor.resetFlickerGrid() } else { flicker.reset() }
        case path.hasPrefix("/scanflicker"): scanFlickerOnClip()
        case path.hasPrefix("/stopscan"): stopFlickerScan()
        case path.hasPrefix("/flickershutter"): applyFlickerShutter()
        case path.hasPrefix("/stopstore"): stopAndStore()
        case path.hasPrefix("/delcine/"):
            if let n = Int(path.dropFirst("/delcine/".count)), n > 0 { deleteCine(n) }
        case path.hasPrefix("/proxy"): saveSDIProxy()
        case path.hasPrefix("/savesmart"): saveInOutSmart()   // mag if present, else Mac
        case path.hasPrefix("/download"): downloadSelectedCine()
        case path.hasPrefix("/trigpos/"):
            // Where the trigger sits in the take: keep footage BEFORE it (end),
            // AFTER it (start), or split 50/50 (mid). Sets post-trigger frames.
            let cap = capacityFrames > 0 ? capacityFrames : max(postTriggerFrames, frameRate)
            switch String(path.dropFirst("/trigpos/".count)) {
            case "start": postTriggerFrames = cap          // keep everything after the trigger
            case "end":   postTriggerFrames = 0            // keep everything before the trigger
            default:      postTriggerFrames = cap / 2      // 50 / 50
            }
            applySettings()
        case path.hasPrefix("/selectcine/"):
            if let n = Int(path.dropFirst("/selectcine/".count)), n > 0 {
                selectCine(n)   // stored → jump SDI to it; recording/empty → live
            }
        case path.hasPrefix("/resetinout"): resetInOut()
        case path.hasPrefix("/clearram"): clearAllRam()
        case path.hasPrefix("/rate/"):
            if let r = Int(path.dropFirst("/rate/".count)), r > 0 {
                frameRate = r
                applySettings()
            }
        case path.hasPrefix("/shutter/"):
            if let a = Double(path.dropFirst("/shutter/".count)), a > 0 {
                shutterAngle = min(359, max(1, a))
                applySettings()
            }
        case path.hasPrefix("/res/"):
            let parts = path.dropFirst("/res/".count).split(separator: "/")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                resWidth = w; resHeight = h
                applySettings()
            }
        case path.hasPrefix("/autosave"):
            if path.hasSuffix("/on") { autoSaveTriggered = true }
            else if path.hasSuffix("/off") { autoSaveTriggered = false }
            else { autoSaveTriggered.toggle() }
        case path.hasPrefix("/preset/"):
            let name = String(path.dropFirst("/preset/".count))
            if let p = presets.first(where: { $0.name.lowercased() == name.lowercased() }) {
                apply(preset: p)
            } else {
                appendLog("remote: no preset named \(name)")
                return RemoteResponse(status: 404, body: "no such preset")
            }
        case path.hasPrefix("/mon/"):
            switch String(path.dropFirst("/mon/".count)) {
            case "falsecolor": monitor.tools.falseColor.toggle()
            case "fcmode":
                let modes = SDIProcessor.falseColorModes.map(\.id)
                if !monitor.tools.falseColor { monitor.tools.falseColor = true }
                else if let i = modes.firstIndex(of: monitor.tools.falseColorMode) {
                    monitor.tools.falseColorMode = modes[(i + 1) % modes.count]
                }
            case "peaking": monitor.tools.peaking.toggle()
            case "zebra": monitor.tools.zebra.toggle()
            case "histogram": monitor.showHistogram.toggle()
            case "waveform": monitor.showWaveform.toggle()
            case "vectorscope": monitor.showVectorscope.toggle()
            case "grid": showGrid.toggle()
            case "guides": guidesVisible.toggle()
            case "invert": monitor.tools.invert.toggle()
            case "fliph": monitor.tools.flipH.toggle()
            case "flipv": monitor.tools.flipV.toggle()
            case "rotate":   // vertical mode: cycle off → 90° CW → 90° CCW → off
                let c = monitor.tools.rotate
                monitor.tools.rotate = c == 0 ? 90 : (c == 90 ? 270 : 0)
                ExportRotation.current = monitor.tools.rotate   // bake into exports/thumbnails
            default: break
            }
        // ── Image overlay (phone) ──
        case path.hasPrefix("/overlay/grabuse"): grabScreenshotAndUse()
        case path.hasPrefix("/overlay/grab"): grabScreenshot()
        case path.hasPrefix("/overlay/toggle"): if overlayImage != nil { overlayEnabled.toggle() }
        case path.hasPrefix("/overlay/clear"): clearOverlay()
        case path.hasPrefix("/overlay/opacity/"):
            if let n = Int(path.dropFirst("/overlay/opacity/".count)) { overlayOpacity = Double(min(100, max(0, n))) / 100 }
        case path.hasPrefix("/overlay/blink/"):
            if let n = Int(path.dropFirst("/overlay/blink/".count)) { overlayBlinkSpeed = min(10, max(0, n)) }
        case path.hasPrefix("/overlay/load/"):
            let name = String(path.dropFirst("/overlay/load/".count)).removingPercentEncoding ?? ""
            let url = screenshotsFolder().appendingPathComponent(name)
            if !name.isEmpty, !name.contains("/"), FileManager.default.fileExists(atPath: url.path) { loadOverlay(url) }
        // ── Grid (phone) ──
        case path.hasPrefix("/grid/div/"):
            if let n = Int(path.dropFirst("/grid/div/".count)) { gridDivisions = n; showGrid = true }
        case path.hasPrefix("/grid/crosshair"): gridCrosshair.toggle()
        case path.hasPrefix("/grid/opacity/"):
            if let n = Int(path.dropFirst("/grid/opacity/".count)) { gridOpacity = Double(min(100, max(5, n))) / 100 }
        // ── Frame guides (phone) ──
        case path.hasPrefix("/guide/add/"):
            if let i = Int(path.dropFirst("/guide/add/".count)), Self.frameGuidePresets.indices.contains(i) {
                var g = FrameGuide(); g.ratioName = Self.frameGuidePresets[i].name
                frameGuideList.append(g); guidesVisible = true
            }
        case path.hasPrefix("/guide/remove/"):
            let id = String(path.dropFirst("/guide/remove/".count))
            frameGuideList.removeAll { $0.id.uuidString == id }
        case path.hasPrefix("/guide/toggle/"):
            let id = String(path.dropFirst("/guide/toggle/".count))
            if let i = frameGuideList.firstIndex(where: { $0.id.uuidString == id }) { frameGuideList[i].enabled.toggle() }
        case path.hasPrefix("/guide/scale/"):
            let parts = path.dropFirst("/guide/scale/".count).split(separator: "/")
            if parts.count == 2, let i = frameGuideList.firstIndex(where: { $0.id.uuidString == String(parts[0]) }),
               let pct = Int(parts[1]) {
                frameGuideList[i].scale = Double(min(100, max(20, pct))) / 100
            }
        default:
            appendLog("remote: unknown \(path)")
            return RemoteResponse(status: 404, body: "unknown endpoint")
        }
        appendLog("remote: \(path)")
        return RemoteResponse()
    }

    private func remoteStatusJSON() -> String {
        func stateName(_ s: CineSlot.State) -> String {
            switch s {
            case .live: return "live"
            case .empty: return "empty"
            case .ready: return "ready"
            case .waitTrigger: return "waitTrigger"
            case .postTrigger: return "postTrigger"
            case .stored: return "stored"
            }
        }
        var dict: [String: Any] = [
            "connected": connected,
            "title": cameraTitle,
            "status": statusLine,
            "camTemp": cameraTemp,
            "snsTemp": sensorTemp,
            "mode": mode.rawValue,
            "selected": selectedCine,
            "autosave": autoSaveTriggered,
            "queued": queuedDownloads,
            "downloadStatus": downloadStatus,
            "rate": frameRate,
            "res": "\(resWidth)×\(resHeight)",
            "resW": resWidth, "resH": resHeight,
            "shutter": Int(shutterAngle.rounded()),
            "resOptions": resolutionPresets.map { ["w": $0.w, "h": $0.h, "label": "\($0.w)×\($0.h) \(Self.aspectLabel($0.w, $0.h))"] },
            "maxFps": estimatedMaxFPS(width: resWidth, height: resHeight),
            "presets": presets.map(\.name),
            "cines": cines.map { ["id": $0.id, "label": $0.label, "state": stateName($0.state),
                                  "firstFrame": $0.firstFrame, "lastFrame": $0.lastFrame,
                                  "saved": savedCines.contains($0.id)] },
            "recording": recordingCine ?? NSNull(),
            "recordingActive": activeRecordingCine ?? NSNull(),
            "partitionCount": partitionCount,
            // Smart save destination + trigger position, for the phone UI.
            "magPresent": magPresent,
            "postTrigger": postTriggerFrames,
            "capacity": capacityFrames,
            // Playback / scrubbing state for the PLAY tab
            "inPoint": Int(inPoint), "outPoint": Int(outPoint),
            "playFrame": Int(playFrame), "isPlaying": isPlaying,
            "autoPlay": autoPlayEnabled, "autoPlayFrame": autoPlayStartFrame,
            "flicker": monitor.tools.flickerMap,
            "sdiLive": sdi.isRunning,
            "mon": [
                "fc": monitor.tools.falseColor, "fcMode": monitor.tools.falseColorMode,
                "peak": monitor.tools.peaking, "zebra": monitor.tools.zebra,
                "hist": monitor.showHistogram, "wave": monitor.showWaveform, "vec": monitor.showVectorscope,
                "grid": showGrid, "guides": guidesVisible,
                "invert": monitor.tools.invert, "fliph": monitor.tools.flipH, "flipv": monitor.tools.flipV,
                "rotate": monitor.tools.rotate,
            ],
            "overlay": [
                "has": overlayImage != nil, "on": overlayEnabled, "name": overlayName,
                "opacity": Int((overlayOpacity * 100).rounded()), "blink": overlayBlinkSpeed,
                "shots": screenshotURLs().map { $0.lastPathComponent },
            ],
            "grid": ["on": showGrid, "div": gridDivisions, "crosshair": gridCrosshair,
                     "opacity": Int((gridOpacity * 100).rounded())],
            "guidePresets": CameraModel.frameGuidePresets.map { $0.name },
            "guides": frameGuideList.map { ["id": $0.id.uuidString, "ratio": $0.ratioName,
                                            "on": $0.enabled, "scale": Int(($0.scale * 100).rounded())] },
            "flickerScanning": flickerScanning,
            "flickerHz": flicker.reading.frequencyHz,
            "flickerAmp": flicker.reading.amplitudePct,
            "flickerBanding": flicker.reading.bandingPct,
            "flickerBandingOn": flicker.reading.banding,
            "flickerOn": flicker.reading.flickering,
            "flickerAdvice": flickerAdvice,
            "flickerShutter": flickerSafeShutter ?? 0,
        ]
        // Selected clip's frame range, so the scrubber knows its span.
        if let sel = cines.first(where: { $0.id == selectedCine }) {
            dict["firstFrame"] = sel.firstFrame
            dict["lastFrame"] = sel.lastFrame
        }
        if let p = downloadProgress { dict["downloadProgress"] = p }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // Cache so repeated phone polls of the same frame don't re-encode.
    private var lastJPEGSource: CGImage?
    private var lastJPEGData: Data?
    private var lastOverlaySig = 0

    /// The frame currently on the in-app monitor, as a small JPEG for the phone
    /// preview — same as the external Video Out: the processed image with the
    /// onion-skin overlay, frame guides and grid baked in (the phone mirrors the
    /// monitor, not the raw SDI). Falls back to the Ethernet/playback viewer image.
    func currentViewerJPEG(maxWidth: Int = 720, quality: CGFloat = 0.5) -> Data? {
        let source: CGImage? = (viewerSource == .sdi && sdi.isRunning)
            ? (monitor.processedImage ?? viewerImage)
            : viewerImage
        guard let cg = source else { return nil }
        let sig = monitorOverlaySignature()
        if cg === lastJPEGSource, sig == lastOverlaySig, let cached = lastJPEGData { return cached }

        let scale = min(1.0, CGFloat(maxWidth) / CGFloat(cg.width))
        let w = max(1, Int(CGFloat(cg.width) * scale))
        let h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawMonitorOverlays(in: ctx, size: CGSize(width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        lastJPEGSource = cg; lastOverlaySig = sig
        lastJPEGData = out as Data
        return out as Data
    }

    /// Changes whenever a baked overlay changes, so the JPEG cache re-renders even
    /// when the underlying frame is static (e.g. paused, or the blink phase flips).
    private func monitorOverlaySignature() -> Int {
        var h = Hasher()
        h.combine(showGrid); h.combine(gridDivisions); h.combine(gridCrosshair)
        h.combine(gridColorName); h.combine(gridOpacity)
        h.combine(guidesVisible); h.combine(frameGuideList.count)
        for g in frameGuideList {
            h.combine(g.enabled); h.combine(g.ratioName); h.combine(g.scale)
            h.combine(g.offsetX); h.combine(g.offsetY); h.combine(g.colorName)
            h.combine(g.lineOpacity); h.combine(g.dimOutside)
        }
        h.combine(overlayEnabled); h.combine(overlayName); h.combine(effectiveOverlayOpacity)
        return h.finalize()
    }

    private static func aspectFit(srcW: CGFloat, srcH: CGFloat, in b: CGRect) -> CGRect {
        guard srcW > 0, srcH > 0 else { return b }
        let s = min(b.width / srcW, b.height / srcH)
        let w = srcW * s, h = srcH * s
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    /// Bakes the onion-skin overlay, frame guides and grid into a phone-feed JPEG
    /// context (native CG coords; Y is flipped vs the SwiftUI overlay).
    private func drawMonitorOverlays(in ctx: CGContext, size: CGSize) {
        let W = size.width, H = size.height
        if overlayEnabled, let ov = overlayImage {
            let op = effectiveOverlayOpacity
            if op > 0.001 {
                let r = Self.aspectFit(srcW: CGFloat(ov.width), srcH: CGFloat(ov.height),
                                       in: CGRect(x: 0, y: 0, width: W, height: H))
                ctx.saveGState(); ctx.setAlpha(CGFloat(op)); ctx.draw(ov, in: r); ctx.restoreGState()
            }
        }
        if guidesVisible {
            for g in frameGuideList where g.enabled {
                let ratio = CGFloat(g.ratio)
                var gw = W, gh = H
                if ratio > W / H { gh = gw / ratio } else { gw = gh * ratio }
                gw *= CGFloat(g.scale); gh *= CGFloat(g.scale)
                let cx = W / 2 + CGFloat(g.offsetX) * W
                let cy = H / 2 - CGFloat(g.offsetY) * H        // flip Y (CG is bottom-up)
                let r = CGRect(x: cx - gw / 2, y: cy - gh / 2, width: gw, height: gh)
                if g.dimOutside > 0.01 {
                    ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(g.dimOutside)))
                    ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H)); ctx.addRect(r)
                    ctx.fillPath(using: .evenOdd)
                }
                ctx.setStrokeColor(NSColor(g.color).withAlphaComponent(CGFloat(g.lineOpacity)).cgColor)
                ctx.setLineWidth(max(2, W / 360)); ctx.stroke(r)
            }
        }
        if showGrid {
            let n = max(gridDivisions, 1)
            ctx.setStrokeColor(NSColor(gridColor).withAlphaComponent(CGFloat(gridOpacity)).cgColor)
            ctx.setLineWidth(max(1, W / 720)); ctx.beginPath()
            if n > 1 {
                for i in 1..<n {
                    let fx = W * CGFloat(i) / CGFloat(n), fy = H * CGFloat(i) / CGFloat(n)
                    ctx.move(to: CGPoint(x: fx, y: 0)); ctx.addLine(to: CGPoint(x: fx, y: H))
                    ctx.move(to: CGPoint(x: 0, y: fy)); ctx.addLine(to: CGPoint(x: W, y: fy))
                }
            }
            if gridCrosshair {
                let cx = W / 2, cy = H / 2, a = max(10, W / 45)
                ctx.move(to: CGPoint(x: cx - a, y: cy)); ctx.addLine(to: CGPoint(x: cx + a, y: cy))
                ctx.move(to: CGPoint(x: cx, y: cy - a)); ctx.addLine(to: CGPoint(x: cx, y: cy + a))
            }
            ctx.strokePath()
        }
    }

    // Image tuning (Ethernet viewer only — the raw preview has no camera
    // picture processing, so these give it a proper look).
    @Published var wbRed: Double = 1.0
    @Published var wbBlue: Double = 1.0
    @Published var gain: Double = 1.3
    @Published var previewBlack: Double = 0.05    // input level mapped to black
    @Published var previewWhite: Double = 1.0     // input level mapped to white
    @Published var previewContrast: Double = 1.12 // S-curve strength (1 = flat)
    // Neutral by default — the Ethernet feed prioritizes COLOUR ACCURACY, so no
    // saturation boost that would misrepresent the camera's colour. Bump only
    // if you want a punchier look for framing.
    @Published var previewSaturation: Double = 1.0

    /// Match SDI (EXPERIMENTAL, default OFF): develop the raw with the camera's
    /// own video.adj pipeline (per-channel WB gains in linear, then camera gamma).
    /// Packet capture of a live SDI session on this Flex proved these ARE the raw
    /// develop: PCC applies video.adj.red≈2.01× / blue≈1.68× / gamma 2.22 (matrix,
    /// flare and pedestals all 0) to raw that is bit-for-bit identical to ours, and
    /// gets its SDI colour. (The raw is green-dominant, so the gains BOOST R/B to
    /// neutral — my earlier "green runs low → double-corrects" read was backwards.)
    /// Remaining gap on the LIVE feed: faint sensor fixed-pattern banding, because
    /// the camera's black calibration (CSR) isn't applied to the live raw stream.
    @Published var matchSDI = false
    // Camera SDI colour params, queried live (video.adj, 1024 = 1.0). Defaults are
    // this Flex's measured values until the camera is read on connect.
    @Published var camWbRed: Double = 2.01
    @Published var camWbBlue: Double = 1.68
    @Published var camGamma: Double = 2.2
    @Published var camSat: Double = 1.0
    @Published var camBlack: Double = 0.02

    // MARK: - Image Tools (develop panel) — generic video.adj layer
    // A PCC-style develop panel that writes any video.adj.<key> live. Values are HUMAN
    // units; encode/decode handle the per-body scaling (float on Flex 4K/VEO, ×1024 on
    // the PH16 Flex 2K). Presence-gated so each body shows only the controls it reports.
    @Published var adj: [String: Double] = [:]     // key → human value
    @Published var adjPresent: Set<String> = []    // keys this body actually reports (gating)
    @Published var adjIsFloat = true               // false = ×1024 fixed-point body (PH16 Flex 2K)
    private var adjSendPending: Set<String> = []

    private func encodeAdj(_ c: AdjControl, _ human: Double) -> String {
        switch c.kind {
        case .passthru: return String(Int(human.rounded()))
        case .scaled:   return adjIsFloat ? String(format: "%.4f", human)
                                          : String(Int((human * 1024).rounded()))
        }
    }

    /// Set a develop control (human units). Mirrors the UI + Match-SDI preview at once and
    /// COALESCES the 7115 write to ~12/sec per key, so dragging a slider never floods the
    /// control channel. The final value is always sent (the trailing send reads adj[key]).
    func setAdjust(_ key: String, _ human: Double) {
        guard let c = ImageAdjust.byKey[key] else { return }
        let v = min(c.max, max(c.min, human))
        adj[key] = v
        mirrorSharedAdj(key, v)
        guard adjSendPending.insert(key).inserted else { return }   // a send is already scheduled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.adjSendPending.remove(key)
            guard let cc = ImageAdjust.byKey[key], let val = self.adj[key] else { return }
            self.sendSimple("set video.adj.\(key) \(self.encodeAdj(cc, val))", label: "adj.\(key) → \(val)")
        }
    }

    func resetAdjust(_ key: String) {
        if let c = ImageAdjust.byKey[key] { setAdjust(key, c.neutral) }
    }
    func resetAdjGroup(_ g: AdjControl.Group) {
        for c in ImageAdjust.controls where c.group == g && adjPresent.contains(c.key) {
            setAdjust(c.key, c.neutral)
        }
    }
    func resetAllAdjust() { AdjControl.Group.allCases.forEach(resetAdjGroup) }
    func hasAdj(_ key: String) -> Bool { adjPresent.contains(key) }
    func groupPresent(_ g: AdjControl.Group) -> Bool {
        ImageAdjust.controls.contains { $0.group == g && adjPresent.contains($0.key) }
    }
    func adjBinding(_ key: String) -> Binding<Double> {
        Binding(get: { self.adj[key] ?? (ImageAdjust.byKey[key]?.neutral ?? 0) },
                set: { self.setAdjust(key, $0) })
    }

    /// Keep the Ethernet Match-SDI preview in step with a develop change (gamma/sat feed
    /// the debayer; the camera's own SDI updates instantly regardless). Other keys are
    /// applied by the camera to SDI only until the debayer honors them (later phase).
    private func mirrorSharedAdj(_ key: String, _ v: Double) {
        switch key {
        case "gamma": camGamma = min(3, max(1, v))
        case "sat":   camSat   = min(2, max(0, v))
        default: break
        }
    }

    @Published var log: [String] = []

    // Download
    @Published var downloadProgress: Double?   // nil = idle, 0...1 while running
    @Published var downloadStatus = ""

    /// Set once the user picks a viewer source by hand. The launch retry loop
    /// auto-switches to SDI when a capture box enumerates late, which must not
    /// override a deliberate choice — otherwise switching to Ethernet (which
    /// now releases the capture device) gets undone a few seconds later and the
    /// card is silently re-claimed.
    @Published var viewerSourceUserSet = false

    /// Whether the 10G raw-ethernet download path can actually run right now —
    /// which interface is on the camera's subnet, what speed it negotiated, and
    /// whether `/dev/bpf*` is reachable. BOTH have to be true, and until now
    /// both failed silently: the app would fall back to the ~7 MB/s TCP loop and
    /// say nothing, so a tester saw only a mysteriously slow download.
    @Published var tenGigStatus: XimgReceiver.TenGigStatus?

    /// Cheap (one bpf open/close + a getifaddrs walk). Call on connect, on the
    /// Save tab appearing, or from the Re-check button.
    func refreshTenGigStatus() {
        guard !host.isEmpty else { tenGigStatus = nil; return }
        let s = XimgReceiver.preflight(cameraIP: host)
        tenGigStatus = s
        NSLog("[10G] %@", s.summary)
    }
    /// Camera-side ximg pacing, percent of 10G line rate (~11.5 MB/s per 1%).
    /// 100 = full blast (~640 MB/s). Lower it if downloads report packet loss.
    /// Only affects the 10G raw-ethernet fast path; TCP ignores it.
    @Published var downloadThrottle: Double = 100

    /// Pixel PACKING for downloaded .cine files — how the RAW sensor data is stored.
    /// None of these reduce quality below the camera's native bit depth; they trade
    /// file size and download speed. `.auto` picks the fastest COMPLETE format for the
    /// link (10-bit packed over 10G, full 12-bit over 1G). `.packed10` forces the
    /// compact companded 10-bit (P10 — the camera's native CineMag/10G format; needs a
    /// 10G link, else falls back to Auto). `.wide12` forces the uncompressed full 12-bit
    /// (in a 16-bit file) over the standard path.
    enum DownloadPacking: String, CaseIterable, Identifiable {
        case auto, packed10, wide12
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:     return "Auto (recommended)"
            case .packed10: return "10-bit packed (P10)"
            case .wide12:   return "12-bit (16-bit file)"
            }
        }
    }
    @Published var downloadPacking: DownloadPacking =
        DownloadPacking(rawValue: UserDefaults.standard.string(forKey: "downloadPacking") ?? "auto") ?? .auto {
        didSet { UserDefaults.standard.set(downloadPacking.rawValue, forKey: "downloadPacking") }
    }
    private var downloadCancelled = false

    // Naming & destination (persisted between launches)
    @Published var projectName: String = UserDefaults.standard.string(forKey: "projectName") ?? "" {
        didSet { UserDefaults.standard.set(projectName, forKey: "projectName") }
    }
    @Published var shotName: String = ""
    @Published var saveFolderPath: String = UserDefaults.standard.string(forKey: "saveFolder")
        ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path {
        didSet { UserDefaults.standard.set(saveFolderPath, forKey: "saveFolder") }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path
        }
    }

    private static func sanitize(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned
    }

    /// Builds Project-folder/ShotName.ext, creating directories and avoiding
    /// overwrites by appending _2, _3…
    func destinationURL(defaultBase: String, ext: String) -> URL {
        var dir = URL(fileURLWithPath: saveFolderPath)
        let proj = Self.sanitize(projectName)
        if !proj.isEmpty {
            dir.appendPathComponent(proj)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shot = Self.sanitize(shotName)
        let base = shot.isEmpty ? defaultBase : shot
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    // CineMag
    struct MagTake: Identifiable {
        let id: Int
        var width = 0, height = 0, rate = 0, frames = 0
        var firstFrame = 0, lastFrame = 0
        var name = ""
        // Header metadata read from the whole `get fc<i>` struct (when the
        // firmware reports it): precise fps, playback fps, exposure and the
        // time the take was shot.
        var rateDouble: Double = 0      // precise recording fps (rate is the rounded Int)
        var playbackFPS: Double = 0     // intended playback fps (e.g. 24)
        var exposureNs: Int = 0         // exposure time, nanoseconds
        var triggerSecs: UInt32 = 0     // when it was shot (epoch seconds); 0 = unknown

        /// PVP convention: flash takes are "1F", "2F", …
        var label: String { "\(id + 1)F" }

        var fps: Double { rateDouble > 0 ? rateDouble : Double(rate) }
        /// When the take was shot, if the camera reported it.
        var shotDate: Date? { triggerSecs > 0 ? Date(timeIntervalSince1970: Double(triggerSecs)) : nil }
        /// Shutter angle from exposure × rate (same formula as the .cine sidecar).
        var shutterAngle: Double? {
            guard exposureNs > 0, fps > 0 else { return nil }
            let a = Double(exposureNs) * fps * 360 / 1e9
            return (a > 0 && a <= 360.5) ? a : nil
        }
        /// Real-time length of the captured event (frames at the capture rate) —
        /// e.g. a 5477-frame 1456 fps take is a 3.8 s grab.
        var durationSeconds: Double { fps > 0 ? Double(frames) / fps : 0 }

        private static let shotFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · h:mm a"; return f
        }()

        /// Primary line: resolution · fps · frames · shutter (or the clip name).
        var detail: String {
            var parts: [String] = []
            if width > 0 { parts.append("\(width)×\(height)") }
            if fps > 0 { parts.append(String(format: "%g fps", fps)) }
            if frames > 0 { parts.append("\(frames) fr") }
            if let a = shutterAngle { parts.append(String(format: "%.0f°", a)) }
            let base = parts.isEmpty ? "take \(label)" : parts.joined(separator: "  ·  ")
            return name.isEmpty ? base : "\(name)  —  \(base)"
        }
        /// Secondary line: duration and the date/time it was shot (when known).
        var subline: String {
            var parts: [String] = []
            if durationSeconds > 0 { parts.append(String(format: "%.2fs", durationSeconds)) }
            if let d = shotDate { parts.append(MagTake.shotFormatter.string(from: d)) }
            return parts.joined(separator: "  ·  ")
        }
    }
    @Published var magTakes: [MagTake] = []
    @Published var magInfo = ""
    /// Capacity for the mag manager's fill bar (bytes are the camera's kB-ish
    /// units; only the ratio is displayed).
    @Published var magUsed: Double = 0
    @Published var magSize: Double = 0

    let sdi = SDICaptureManager()
    /// Reusable low-latency H.264 LAN streamer (own port + threads). Started by
    /// startRemote(); SDI frames are submitted to it.
    private var stream: VideoStreamServer?
    static let streamPort: UInt16 = 8990
    /// LAN stream quality (H.264 Mbps). Defaults to max — rarely touched.
    @Published var streamBitrateMbps: Double = 25 {
        didSet { stream?.setBitrate(Int(streamBitrateMbps * 1_000_000)) }
    }
    let monitor = SDIProcessor()
    let flicker = FlickerDetector()
    private var sdiObserver: AnyCancellable?
    private var monitorObserver: AnyCancellable?
    private var flickerObserver: AnyCancellable?

    /// Shutter angles that make the exposure span a whole number of flicker
    /// cycles (exposure = k / f), so each frame integrates the flicker away.
    /// Works for PWM LEDs as well as mains — it uses the measured frequency, not
    /// an assumed 50/60 Hz. Returns rounded angles in 1…358°, largest first.
    var flickerSafeShutters: [Double] {
        let f = flicker.reading.frequencyHz
        guard flicker.reading.flickering, f > 1 else { return [] }
        let rate = Double(max(frameRate, 1))
        var out: [Double] = []
        for k in 1...12 {
            let angle = 360.0 * Double(k) / f * rate     // = 360·k·rate/f
            if angle >= 5 && angle <= 358 { out.append((angle * 10).rounded() / 10) }
        }
        return out.sorted(by: >)
    }

    /// The single best anti-flicker shutter to offer for one-tap apply — the
    /// largest valid angle (keeps the most exposure / fewest stops lost).
    var flickerSafeShutter: Double? { flickerSafeShutters.first }

    /// Sets the shutter to the suggested anti-flicker angle and pushes it.
    func applyFlickerShutter() {
        guard let a = flickerSafeShutter else { return }
        shutterAngle = a
        applySettings()
    }

    /// Plain-English flicker advice with concrete shutter angles to dial in.
    var flickerAdvice: String {
        let r = flicker.reading
        let f = r.frequencyHz
        guard r.flickering else { return "" }

        // Rolling LED banding — the per-row residual found bands travelling
        // through the frame (the classic dimmed-PWM-LED look). This often shows
        // up even when the whole-frame brightness barely changes.
        let bandNote = r.banding
            ? String(format: " Rolling LED banding %.0f%%: raise the light's PWM/flicker-free frequency, or set its dimmer to 100%% and cut level with ND/aperture — dimming is what creates the bands. A longer shutter reduces them but won't fully remove rolling bands.", r.bandingPct)
            : ""

        // No usable temporal frequency (banding-only, or too fast to measure).
        guard f > 1 else {
            if r.banding {
                return "Banding detected (no steady whole-frame frequency)." + bandNote
            }
            return ""
        }
        let nearMains = abs(f - 50) < 4 || abs(f - 60) < 4
                     || abs(f - 100) < 6 || abs(f - 120) < 6
        let src = nearMains ? "mains/ballast" : "PWM/LED"
        let angles = flickerSafeShutters
        if !angles.isEmpty {
            let list = angles.prefix(3).map { String(format: "%.1f°", $0) }.joined(separator: " / ")
            return String(format: "Flicker ~%.0f Hz (%@). Shutter %@ integrates whole cycles.", f, src, list) + bandNote
        }
        // Frame rate is faster than the flicker, so no shutter spans a full cycle.
        // A frame rate that divides the flicker frequency captures the same phase
        // each frame (f = m × rate). Suggest the practical ones.
        var rates: [Int] = []
        for m in 1...20 {
            let rr = Int((f / Double(m)).rounded())
            if rr >= 24, !rates.contains(rr) { rates.append(rr) }
        }
        if rates.isEmpty {
            return String(format: "Flicker ~%.0f Hz (%@) — slower than normal frame rates. Use a flicker-free light or shoot below %.0f fps.", f, src, f) + bandNote
        }
        let list = rates.prefix(4).map(String.init).joined(separator: " / ")
        return String(format: "Flicker ~%.0f Hz (%@). At %d fps no shutter spans a cycle — shoot at %@ fps (whole cycles per frame).",
                      f, src, frameRate, list) + bandNote
    }

    func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.prompt = "Load LUT"
        if panel.runModal() == .OK, let url = panel.url {
            monitor.loadLUT(from: url)
        }
    }

    private var conn: CameraConnection?
    private var cineMem = 0   // total cine memory units from `get info` (e.g. 32097 on Flex 32GB)
    private(set) var xInc = 256   // width must be a multiple of this (Flex: 256)
    private(set) var yInc = 4     // height step
    private(set) var xMax = 2560
    private(set) var yMax = 1600
    private let camQueue = DispatchQueue(label: "phantom.camera", qos: .userInitiated)
    private var liveLoopGeneration = 0
    private var pollTimer: Timer?
    private var playTask: Task<Void, Never>?
    private var applyDebounce: Task<Void, Never>?
    private var lastRawFrame: PhantomFrame?
    private var consecutiveErrors = 0
    private var reconnectTimer: Timer?
    /// True while UI fields are being filled FROM the camera, so auto-apply
    /// doesn't echo the values straight back.
    private var loadingFromCamera = false

    init() {
        // Surface SDI manager state changes through this model so the UI updates.
        sdiObserver = sdi.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        monitorObserver = monitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        flickerObserver = flicker.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        monitor.attach(to: sdi.session)
        // Proof-of-life: tell the capture manager frames are genuinely arriving,
        // so "SDI live" means a picture rather than merely an open session.
        monitor.onFrameArrived = { [weak self] w, h, fmt in
            self?.sdi.noteFrameArrived(width: w, height: h, pixelFormat: fmt)
        }
        // SDI frames feed the flicker meter when SDI is the viewer.
        monitor.onFlickerSample = { [weak self] luma in
            Task { @MainActor in
                guard let self, self.viewerSource == .sdi else { return }
                self.flicker.sampleRateHz = 60   // SDI output rate
                self.flicker.push(meanLuma: luma)
            }
        }
        // Rolling-band detection (PWM LEDs) from the per-row profile.
        monitor.onBandingSample = { [weak self] profile in
            Task { @MainActor in
                guard let self, self.viewerSource == .sdi else { return }
                self.flicker.pushBanding(profile: profile)
            }
        }
        // Low-latency H.264 LAN feed — the module encodes only while a phone/iPad
        // is connected and fans out on its own threads.
        monitor.onStreamFrame = { [weak self] pb, pts in
            self?.stream?.submit(pb, pts: pts)
        }
        // 3-second Sample & Analyze progress / result.
        monitor.onFlickerSampleProgress = { [weak self] p in
            Task { @MainActor in self?.flickerSampleProgress = p }
        }
        monitor.onFlickerSampleDone = { [weak self] summary in
            Task { @MainActor in
                self?.flickerSampleProgress = nil
                self?.flickerSampleSummary = summary
            }
        }
    }

    // MARK: Flicker Sample & Analyze (3 s of live SDI)
    @Published var flickerSampleProgress: Double?   // 0…1 while capturing, nil otherwise
    @Published var flickerSampleSummary = ""

    /// Captures ~3 s of the live SDI feed and analyzes it for flicker + banding,
    /// freezing a red map of exactly where it is. SDI only — the live feed is the
    /// source here.
    func sampleFlickerLive() {
        guard viewerSource == .sdi, sdi.isRunning else {
            flickerSampleSummary = "Switch the viewer to SDI (and start it) to sample the live feed."
            return
        }
        guard flickerSampleProgress == nil else { return }   // already running
        // Turn the tool on so the frozen result is visible when it lands.
        flicker.enabled = true
        monitor.tools.flickerMap = true
        monitor.sampleFlicker = true
        flickerSampleSummary = ""
        flickerSampleProgress = 0
        monitor.startFlickerSample(frames: 90)   // ~3 s at 30 fps
    }

    /// Clears a frozen sample result and returns the overlay to live mode.
    func clearFlickerSample() {
        monitor.clearFlickerSample()
        flickerSampleSummary = ""
        flickerSampleProgress = nil
    }

    // MARK: - Connection

    /// All Phantoms answering discovery — lets the user switch between
    /// cameras (e.g. Flex vs VEO4K) without typing IPs.
    @Published var discoveredCameras: [DiscoveredCamera] = []

    /// IPs of cameras Daniel uses — probed directly so cameras on subnets UDP
    /// broadcast can't reach (Flex 100.100.x + VEO 172.16.x) both show up.
    /// Editable + persisted; seeded with the two known Phantoms.
    @Published var knownCameraIPs: [String] = {
        if let saved = UserDefaults.standard.stringArray(forKey: "knownCameraIPs") { return saved }
        return ["100.100.111.76", "172.16.36.248"]
    }() {
        didSet { UserDefaults.standard.set(knownCameraIPs, forKey: "knownCameraIPs") }
    }

    func discoverAndConnect() {
        statusLine = "Searching (broadcast + known IPs)…"
        let known = knownCameraIPs
        camQueue.async { [weak self] in
            // UDP broadcast for this subnet + direct probe of every known IP
            // (covers other subnets). Merge, de-dup by host.
            var byHost: [String: DiscoveredCamera] = [:]
            for c in CameraConnection.discover() { byHost[c.host] = c }
            for c in CameraConnection.probe(hosts: known) where byHost[c.host] == nil { byHost[c.host] = c }
            // Don't let the main camera slot grab a CineStation — it's a separate
            // device handled by its own window/model. Skip its known addresses.
            let cams = Array(byHost.values).filter { !CineStationModel.knownHosts.contains($0.host) }
            Task { @MainActor in
                guard let self else { return }
                self.discoveredCameras = cams.sorted { $0.host < $1.host }
                if let cam = cams.first(where: { $0.host == self.host }) ?? cams.first {
                    self.host = cam.host
                    self.connect()
                } else {
                    self.statusLine = "No cameras found (broadcast + \(known.count) known IPs)"
                }
            }
        }
    }

    func switchCamera(to cam: DiscoveredCamera) {
        guard cam.host != host || !connected else { return }
        disconnect()
        host = cam.host
        connect()
    }

    /// True when no local interface shares the camera host's /16 subnet — i.e.
    /// the Mac can't reach it without a network address on that subnet.
    func needsNetworkSetup(for host: String) -> Bool {
        let octs = host.split(separator: ".").compactMap { Int($0) }
        guard octs.count == 4 else { return false }
        // A Mac interface claiming the camera's OWN address is a conflict —
        // the camera becomes unreachable even though the subnet "matches".
        if Self.interfaceOwning(ip: host) != nil { return true }
        let camPrefix = "\(octs[0]).\(octs[1])."
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return false }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host6 = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host6, socklen_t(host6.count), nil, 0, NI_NUMERICHOST) == 0 {
                if String(cString: host6).hasPrefix(camPrefix) { return false }  // already reachable
            }
        }
        return true
    }

    /// True when a Mac interface holds EXACTLY the camera's IP (address theft —
    /// usually a leftover manual config). Drives the "Fix Address Conflict" UI.
    func hasAddressConflict(for host: String) -> Bool {
        Self.interfaceOwning(ip: host) != nil
    }

    /// The en-interface whose IPv4 equals `ip`, if any.
    static func interfaceOwning(ip: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (p.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host6 = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host6, socklen_t(host6.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: host6) == ip {
                return String(cString: p.pointee.ifa_name)
            }
        }
        return nil
    }

    /// macOS network SERVICE name (System Settings entry) for a BSD device
    /// like "en25" — needed by `networksetup -setmanual`. No admin required.
    static func serviceName(forDevice device: String) -> String? {
        let p = Process()
        p.launchPath = "/usr/sbin/networksetup"
        p.arguments = ["-listnetworkserviceorder"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        var lastService: String?
        for line in out.split(separator: "\n") {
            let l = String(line)
            if let m = l.range(of: #"^\(\d+\) "#, options: .regularExpression) {
                lastService = String(l[m.upperBound...])
            } else if l.contains("Device: \(device))"), let svc = lastService {
                return svc
            }
        }
        return nil
    }

    /// Auto-configures the Mac's adapter to reach the camera — the macOS analog
    /// of PCC's "auto-configure network adapter". One admin password prompt.
    /// Two cases:
    ///  1. ADDRESS CONFLICT — an interface holds the camera's OWN IP (leftover
    ///     manual config). Fix it persistently via `networksetup -setmanual`
    ///     with a proper neighbor address (camera .76 → Mac .74).
    ///  2. NO ROUTE — no interface on the camera's subnet: add an alias IP on
    ///     the active wired interface (non-destructive; existing DHCP/other
    ///     config untouched).
    func configureNetwork(for host: String) {
        let octs = host.split(separator: ".").compactMap { Int($0) }
        guard octs.count == 4 else { return }
        let script: String, prompt: String, logLine: String
        if let dev = Self.interfaceOwning(ip: host), let svc = Self.serviceName(forDevice: dev) {
            // Conflict: Mac and camera share the address. Give the Mac its own.
            let fixIP = "\(octs[0]).\(octs[1]).\(octs[2]).\(octs[3] == 74 ? 75 : 74)"
            script = "networksetup -setmanual \\\"\(svc)\\\" \(fixIP) 255.255.0.0"
            prompt = "Your Mac's adapter is using the CAMERA's own address (\(host)) — they conflict, so the camera can't be reached. Phantom Control will change the Mac to \(fixIP)."
            logLine = "network: fixed conflict on \(dev) (\(svc)) → \(fixIP)"
        } else {
            let aliasIP = "\(octs[0]).\(octs[1]).\(octs[2]).\(octs[3] == 250 ? 251 : 250)"
            // Pick the active wired interface (prefer 10G, never Wi‑Fi en0).
            let iface = Self.activeWiredInterface() ?? "en11"
            script = "ifconfig \(iface) alias \(aliasIP) netmask 255.255.0.0"
            prompt = "Phantom Control wants to add a network address (\(aliasIP)) so it can reach the camera at \(host)."
            logLine = "network: added \(aliasIP) on \(iface) for \(host)"
        }
        let osa = "do shell script \"\(script)\" with administrator privileges with prompt \"\(prompt)\""
        statusLine = "Setting up network for \(host) — enter your Mac password…"
        camQueue.async { [weak self] in
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", osa]
            try? p.run(); p.waitUntilExit()
            let ok = p.terminationStatus == 0
            Task { @MainActor in self?.statusLine = ok ? "Network configured — rescanning…"
                                                       : "Network setup cancelled" }
            // Give the interface a beat to re-bind before rescanning.
            Thread.sleep(forTimeInterval: 2.0)
            Task { @MainActor in
                self?.appendLog(logLine)
                if ok { self?.discoverAndConnect() }
            }
        }
    }

    static func activeWiredInterface() -> String? {
        // en interfaces that are up, not loopback, not Wi‑Fi (en0); prefer higher index (usually the dock/10G).
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var candidates: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en"), name != "en0",
                  (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            if !candidates.contains(name) { candidates.append(name) }
        }
        return candidates.sorted().last
    }

    // Telemetry shown in the status bar (refreshed by the poll loop).
    @Published var cameraTemp: Int = 0
    @Published var sensorTemp: Int = 0

    /// Whether a CineMag is mounted (size 0 = none). Drives the mag-save UI.
    var magPresent: Bool { magSize > 0 }

    // MARK: - EI / ISO
    // EI = baseei × (video.adj.gain / 1024). The develop gain rides along as
    // take metadata (adj.gain in saved cines); the raw sensor data stays raw —
    // same mechanism as the camera's own EI menu (verified by state diff).
    @Published var baseEI = 0            // camera-native EI (info.baseei); 0 = unsupported
    @Published var videoGain = 1024      // current video.adj.gain (1024 = 1×)

    /// Standard photographic 1/3-stop EI/ISO ladder — so the menu offers proper
    /// thirds (…1250, 1600, 2000, 2500…) instead of only full-stop doublings.
    static let standardEILadder = [
        50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
        1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
        16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400,
    ]

    var currentEI: Int {
        guard baseEI > 0 else { return 0 }
        let raw = baseEI * videoGain / 1024
        // Snap to the nearest standard 1/3-stop so the readout matches a menu
        // entry — integer gain rounding can land EI at e.g. 1599 not 1600.
        return Self.standardEILadder.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
    }

    /// Native EI plus every standard 1/3-stop up to +4 stops (base × 16). The Flex
    /// pulls EI as a develop gain over native, so each maps to an integer
    /// video.adj.gain via setEI.
    var eiChoices: [Int] {
        guard baseEI > 0 else { return [] }
        let maxEI = baseEI * 16
        let thirds = Self.standardEILadder.filter { $0 > baseEI && $0 <= maxEI }
        return ([baseEI] + thirds).sorted()
    }

    func setEI(_ ei: Int) {
        guard baseEI > 0, ei >= baseEI else { return }
        let gain = 1024 * ei / baseEI
        videoGain = gain
        sendSimple("set video.adj.gain \(gain)", label: "EI → \(ei) (gain \(gain))")
    }

    func refreshTelemetry() {
        runCommandAsync { conn -> (Int, Int, Double, Int) in
            let cam = PhantomProtocol.find("camtemp", in: try conn.get("info.camtemp"))?.intValue ?? 0
            let sns = PhantomProtocol.find("snstemp", in: try conn.get("info.snstemp"))?.intValue ?? 0
            // Cheap mag-presence probe so hot-swapping a mag updates the UI.
            let mag = PhantomProtocol.find("size", in: (try? conn.get("mag.size")) ?? [:])?.doubleValue ?? 0
            // Track EI changes made on the camera body's own menu.
            let gain = PhantomProtocol.find("gain", in: (try? conn.get("video.adj.gain")) ?? [:])?.intValue ?? -1
            return (cam, sns, mag, gain)
        } onResult: { [weak self] t in
            if let (cam, sns, mag, gain) = t {
                if gain > 0 { self?.videoGain = gain }
                self?.magSize = mag
                if mag == 0 {
                    self?.magTakes = []; self?.magUsed = 0
                    // Mag pulled while auto-save→mag armed: disarm, don't queue
                    // saves that can only fail.
                    if self?.autoSaveToMag == true {
                        self?.autoSaveToMag = false
                        self?.appendLog("auto-save→mag disarmed — no CineMag present")
                    }
                }
                self?.cameraTemp = cam
                self?.sensorTemp = sns
            }
        }
    }

    func connect() {
        let host = self.host
        statusLine = "Connecting to \(host)…"
        camQueue.async { [weak self] in
            let conn = CameraConnection(host: host)
            do {
                do { try conn.connect() }
                catch { Task { @MainActor in self?.appendLog("connect step FAILED at tcpConnect: \(error)") }; throw error }
                do { try conn.startDataChannel() }
                catch { Task { @MainActor in self?.appendLog("connect step FAILED at startDataChannel: \(error)") }; throw error }
                let info = try conn.get("info")
                // Capability probes — newer cameras (VEO) answer; older error out.
                let hasLog = ((try? conn.command("get video.adj.log")) ?? "").contains("log :")
                let hasDark = ((try? conn.command("get cam.dark")) ?? "").contains("dark :")
                let hasQuiet = ((try? conn.command("get cam.quiet")) ?? "").contains("quiet :")
                let hasWBTemp = ((try? conn.command("get video.adj.wbtemp")) ?? "").contains("wbtemp :")
                let hasCines = ((try? conn.command("get cam.cines")) ?? "").contains("cines :")
                // SDI/HDMI output standard: the capability list + current value.
                let vidSysList = (try? conn.command("get info.videosystems")) ?? ""
                let vidSysCur = (try? conn.command("get video.system")) ?? ""
                Task { @MainActor in
                    guard let self else { return }
                    self.conn = conn
                    self.connected = true
                    self.consecutiveErrors = 0
                    self.reconnectTimer?.invalidate()
                    self.reconnectTimer = nil
                    let model = PhantomProtocol.find("model", in: info)?.stringValue ?? "Phantom"
                    let serial = PhantomProtocol.find("serial", in: info)?.intValue ?? 0
                    self.capabilities = Set((PhantomProtocol.find("features", in: info)?.stringValue ?? "")
                        .split(separator: " ").map(String.init))
                    self.supportsLog = hasLog
                    self.supportsDark = hasDark
                    self.supportsQuiet = hasQuiet
                    self.supportsWBTemp = hasWBTemp
                    self.supportsCinesVar = hasCines
                    // Native EI (ISO) — EI = baseei × (video.adj.gain / 1024).
                    // Verified live on the Flex: the camera's own EI menu writes
                    // video.adj.gain (1024 = 1×). 0 = firmware doesn't report it.
                    self.baseEI = PhantomProtocol.find("baseei", in: info)?.intValue ?? 0
                    // Parse the camera's supported video-output standards + current.
                    let listStr = PhantomProtocol.find("videosystems",
                        in: PhantomProtocol.parse(vidSysList))?.stringValue ?? ""
                    self.availableVideoSystems = listStr.split(whereSeparator: { $0 == " " })
                        .compactMap { Int($0) }
                    self.currentVideoSystem = PhantomProtocol.find("system",
                        in: PhantomProtocol.parse(vidSysCur))?.intValue ?? 0
                    // Pick a sane SDI output ONLY if the camera's current output
                    // is unset/unknown — NEVER override a valid one, or every
                    // reconnect would stomp a DP's chosen timebase (e.g. 23.98
                    // for genlock/LockToVideo). 1080p30 (code 20) is the fallback.
                    let cur = self.currentVideoSystem
                    if (cur == 0 || !self.availableVideoSystems.contains(cur)),
                       self.availableVideoSystems.contains(20) {
                        self.setVideoSystem(20)
                    }
                    self.cineMem = PhantomProtocol.find("cinemem", in: info)?.intValue ?? 0
                    self.xInc = PhantomProtocol.find("xinc", in: info)?.intValue ?? 256
                    self.yInc = PhantomProtocol.find("yinc", in: info)?.intValue ?? 4
                    self.xMax = PhantomProtocol.find("xmax", in: info)?.intValue ?? 2560
                    self.yMax = PhantomProtocol.find("ymax", in: info)?.intValue ?? 1600
                    self.cameraTitle = "\(model)  #\(serial)"
                    self.connectFailures = 0
                    self.statusLine = "Connected to \(model) #\(serial) @ \(host)"
                    self.appendLog("connected to \(host)")
                    self.refreshAll()
                    self.refreshCameraColor()
                    self.refreshTimecode()
                    self.refreshAutoMode()
                    self.startPolling()
                    self.startLiveLoop()
                    // Jam the camera clock to time-of-day on connect, if enabled.
                    if self.syncTCOnConnect { self.syncTimecodeToTimeOfDay() }
                }
            } catch {
                conn.close()
                let detail = "\(error)"
                Task { @MainActor in
                    guard let self else { return }
                    self.connectFailures += 1
                    self.appendLog("connect failed (#\(self.connectFailures)): \(detail)")
                    // errno 65 = host unreachable. After a couple of tries, if the
                    // camera is clearly on (repeated fails), the app's connection
                    // is likely stuck — a full quit/reopen clears it.
                    if detail.contains("errno 65") && self.connectFailures >= 3 {
                        self.statusLine = "Can't reach the camera. If it's powered on, fully Quit and reopen the app (⌘Q) to clear a stuck connection."
                    } else if detail.contains("errno 65") || detail.contains("errno 64") {
                        self.statusLine = "Camera unreachable — check it's powered on and the cable/adapter is connected."
                    } else {
                        self.statusLine = "Connect failed: \(detail)"
                    }
                }
            }
        }
    }

    /// Consecutive failed connect attempts (reset on a successful connect).
    private var connectFailures = 0

    func disconnect() {
        liveLoopGeneration += 1
        pollTimer?.invalidate(); pollTimer = nil
        playTask?.cancel(); playTask = nil
        let c = conn
        conn = nil
        camQueue.async { c?.close() }
        connected = false
        statusLine = "Disconnected"
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - Status polling

    private var pollTick = 0

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCineStates()
                // The camera never announces changes (verified by packet capture
                // with no apps running) — poll settings so on-camera-control
                // changes show up here, like PCC does. Skip while the user has
                // an apply pending so we don't fight their edit.
                self.pollTick += 1
                if self.pollTick % 3 == 0, self.applyDebounce == nil {
                    self.refreshSettingsFromCamera()
                }
                if self.pollTick % 10 == 0 { self.refreshTelemetry() }
                if self.pollTick % 5 == 0 { self.checkBrefReminder() }
                // Keep the LOCKED indicator current while an external sync is engaged.
                if self.syncMode != .internalClock, self.pollTick % 4 == 0 { self.refreshGenlock() }
            }
        }
    }

    func refreshAll() {
        refreshSettingsFromCamera()
        refreshCineStates()
    }

    private func refreshSettingsFromCamera() {
        runCommandAsync { conn in
            let defc = try conn.get("defc")
            return defc
        } onResult: { [weak self] parsed in
            guard let self, let parsed else { return }
            self.loadingFromCamera = true
            defer { self.loadingFromCamera = false }
            // defc contains nested dicts (autoexp, profile, cam…) — read only
            // top-level fields, and assign only on change so the periodic
            // on-camera-sync poll doesn't churn fields being edited.
            let defc = parsed["defc"]?.dictValue ?? parsed
            if let res = defc["res"]?.sizeValue {
                if res.width != self.resWidth { self.resWidth = res.width }
                if res.height != self.resHeight { self.resHeight = res.height }
            }
            if let rate = defc["rate"]?.intValue {
                if rate != self.frameRate { self.frameRate = rate }
                // Track the camera's actual rate so applyFrameRate can tell a real
                // user change from a telemetry echo (for the black-shade reminder).
                self.committedFrameRate = rate
            }
            if let expNS = defc["exp"]?.doubleValue, self.frameRate > 0 {
                // exp is in NANOSECONDS (verified on Flex swver 797).
                let angle = min(359, max(1, (expNS / 1e9) * Double(self.frameRate) * 360.0))
                if abs(angle - self.shutterAngle) > 0.5 { self.shutterAngle = angle }
            }
            if let pt = defc["ptframes"]?.intValue, pt != self.postTriggerFrames { self.postTriggerFrames = pt }
            if let hq = defc["hqenable"]?.intValue, (hq == 1) != self.hqMode { self.hqMode = (hq == 1) }
            // Surface a live speed-ramp profile so the shutter-angle cap it imposes
            // is never a mystery (a warning chip + one-tap Clear appear when true).
            let rampOn = (defc["profile"]?.dictValue?["atrig"]?.intValue ?? 0) == 1
            if rampOn != self.rampActiveOnCamera { self.rampActiveOnCamera = rampOn }
            // Does this body even have a defc.profile? The Flex 4K doesn't (it uses
            // defc.ramp) and rejects every profile write — so gate them on this.
            let hasProfile = defc["profile"]?.dictValue != nil
            if hasProfile != self.supportsProfileRamp { self.supportsProfileRamp = hasProfile }
        }
    }

    /// Instant-apply: any UI settings change calls this; pushes after a short
    /// debounce so slider drags don't flood the camera.
    func settingsEdited() {
        guard connected, !loadingFromCamera else { return }
        applyDebounce?.cancel()
        applyDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.applySettings()
            self?.applyDebounce = nil
        }
    }

    private func refreshCineStates() {
        guard connected else { return }
        runCommandAsync { conn in
            PhantomProtocol.parse(try conn.command("cstats"))
        } onResult: { [weak self] parsed in
            guard let self, let parsed else { return }
            // Carry over known frame ranges — cstats doesn't report them, and
            // rebuilding from scratch would blank the playback timeline every
            // poll until the async range fetch catches up.
            let prev = Dictionary(self.cines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var slots: [CineSlot] = []
            var i = 0
            while let v = parsed["c\(i)"] {
                var slot = CineSlot(id: i, flags: v.flagsValue ?? [])
                if let p = prev[i] {
                    slot.frameCount = p.frameCount
                    slot.firstFrame = p.firstFrame
                    slot.lastFrame = p.lastFrame
                }
                slots.append(slot)
                i += 1
            }
            // Drop INV placeholders — cstats always ends with one marker entry.
            slots.removeAll { $0.id > 0 && $0.flags.contains("INV") }
            self.cines = slots
            self.partitionCount = max(1, slots.count(where: { $0.id > 0 }))
            self.recordingCine = slots.first(where: { $0.id > 0 && $0.flags.contains("WTR") })?.id
            // A "saved" mark only applies while that exact clip still sits stored
            // in RAM — once a partition re-records or clears, drop it.
            let storedIDs = Set(slots.filter { $0.state == .stored }.map(\.id))
            self.savedCines.formIntersection(storedIDs)
            self.autoSaveSweep(storedNow: Set(slots.filter { $0.id > 0 && $0.state == .stored }.map(\.id)))
            // Auto-playback: a partition that just finished recording (was WTR/TRG,
            // now stored) starts reviewing itself from the hero frame, hands-free.
            if self.autoPlayEnabled {
                let justStored = slots.first { s in
                    s.state == .stored
                        && (prev[s.id]?.state == .waitTrigger || prev[s.id]?.state == .postTrigger)
                }
                if let s = justStored {
                    self.selectedCine = s.id
                    self.mode = .play
                    self.refreshSelectedCineRange(resetTrim: true)
                    let start = self.autoPlayStartFrame
                    // Give the range fetch a beat, then play the whole clip from there.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.playFromFrame(start)
                    }
                }
            }
            // Keep playback range in sync for the selected stored cine.
            if self.mode == .play { self.refreshSelectedCineRange() }
        }
        refreshCapacity()
    }

    private var lastCapacityRefresh = Date.distantPast
    /// Partition capacity (frames that fit) is essentially static — it only
    /// changes on a resolution / partition / rate change or when you pick a
    /// different partition. So the 1 Hz poll doesn't need to hit the camera every
    /// second (each poll steals two round-trips from the live-frame queue). We
    /// throttle the routine poll to ~4 s; event-driven callers pass `force: true`
    /// (e.g. selecting a partition) to refresh immediately.
    private func refreshCapacity(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastCapacityRefresh) < 4 { return }
        lastCapacityRefresh = Date()
        let n = max(selectedCine, 1)
        runCommandAsync { conn -> Int in
            let size = PhantomProtocol.find("frsize", in: try conn.get("c\(n).frsize"))?.intValue ?? 0
            let space = PhantomProtocol.find("frspace", in: try conn.get("c\(n).frspace"))?.intValue ?? 0
            return size > 0 ? space / size : 0
        } onResult: { [weak self] cap in
            guard let self, let cap, cap > 0 else { return }
            self.capacityFrames = cap
            // Trigger position is per-partition — keep it inside this one.
            if self.postTriggerFrames > cap {
                self.loadingFromCamera = true
                self.postTriggerFrames = cap
                self.loadingFromCamera = false
            }
        }
    }

    /// Fetches the selected cine's recorded frame range. `resetTrim` forces the
    /// in/out points back to the full clip — pass it when the user picks a
    /// different clip, so an old trim never carries over. On a routine poll of
    /// the same clip we keep the user's trim but clamp it into the valid range.
    func refreshSelectedCineRange(resetTrim: Bool = false, then: (() -> Void)? = nil) {
        let n = selectedCine
        guard n > 0 else { then?(); return }
        runCommandAsync { conn in
            try conn.get("c\(n)")
        } onResult: { [weak self] parsed in
            guard let self else { return }
            defer { then?() }
            guard let parsed else { return }
            let first = PhantomProtocol.find("firstfr", in: parsed)?.intValue ?? 0
            let last = PhantomProtocol.find("lastfr", in: parsed)?.intValue ?? 0
            let count = PhantomProtocol.find("frcount", in: parsed)?.intValue ?? 0
            if let i = self.cines.firstIndex(where: { $0.id == n }) {
                self.cines[i].firstFrame = first
                self.cines[i].lastFrame = last
                self.cines[i].frameCount = count
            }
            // Don't clobber the deck while it's driving a mag take.
            guard !self.playbackIsMag else { return }
            let lo = Double(first), hi = Double(last)
            if resetTrim || (self.inPoint == 0 && self.outPoint == 0)
                || self.outPoint > hi || self.inPoint < lo {
                self.inPoint = lo
                self.outPoint = hi
                self.playFrame = lo
            } else {
                // Same clip, keep the user's trim but clamp it to valid frames.
                self.inPoint = min(max(self.inPoint, lo), hi)
                self.outPoint = min(max(self.outPoint, lo), hi)
                self.playFrame = min(max(self.playFrame, lo), hi)
            }
        }
    }

    /// Clears the trim — resets in/out/playhead to the full selected clip.
    func resetInOut() {
        refreshSelectedCineRange(resetTrim: true)
    }

    /// True when every partition holds a stored take — nothing is left to record
    /// into, so a trigger has nowhere to land.
    var ramIsFull: Bool {
        let parts = cines.filter { $0.id > 0 }
        return !parts.isEmpty && parts.allSatisfy { $0.state == .stored }
    }

    /// Stored partitions that haven't been downloaded or saved to the CineMag yet.
    func unsavedCineCount() -> Int {
        cines.filter { $0.id > 0 && $0.state == .stored && !savedCines.contains($0.id) }.count
    }

    /// Erases every recorded clip in RAM (keeps the current partition layout).
    /// Each partition re-arms afterwards.
    func clearAllRam() {
        let ids = cines.filter { $0.id > 0 }.map(\.id)
        guard !ids.isEmpty else { return }
        runCommandAsync { conn -> String in
            for n in ids { _ = try? conn.command("del {cine:\(n)}") }
            return "ok"
        } onResult: { [weak self] _ in
            self?.appendLog("cleared RAM: \(ids.count) partition(s)")
            self?.refreshCineStates()
        }
    }

    // MARK: - Live preview loop (Ethernet)

    /// The feed mode the preview was last auto-tuned for. nil → re-tune on the
    /// next frame. Mode-aware (not a plain bool) so an in-flight frame from the
    /// OLD mode can't consume the flag meant for the new one — that bug left
    /// the 12-bit path using the 8-bit levels and crushed the image.
    private var autoTunedMode: FeedMode?

    func startLiveLoop() {
        liveLoopGeneration += 1
        autoTunedMode = nil
        let gen = liveLoopGeneration
        scheduleNextLiveFrame(generation: gen)
    }

    func stopLiveLoop() { liveLoopGeneration += 1 }

    private func scheduleNextLiveFrame(generation: Int) {
        guard connected, generation == liveLoopGeneration else { return }
        // Stream while the ethernet image is what's on screen: either ethernet
        // is the chosen source, or SDI is chosen but not delivering (fallback).
        let ethernetVisible = viewerSource == .ethernet || !sdi.isRunning
        // Idle the live fetch while a clip is playing/scrubbing (even on the
        // Camera tab) so it doesn't fight playback for the camera's control
        // channel — the deck now drives playback from either tab.
        guard ethernetVisible, mode == .live, !isPlaying, !isScrubbing else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.scheduleNextLiveFrame(generation: generation)
            }
            return
        }
        let g = Float(gain)
        let pk = focusPeaking
        let con = Float(previewContrast), sat = Float(previewSaturation)
        let quality = feedMode == .quality
        // Match-SDI: develop with the camera's own WB + gamma (video.adj) so the
        // Ethernet feed matches the SDI. When on, bypass the auto-levels/contrast.
        let matchCam = matchSDI
        let camWB = Debayer.WhiteBalance(red: Float(camWbRed), green: 1.0, blue: Float(camWbBlue))
        let camGam = Float(camGamma), camS = Float(camSat), camBlk = Float(camBlack)
        // EI develop gain — the SDI applies it, so Match-SDI must too or the feeds
        // diverge in brightness at non-native EI. VEO-class (VEO, Flex 4K) store gain as
        // a FLOAT (unity 1.0) → use it directly; Flex-2K stores it fixed-point (1024 = 1×).
        // (Old code truncated the float to Int, e.g. 3.2 → 3 → /1024 ≈ 0 = near-black.)
        let camG = supportsWBTemp ? Float(eiGain) : Float(videoGain) / 1024.0
        let t0 = Date()
        // Grab ONLY the raw bytes on the camera queue, then immediately schedule
        // the next grab — the debayer + display run on a separate worker so the
        // data channel keeps streaming instead of stalling on CPU work each
        // frame. Quality mode pulls 12-bit (P16) for banding-free gradients at
        // the cost of ~half the fps; Speed pulls 8-bit.
        runCommandAsync { conn -> (PhantomFrame?, Data?, Int, Int) in
            if quality {
                let (d, w, h) = try conn.grabFrame16()
                return (nil, d, w, h)
            } else {
                let f = try conn.grabFrame()
                return (f, nil, f.width, f.height)
            }
        } onResult: { [weak self] result in
            guard let self else { return }
            if let (frame8, data16, w, h) = result {
                let dt = Date().timeIntervalSince(t0)
                self.ethernetFPSExact = self.ethernetFPSExact * 0.8 + (1.0 / max(dt, 0.001)) * 0.2
                let fps = self.ethernetFPSExact
                // Publish the readout only when the whole-fps number changes —
                // otherwise every single frame triggers a full SwiftUI pass just
                // to nudge a counter, which is real overhead on slower Macs.
                let shownFPS = fps.rounded()
                if shownFPS != self.ethernetFPS { self.ethernetFPS = shownFPS }
                if let frame = frame8 { self.lastRawFrame = frame }
                // Auto-tune once per connection / mode change — keyed to THIS
                // frame's mode so a stale other-mode frame can't consume it.
                let thisMode: FeedMode = quality ? .quality : .speed
                let doAuto = self.autoTunedMode != thisMode
                if doAuto { self.autoTunedMode = thisMode }
                self.debayerQueue.async { [weak self] in
                    guard let self else { return }
                    var image: CGImage?
                    var luma: Double?
                    // Match-SDI develop = reproduce the camera's OWN video.adj
                    // pipeline on the raw: per-channel WB gains (video.adj.red/
                    // green/blue) applied in LINEAR, then the camera gamma. This is
                    // the develop PCC uses — verified by packet capture of the SDI
                    // session on this Flex (red 2.01×, blue 1.68×, gamma 2.22, and
                    // matrix/flare/pedestal all 0), applied to raw that is bit-for-
                    // bit identical to what PCC downloads. So we skip auto-levels
                    // and app WB in this mode and use the camera's fixed values with
                    // gain 1.0. NOTE: the LIVE preview still shows faint sensor
                    // fixed-pattern banding the SDI/recordings don't — the camera's
                    // black calibration (CSR) isn't applied to the live raw stream,
                    // only to recordings; colour/gamma are what we can match here.
                    let mGamma  = matchCam ? camGam : 0
                    let mSat    = matchCam ? camS : sat
                    let devWB   = matchCam ? camWB
                        : Debayer.WhiteBalance(red: Float(self.wbRed), green: 1.0, blue: Float(self.wbBlue))
                    let devGain: Float   = matchCam ? camG : g
                    let devBlack: Float  = matchCam ? camBlk : Float(self.previewBlack)
                    let devWhite: Float  = matchCam ? 1.0 : Float(self.previewWhite)
                    if quality, let d = data16 {
                        if doAuto && !matchCam { self.autoLevels16(data: d, width: w, height: h) }
                        image = Debayer.halfResBGRA16(data: d, width: w, height: h, wb: devWB, gain: devGain,
                                                      peaking: pk, blackLevel: devBlack,
                                                      whiteLevel: devWhite,
                                                      contrast: con, saturation: mSat, gamma: mGamma)
                    } else if let frame = frame8 {
                        if doAuto && !matchCam { self.autoLevels(from: frame) }
                        image = Debayer.halfResBGRA(frame: frame, wb: devWB, gain: devGain, peaking: pk,
                                                    blackLevel: devBlack,
                                                    whiteLevel: devWhite,
                                                    contrast: con, saturation: mSat, gamma: mGamma)
                        luma = Self.meanLuma(of: frame)
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let image { self.viewerImage = image }
                        if self.viewerSource == .ethernet, let l = luma {
                            self.flicker.sampleRateHz = fps
                            self.flicker.push(meanLuma: l)
                        }
                    }
                }
            }
            // Reschedule right away — don't wait for the debayer above.
            self.scheduleNextLiveFrame(generation: generation)
        }
    }

    /// Serial worker that debayers/analyzes preview frames off the camera queue,
    /// so network fetches never wait on CPU. One frame in flight at a time keeps
    /// display order correct and memory flat.
    private let debayerQueue = DispatchQueue(label: "phantom.debayer", qos: .userInitiated)

    /// Coarse mean luma of a raw Phantom frame (8-bit bayer) — for flicker.
    static func meanLuma(of frame: PhantomFrame) -> Double? {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0, frame.pixels.count >= w * h else { return nil }
        return frame.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Double in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            var sum = 0.0, count = 0
            var y = 0
            while y < h {
                var x = 0
                let row = p + y * w
                while x < w { sum += Double(row[x]); count += 1; x += 16 }
                y += 8
            }
            return count > 0 ? sum / Double(count) : 0
        }
    }

    /// Re-debayers the last received frame with current WB/gain — instant
    /// feedback for the image sliders even when playback is paused.
    func rerenderLastFrame() {
        guard let frame = lastRawFrame else { return }
        let wb = Debayer.WhiteBalance(red: Float(wbRed), green: 1.0, blue: Float(wbBlue))
        let g = Float(gain)
        let pk = focusPeaking
        let blk = Float(previewBlack), wht = Float(previewWhite)
        let con = Float(previewContrast), sat = Float(previewSaturation)
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = Debayer.halfResBGRA(frame: frame, wb: wb, gain: g, peaking: pk,
                                          blackLevel: blk, whiteLevel: wht,
                                          contrast: con, saturation: sat)
            if let img {
                await MainActor.run { self?.viewerImage = img }
            }
        }
    }

    /// Auto-levels: find the raw preview's actual black/white points (2nd and
    /// 98th percentiles of a luma sample) and set them so the stretch fills the
    /// display range — the fix for the flat, milky raw feed. Cheap 256-bin
    /// histogram over a subsampled grid.
    func autoLevels(from frame: PhantomFrame) {
        let w = frame.width, h = frame.height
        guard w >= 2, h >= 2, frame.pixels.count >= w * h else { return }
        var hR = [Int](repeating: 0, count: 256)
        var hG = [Int](repeating: 0, count: 256)
        var hB = [Int](repeating: 0, count: 256)
        var hL = [Int](repeating: 0, count: 256)
        var total = 0
        frame.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            var y = 0
            while y < h - 1 {                    // GBRG 2x2 cells
                let r0 = p + y * w, r1 = p + (y + 1) * w
                var x = 0
                while x < w - 1 {
                    let g = (Int(r0[x]) + Int(r1[x + 1])) >> 1
                    let b = Int(r0[x + 1]); let r = Int(r1[x])
                    hR[r] += 1; hG[g] += 1; hB[b] += 1
                    hL[(r * 77 + g * 151 + b * 28) >> 8] += 1   // ~Rec.601 luma
                    total += 1
                    x += 8
                }
                y += 8
            }
        }
        guard total > 0 else { return }
        func pct(_ hist: [Int], _ frac: Double, fromTop: Bool) -> Int {
            let cut = Int(Double(total) * frac)
            var acc = 0
            if fromTop {
                for i in stride(from: 255, through: 0, by: -1) { acc += hist[i]; if acc >= cut { return i } }
                return 255
            } else {
                for i in 0..<256 { acc += hist[i]; if acc >= cut { return i } }
                return 0
            }
        }
        // White-balance from the channel white points: a neutral highlight
        // should read equal RGB. Green is the reference (2 samples per cell).
        // This is robust where grey-world fails — e.g. a colourful test chart.
        let rW = Double(max(1, pct(hR, 0.02, fromTop: true)))
        let gW = Double(max(1, pct(hG, 0.02, fromTop: true)))
        let bW = Double(max(1, pct(hB, 0.02, fromTop: true)))
        let newRed = min(3.0, max(0.5, gW / rW))
        let newBlue = min(3.0, max(0.5, gW / bW))
        // Levels stretch from luma percentiles.
        let lo = pct(hL, 0.02, fromTop: false)
        let hi = pct(hL, 0.02, fromTop: true)
        guard hi - lo >= 8 else { return }
        let black = Double(lo) / 255.0
        var white = min(1.0, Double(hi) / 255.0 + 0.03)
        // Anti-noise guard: a near-black / flat frame (e.g. capped lens) spans
        // almost nothing, and stretching that to full range magnifies the
        // sensor's noise floor into visible grain. Don't over-amplify — widen
        // the white point so a black frame stays BLACK instead of noisy.
        if white - black < 0.06 { white = min(1.0, black + 0.5) }
        Task { @MainActor in
            self.wbRed = newRed
            self.wbBlue = newBlue
            self.previewBlack = black
            self.previewWhite = white
            self.rerenderLastFrame()
            self.appendLog(String(format: "auto tune: WB R %.2f B %.2f · levels %.2f–%.2f",
                                   newRed, newBlue, black, white))
        }
    }

    /// 16-bit (P16 quality mode) counterpart of autoLevels — same per-channel
    /// white-point WB + luma levels stretch, computed in 12-bit space (value
    /// >>4 → 256-bin index) so the fractions mean the same 0–1 as the 8-bit
    /// path. Runs on the debayer queue; publishes on the main actor.
    func autoLevels16(data: Data, width w: Int, height h: Int) {
        guard w >= 2, h >= 2, data.count >= w * h * 2 else { return }
        var hR = [Int](repeating: 0, count: 256)
        var hG = [Int](repeating: 0, count: 256)
        var hB = [Int](repeating: 0, count: 256)
        var hL = [Int](repeating: 0, count: 256)
        var total = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s = raw.bindMemory(to: UInt16.self).baseAddress!
            var maxV: UInt16 = 0, i = 0
            let n = w * h
            while i < n { if s[i] > maxV { maxV = s[i] }; i += 97 }
            let shift = (maxV > 4095 ? 4 : 0) + 4     // → 8-bit index over 12-bit range
            var y = 0
            while y < h - 1 {
                let r0 = s + y * w, r1 = s + (y + 1) * w
                var x = 0
                while x < w - 1 {
                    let g = ((Int(r0[x]) + Int(r1[x + 1])) >> 1) >> shift
                    let b = Int(r0[x + 1]) >> shift, r = Int(r1[x]) >> shift
                    hR[min(255, r)] += 1; hG[min(255, g)] += 1; hB[min(255, b)] += 1
                    hL[min(255, (r * 77 + g * 151 + b * 28) >> 8)] += 1
                    total += 1
                    x += 8
                }
                y += 8
            }
        }
        guard total > 0 else { return }
        func pct(_ hist: [Int], _ frac: Double, fromTop: Bool) -> Int {
            let cut = Int(Double(total) * frac); var acc = 0
            if fromTop { for i in stride(from: 255, through: 0, by: -1) { acc += hist[i]; if acc >= cut { return i } }; return 255 }
            for i in 0..<256 { acc += hist[i]; if acc >= cut { return i } }; return 0
        }
        let rW = Double(max(1, pct(hR, 0.02, fromTop: true)))
        let gW = Double(max(1, pct(hG, 0.02, fromTop: true)))
        let bW = Double(max(1, pct(hB, 0.02, fromTop: true)))
        let newRed = min(3.0, max(0.5, gW / rW))
        let newBlue = min(3.0, max(0.5, gW / bW))
        let lo = pct(hL, 0.02, fromTop: false), hi = pct(hL, 0.02, fromTop: true)
        guard hi - lo >= 8 else { return }
        let black = Double(lo) / 255.0
        var white = min(1.0, Double(hi) / 255.0 + 0.03)
        // Anti-noise guard (see autoLevels): don't stretch a near-black/flat
        // frame to full range — it just magnifies the sensor noise floor.
        if white - black < 0.06 { white = min(1.0, black + 0.5) }
        Task { @MainActor in
            self.wbRed = newRed; self.wbBlue = newBlue
            self.previewBlack = black; self.previewWhite = white
            self.appendLog(String(format: "auto tune (12-bit): WB R %.2f B %.2f · levels %.2f–%.2f",
                                   newRed, newBlue, black, white))
        }
    }

    /// Read the camera's SDI colour pipeline (video.adj) so the Ethernet feed
    /// can develop the raw the SAME way — matching the SDI feed. video.adj is
    /// fixed-point 1024 = 1.0; green is the WB reference. Re-read on connect and
    /// after a white balance (both change these registers).
    func refreshCameraColor() {
        runCommandAsync { conn -> [String: PhValue] in
            try conn.get("video.adj")
        } onResult: { [weak self] adjRaw in
            guard let self, let adjRaw else { return }
            // Encoding probe: newer bodies (Flex 4K / VEO) report develop values as FLOATS
            // (gamma ~2.2); the PH16 Flex 2K reports them ×1024 fixed-point (gamma ~2273).
            // One probe on `gamma` (always present) decides which — float ≤10, 1024-int ≈2273.
            let isFloat = (PhantomProtocol.find("gamma", in: adjRaw)?.doubleValue ?? 2.2) < 100
            self.adjIsFloat = isFloat
            // Scale-aware human value of a develop key.
            func hv(_ k: String, _ d: Double) -> Double {
                guard let raw = PhantomProtocol.find(k, in: adjRaw)?.doubleValue else { return d }
                return isFloat ? raw : raw / 1024.0
            }
            // Populate the Image Tools develop dict (human units) + presence set (UI gating).
            var present = Set<String>(); var dict = self.adj
            for c in ImageAdjust.controls {
                guard let raw = PhantomProtocol.find(c.key, in: adjRaw)?.doubleValue else { continue }
                present.insert(c.key)
                dict[c.key] = (c.kind == .scaled && !isFloat) ? raw / 1024.0 : raw
            }
            self.adjPresent = present; self.adj = dict
            // Match-SDI develop mirrors — scale-aware. (The old code divided EVERY value by
            // 1024 unconditionally, which clamped gamma→1.0 and sat→0 on the float Flex 4K.)
            if isFloat {
                // Float bodies carry WB in wbred/wbblue; red/green/blue are unity user gains.
                self.camWbRed  = min(4, max(0.25, hv("wbred",  1)))
                self.camWbBlue = min(4, max(0.25, hv("wbblue", 1)))
            } else {
                let green = max(0.25, hv("green", 1.0))
                self.camWbRed  = min(4, max(0.25, hv("red",  1.8) / green))
                self.camWbBlue = min(4, max(0.25, hv("blue", 1.55) / green))
            }
            self.camGamma = min(3.0, max(1.0, hv("gamma", 2.2)))
            self.camSat   = min(2.0, max(0.0, hv("sat", 1.0)))
            // sdimin (0–1023) is the camera's black setpoint → normalized floor.
            let sdimin = PhantomProtocol.find("sdimin", in: adjRaw)?.doubleValue ?? 64
            self.camBlack = min(0.2, max(0, sdimin / 1023.0 * 0.5))
            // EI READ-BACK (VEO-class: VEO, Flex 4K). EI is TWO knobs on video.adj:
            //   • tone — a calibrated "EI####" curve; its label IS the clean EI. A
            //            neutral/numeric curve has no label → clean EI stays unknown.
            //   • gain — float global gain, unity 1.0; >1.0 only pushes past the ceiling.
            if self.supportsWBTemp {
                if let g = PhantomProtocol.find("gain", in: adjRaw)?.doubleValue, g > 0 {
                    self.eiGain = g
                }
                let toneStr = PhantomProtocol.find("tone", in: adjRaw)?.stringValue ?? ""
                if let cei = Self.parseToneEI(toneStr) {
                    self.cleanEI = cei                       // calibrated "EI####" curve → clean EI
                } else if toneStr.trimmingCharacters(in: .whitespaces).isEmpty, self.baseEI > 0 {
                    self.cleanEI = self.baseEI               // empty/neutral tone = native EI (250)
                }
                // else: a numeric/custom look tone with no EI label — leave cleanEI as-is.
            }
            // Log-mode read-back (VEO log locks EI) — reflect what the camera booted with.
            if let lg = PhantomProtocol.find("log", in: adjRaw)?.intValue, lg != self.logMode {
                self.logMode = lg
            }
            self.appendLog(String(format: "video.adj (%@): WB R %.2f B %.2f · gamma %.2f · sat %.2f",
                                   isFloat ? "float" : "1024-int",
                                   self.camWbRed, self.camWbBlue, self.camGamma, self.camSat))
        }
    }

    /// Re-run the auto pass from the latest preview frame (the "Auto" button).
    func autoTunePreview() {
        if let f = lastRawFrame { autoLevels(from: f) }
    }

    /// One-click grey-world white balance from the center of the last frame.
    func autoWhiteBalance() {
        guard let frame = lastRawFrame else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let w = frame.width, h = frame.height
            var sumR = 0, sumG = 0, sumB = 0, count = 0
            frame.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!
                // center half of the image, GBRG pattern
                var y = h / 4
                while y < (3 * h) / 4 - 1 {
                    var x = w / 4
                    while x < (3 * w) / 4 - 1 {
                        sumG += Int(p[y * w + x]) + Int(p[(y + 1) * w + x + 1])
                        sumB += Int(p[y * w + x + 1]) * 2
                        sumR += Int(p[(y + 1) * w + x]) * 2
                        count += 2
                        x += 2
                    }
                    y += 2
                }
            }
            guard count > 0, sumR > 0, sumB > 0 else { return }
            let g = Double(sumG), r = Double(sumR), b = Double(sumB)
            let newRed = min(3.0, max(0.5, g / r))
            let newBlue = min(3.0, max(0.5, g / b))
            await MainActor.run {
                guard let self else { return }
                self.wbRed = newRed
                self.wbBlue = newBlue
                self.rerenderLastFrame()
                self.appendLog(String(format: "auto WB: R %.2f  B %.2f", newRed, newBlue))
            }
        }
    }

    // MARK: - Camera actions

    func capture() {
        let n = selectedCine
        savedCines.remove(n)   // about to overwrite this partition with new footage
        sendSimple("rec {cine:\(n)}", label: "capture c\(n)")
    }

    func trigger() {
        sendSimple("trig", label: "trigger")
    }

    func deleteSelectedCine() {
        deleteCine(selectedCine)
    }

    /// Clears one partition's recording (camera re-arms it).
    func deleteCine(_ n: Int) {
        guard n > 0 else { return }
        savedCines.remove(n)
        sendSimple("del {cine:\(n)}", label: "delete c\(n)")
    }

    /// Resolutions the sensor actually supports — filtered live against the
    /// connected camera's grid (xInc/yInc/xMax/yMax). The candidate list spans
    /// VEO4K 4K/2K widths AND Flex widths; only the legal ones for THIS camera
    /// survive the filter, so the menu auto-adapts per camera. Each entry shows
    /// aspect ratio and an estimated max frame rate at that height.
    var resolutionPresets: [(w: Int, h: Int, label: String)] {
        let sizes = [
            // VEO4K — 4096 wide
            (4096, 2304), (4096, 2160), (4096, 1872), (4096, 1716), (4096, 1536),
            (4096, 1280), (4096, 1080), (4096, 864), (4096, 720),
            // VEO4K — 2048 wide
            (2048, 1536), (2048, 1152), (2048, 1080), (2048, 858), (2048, 720), (2048, 512),
            // Flex / smaller sensors
            (2560, 1600), (2560, 1440), (2560, 1080), (2304, 1296),
            (1920, 1080), (1792, 1008), (1280, 720), (1024, 576),
        ]
        return sizes
            .filter { $0.0 <= xMax && $0.1 <= yMax && $0.0 % xInc == 0 && $0.1 % yInc == 0 }
            .map { (w, h) in
                let fps = estimatedMaxFPS(width: w, height: h)
                return (w, h, "\(w) × \(h)  \(Self.aspectLabel(w, h)) · ~\(fps) fps")
            }
    }

    /// Rough max frame rate at a given height. Phantom readout is row-bound, so
    /// max fps scales inversely with active rows. Calibrated to this camera's
    /// full-res ceiling; clamped to the camera's reported absolute max. Shown
    /// as a guide — the camera clamps the real value when you set the rate.
    func estimatedMaxFPS(width: Int, height: Int) -> Int {
        // Reference: VEO4K-PL ≈ 938 fps at 4096×2304. k = fps × rows.
        let k = 938.0 * 2304.0
        let est = Int((k / Double(max(height, 1))) / 10.0) * 10   // round to 10
        let cap = 25000   // sane display ceiling regardless of info.maxrate
        return min(max(est, 24), cap)
    }

    static func aspectLabel(_ w: Int, _ h: Int) -> String {
        let r = Double(w) / Double(h)
        switch r {
        case 1.59...1.61: return "16:10"
        case 1.76...1.79: return "16:9"
        case 1.32...1.34: return "4:3"
        case 1.88...1.92: return "1.90:1"
        case 1.98...2.02: return "2:1"
        case 2.3...2.45: return "2.39:1"
        case 2.6...2.7: return "2.66:1"
        default: return String(format: "%.2f:1", r)
        }
    }

    func applySettings() {
        // Snap to the sensor's legal grid — the camera silently rounds otherwise
        // (e.g. asking the Flex for 1920 wide yields 1792).
        loadingFromCamera = true
        resWidth = max(xInc, min(xMax, (resWidth / xInc) * xInc))
        resHeight = max(yInc, min(yMax, (resHeight / yInc) * yInc))
        shutterAngle = min(359, max(1, shutterAngle))
        loadingFromCamera = false
        let w = resWidth, h = resHeight, r = max(frameRate, 10), pt = postTriggerFrames
        // exp is NANOSECONDS. Keep ≥ 1µs (camera minimum) and below the frame period.
        let periodNS = 1e9 / Double(r)
        let expNS = Int(min(periodNS * 0.997, max(1000.0, (shutterAngle / 360.0) * periodNS)))
        // PCC semantics: defc always; plus selected cine, or every non-stored cine
        // when "apply to all" (lock off).
        // c0 is the live preview cine — setting it makes the SDI output follow
        // immediately (PCC does this on every change). defc covers future
        // recordings. While a partition is pre-roll capturing (WTR) the sensor
        // is locked to ITS settings, so like PCC we abort → apply → re-arm;
        // only the rolling pre-trigger buffer is lost and it refills at once.
        var targets = ["defc", "c0"]
        var skipped: [String] = []
        let restartCine = cines.first(where: { $0.id > 0 && $0.state == .waitTrigger })?.id
        if let r = restartCine { targets.append("c\(r)") }
        if applyToAllCines {
            for slot in cines where slot.id > 0 {
                if slot.state == .ready { targets.append("c\(slot.id)") }
                else if slot.state == .postTrigger { skipped.append("C\(slot.id) (post-trigger)") }
            }
        } else if selectedCine > 0, selectedCine != restartCine {
            if cines.first(where: { $0.id == selectedCine })?.state == .ready {
                targets.append("c\(selectedCine)")
            } else {
                skipped.append("C\(selectedCine)")
            }
        }
        if !skipped.isEmpty { appendLog("not applied to \(skipped.joined(separator: ", "))") }
        let hq = hqMode ? 1 : 0
        let veoAbort = supportsCinesVar
        let armed = rampArmed
        let hasProfile = supportsProfileRamp
        runCommandAsync { conn -> Int in
            if let rc = restartCine {
                // abort pre-roll: VEO-gen uses rec 0, Flex-gen uses state write
                _ = try? conn.command(veoAbort ? "rec {cine:0}" : "set c\(rc).state { RDY ABL }")
            }
            var ok = 0
            for t in targets {
                ok += (try conn.command("set \(t).hqenable:\(hq)")).contains("Ok") ? 1 : 0
                ok += (try conn.command("set \(t).res \(w) x \(h)")).contains("Ok") ? 1 : 0
                ok += (try conn.command("set \(t).rate \(r)")).contains("Ok") ? 1 : 0
                ok += (try conn.command("set \(t).exp \(expNS)")).contains("Ok") ? 1 : 0
                ok += (try conn.command("set \(t).ptframes \(pt)")).contains("Ok") ? 1 : 0
            }
            // Release any leftover speed-ramp exposure clamp unless a ramp is
            // intentionally armed. A stale defc.profile (atrig 1) silently caps max
            // exposure to the fastest ramp rate's frame period, pinning the shutter
            // angle low at lower frame rates (e.g. stuck ~11° at 30 fps after a
            // 1000 fps ramp). Clearing atrig on every normal apply makes it impossible.
            if !armed && hasProfile {
                _ = try? conn.command("set defc.profile.atrig 0")
            }
            if let rc = restartCine {
                _ = try? conn.command("rec {cine:\(rc)}")               // re-arm capture
            }
            return ok
        } onResult: { [weak self] ok in
            guard let self else { return }
            var line = "settings → \(targets.joined(separator: ",")) (\(ok ?? 0)/\(targets.count*5) ok): \(w)x\(h) @\(r)fps \(Int(self.shutterAngle))°\(hq == 1 ? " HQ" : "")"
            if let rc = restartCine { line += " — restarted capture C\(rc)" }
            self.appendLog(line)
            self.refreshAll()
        }
    }

    /// Aborts the active recording so settings can change (PCC sets the cine
    /// state back to armed, per packet captures).
    func abortRecording() {
        guard let rec = activeRecordingCine else { return }
        // VEO-generation cameras stop capture with `rec {cine:0}` (verified);
        // Flex-generation uses the state write.
        let cmdStr = supportsCinesVar ? "rec {cine:0}" : "set c\(rec).state { RDY ABL }"
        runCommandAsync { conn in
            try conn.command(cmdStr)
        } onResult: { [weak self] result in
            self?.appendLog("abort rec c\(rec): \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
            self?.refreshCineStates()
        }
    }

    /// The partition actively recording — pre-roll (WTR) or post-trigger (TRG).
    var activeRecordingCine: Int? {
        cines.first(where: { $0.id > 0 && ($0.state == .waitTrigger || $0.state == .postTrigger) })?.id
    }

    /// Stops the active recording and KEEPS everything captured so far. On a
    /// triggered (post-trigger) cine this finalizes the partial take as a stored
    /// clip — so a long take rolling out the whole partition can be cut short
    /// without losing it, or waiting. Verified on VEO4K: `rec {cine:0}` on a TRG
    /// cine → STR with the frames recorded up to that instant.
    func stopAndStore() {
        let cmd: String
        if supportsCinesVar {
            cmd = "rec {cine:0}"                                   // VEO: stops + stores partial
        } else if let n = activeRecordingCine {
            cmd = "set c\(n).state { STR }"                        // Flex: mark stored
        } else { return }
        runCommandAsync { conn in try conn.command(cmd) } onResult: { [weak self] result in
            self?.appendLog("stop & store: \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
            self?.refreshCineStates()
        }
    }

    /// Whether a black reference has been taken this session. White balance is
    /// only trustworthy AFTER a black balance — otherwise a per-channel black
    /// offset skews the WB ratios and throws colour off. Drives the pre-WB warning.
    @Published var blackRefDone = false {
        didSet { if blackRefDone { lastBrefDate = Date(); brefReminderFired = false } }
    }
    /// A white-balance action awaiting the black-ref warning's outcome.
    @Published var pendingWhiteBalance: (() -> Void)?
    @Published var showBlackRefWarning = false

    /// Center-screen "re-do black reference" reminder shown after a frame-rate
    /// change (the sensor's black shade is calibrated per rate, so it goes stale).
    /// Offers to run the black reference right from the dialog. `…Rate` carries the
    /// new rate for the message.
    @Published var showBlackShadeReminder = false
    @Published var blackShadeReminderRate = 0

    // MARK: Black-ref reminder — the Flex 2K's sensor drifts with temperature,
    // so its black reference goes stale in a way newer generations (VEO,
    // Flex 4K) don't. Optional timer: after N minutes without a black ref, the
    // Black Ref button re-arms orange and a toast nudges the operator.
    @Published var brefRemindEnabled = UserDefaults.standard.bool(forKey: "brefRemind") {
        didSet { UserDefaults.standard.set(brefRemindEnabled, forKey: "brefRemind") }
    }
    @Published var brefRemindMinutes: Int = {
        let v = UserDefaults.standard.integer(forKey: "brefRemindMin"); return v > 0 ? v : 20
    }() {
        didSet { if brefRemindMinutes > 0 { UserDefaults.standard.set(brefRemindMinutes, forKey: "brefRemindMin") } }
    }
    private var lastBrefDate: Date?
    private var brefReminderFired = false

    /// Called from the poll loop. The clock starts at the first check after a
    /// connect (or at the last black ref) and fires once per overdue period.
    func checkBrefReminder() {
        guard connected, brefRemindEnabled, brefRemindMinutes > 0 else { return }
        guard let last = lastBrefDate else { lastBrefDate = Date(); return }
        guard !brefReminderFired else { return }
        if Date().timeIntervalSince(last) > Double(brefRemindMinutes) * 60 {
            blackRefDone = false          // re-arm the orange button + WB gate
            brefReminderFired = true      // fire once per overdue period
            showDownloadToast(ok: false, title: "Black reference due",
                              detail: "\(brefRemindMinutes) min since the last one — cap the lens and run Black Ref (or use the camera's own button).")
            appendLog("black-ref reminder: \(brefRemindMinutes) min elapsed")
        }
    }

    /// Camera black reference calibration (PCC's "CSR"/Black Reference). Cap the
    /// lens / close the shutter first — it measures the sensor's dark frame.
    func blackReference() {
        sendSimple("bref", label: "black reference")
        blackRefDone = true
    }

    /// Run a black reference, then (once it settles) the queued white balance.
    func blackRefThenWhiteBalance() {
        let wb = pendingWhiteBalance
        pendingWhiteBalance = nil
        showBlackRefWarning = false
        blackReference()
        // Give the camera a moment to compute the dark frame before balancing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { wb?() }
    }

    /// Gate a white-balance action behind the black-ref reminder. If black has
    /// been referenced this session, run it straight away; otherwise raise the
    /// warning so the user can black-balance first (the correct order).
    func requestWhiteBalance(_ action: @escaping () -> Void) {
        if blackRefDone {
            action()
        } else {
            pendingWhiteBalance = action
            showBlackRefWarning = true
        }
    }

    func proceedWithPendingWhiteBalance() {
        let wb = pendingWhiteBalance
        pendingWhiteBalance = nil
        showBlackRefWarning = false
        wb?()
    }

    /// Saves the selected cine's in/out range onto the CineMag (camera-side
    /// copy — much faster than Ethernet download).
    func saveToMag() {
        // The Flex can't serve an Ethernet download AND write to the CineMag at
        // once — doing both jams the camera. Block the overlap.
        guard downloadProgress == nil else {
            magOpResult = "Finish the Mac download first — the camera can't save to the CineMag and download at the same time."
            return
        }
        guard magBusy == nil, magSavingCine == nil else { return }
        let n = selectedCine
        let first = Int(inPoint), last = Int(outPoint)
        magBusy = "Saving C\(n) → CineMag…"
        runCommandAsync { conn in
            try conn.command("fsave {cine:\(n), firstframe:\(first), lastframe:\(last)}", timeout: 10)
        } onResult: { [weak self] result in
            self?.magBusy = nil
            self?.savedCines.insert(n)   // safely on the CineMag now
            self?.appendLog("save c\(n) \(first)…\(last) → CineMag: \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
            self?.refreshMag()
        }
    }

    /// The deck currently holds a saved RAM clip — so its in→out can be kept
    /// (saved to the CineMag or downloaded). False for live, an empty/recording
    /// partition, or a CineMag take (that's already on the mag).
    var canSaveDeckClip: Bool {
        guard !playbackIsMag else { return false }
        return cines.first(where: { $0.id == selectedCine })?.state == .stored
    }

    /// Where a one-tap "keep this clip" will go — CineMag if one is loaded,
    /// otherwise the Mac. Drives the button/menu label.
    var saveDeckDestinationLabel: String {
        magSize > 0 ? "Save In→Out to CineMag" : "Download In→Out to Mac"
    }

    /// One-tap keep of the deck's in→out range: to the CineMag if one is present
    /// (Flex with a mag → mag), otherwise a download to the Mac (VEO / no mag →
    /// computer). Same two destinations as the Save-tab buttons, picked for you.
    func saveInOutSmart() {
        guard canSaveDeckClip else { return }
        if magSize > 0 { saveToMag(); return }
        let frames = Int(outPoint - inPoint) + 1
        if downloadWontFit(frames: frames) {
            let gb = Double(estimatedDownloadBytes(frames: frames)) / 1e9
            showDownloadToast(ok: false, title: "Not enough space",
                detail: "This clip needs ≈\(String(format: "%.1f", gb)) GB but the drive only has \(freeSpaceString). Free up space, or use the Save tab to pick another folder.")
            return
        }
        downloadSelectedCine()
    }

    /// Plays the deck's in→out range (RAM or mag) out the SDI and records it
    /// to a .mov on the Desktop — a quick viewing copy with no .cine download.
    func saveSDIProxy() {
        guard sdi.isRunning else {
            appendLog("SDI proxy needs the SDI viewer running")
            return
        }
        guard !sdi.isProxyRecording else { return }
        isPlaying = false
        playTask?.cancel(); playTask = nil
        let first = Int(inPoint), last = Int(outPoint)
        let dest = destinationURL(defaultBase: "Proxy_\(playbackSourceLabel)", ext: "mov")
        let name = dest.lastPathComponent
        let label = playbackSourceLabel
        // Hold the FIRST frame on the SDI while the recorder warms up, then roll
        // the clip only once recording has actually started — otherwise the
        // recorder's startup latency eats the first few percent of frames.
        sendSimple(vplayCmd(first: first, last: first), label: "proxy cue")
        let seconds = Double(last - first + 1) / 24.0 + 1.5
        sdi.startProxyRecording(to: dest) { [weak self] in
            guard let self else { return }
            self.sendSimple(self.vplayCmd(first: first, last: last), label: "proxy play \(label)")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.sdi.stopProxyRecording()
            }
        }
        appendLog("recording SDI proxy ~\(Int(seconds))s → \(name)")
    }

    /// Camera-side white balance from the image center — the accurate,
    /// feed-consistent WB. Put a grey card in the middle of frame first. Bare
    /// `wbal` sets the CAMERA's own WB, so the SDI output, recordings AND the
    /// raw Ethernet preview all inherit it. Afterwards the Ethernet display's
    /// app-side trim is reset to neutral so it shows the camera's WB (not a
    /// second, conflicting correction) — which is why SDI used to look off.
    func cameraWhiteBalance(retriesLeft: Int = 5) {
        runCommandAsync { conn in
            try conn.command("wbal")
        } onResult: { [weak self] result in
            guard let self else { return }
            let r = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            // A black reference runs asynchronously on the camera; wbal reports
            // "ref in progress" until it finishes — wait it out and retry.
            if r.localizedCaseInsensitiveContains("in progress"), retriesLeft > 0 {
                // A black reference IS running right now (maybe started from the
                // camera-body button) — that satisfies the black-balance-first
                // gate for this session.
                self.blackRefDone = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.cameraWhiteBalance(retriesLeft: retriesLeft - 1)
                }
                return
            }
            self.appendLog("camera WB (centre grey): \(r)")
            if r.hasPrefix("Ok") {
                // Trust the camera's WB on both feeds — drop the app-side trim.
                self.wbRed = 1.0
                self.wbBlue = 1.0
                // WB changed video.adj — re-read it so Match-SDI stays matched.
                self.refreshCameraColor()
                self.rerenderLastFrame()
            }
        }
    }

    /// Click-to-white-balance: the viewer passes the clicked point as a 0–1
    /// fraction of the image. Newer firmware gets camera-side `wbal {x,y}`;
    /// the Flex (which rejects coordinates) gets the app-side path — sample
    /// the clicked patch from the live picture, compute the gain correction,
    /// and write the camera's live video WB registers (video.adj.red/blue,
    /// fixed-point 1024 = 1.0 — verified live on swver 797).
    @Published var wbPickMode = false

    func whiteBalance(atRelativeX rx: Double, y ry: Double) {
        wbPickMode = false
        // Sample the RAW sensor patch at the click (not the processed image) so
        // the balance is measured from true sensor values — accurate, no
        // double-correction. One click then balances BOTH feeds from that same
        // neutral: the Ethernet display (app-side wbRed/wbBlue) and the camera
        // video processor (video.adj → SDI + recordings). That keeps them
        // consistent — previously the eyedropper only touched the camera side,
        // so switching to SDI showed a different balance.
        let raw = lastRawFrame.flatMap { Self.rawPatchRGB(in: $0, rx: rx, ry: ry) }
        runCommandAsync { conn -> (String, Double?, Double?) in
            guard let p = raw, p.r > 1, p.g > 1, p.b > 1 else {
                // No raw frame to measure (e.g. SDI-only) — centre camera WB.
                _ = try conn.command("wbal")
                return ("camera WB (no raw patch — used centre)", nil, nil)
            }
            if max(p.r, p.g, p.b) > 250 {
                return ("that spot is clipped white — click a GREY (not blown-out) area", nil, nil)
            }
            // Ethernet display gains that make the clicked patch neutral.
            let ethRed  = min(3.0, max(0.4, p.g / p.r))
            let ethBlue = min(3.0, max(0.4, p.g / p.b))
            // Camera video WB (SDI/recordings), scaling the current registers by
            // the same ratio (1024 = 1.0 fixed point).
            let red  = PhantomProtocol.find("red",  in: try conn.get("video.adj.red"))?.doubleValue  ?? 1024
            let blue = PhantomProtocol.find("blue", in: try conn.get("video.adj.blue"))?.doubleValue ?? 1024
            _ = try conn.command("set video.adj.red \(min(max(Int((red * p.g / p.r).rounded()), 128), 8192))")
            _ = try conn.command("set video.adj.blue \(min(max(Int((blue * p.g / p.b).rounded()), 128), 8192))")
            return (String(format: "spot WB: eth R %.2f B %.2f · SDI adjusted", ethRed, ethBlue), ethRed, ethBlue)
        } onResult: { [weak self] result in
            guard let self else { return }
            let (msg, r, b) = result ?? ("WB failed — camera connected?", nil, nil)
            if let r, let b { self.wbRed = r; self.wbBlue = b; self.rerenderLastFrame() }
            self.appendLog("WB: \(msg)")
            // We just rewrote video.adj.red/blue on the camera — re-read them so
            // the Match-SDI Ethernet develop tracks the new SDI look immediately.
            self.refreshCameraColor()
        }
    }

    /// Mean raw R/G/B (0–255) of a ~24px GBRG region around a relative point —
    /// the honest sensor values for white balance, before any display processing.
    static func rawPatchRGB(in frame: PhantomFrame, rx: Double, ry: Double) -> (r: Double, g: Double, b: Double)? {
        let w = frame.width, h = frame.height
        guard w >= 4, h >= 4, frame.pixels.count >= w * h else { return nil }
        let cx = min(max(Int(rx * Double(w)), 12), w - 13)
        let cy = min(max(Int(ry * Double(h)), 12), h - 13)
        return frame.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Double, Double, Double)? in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            var sr = 0, sg = 0, sb = 0, n = 0
            var y = (cy & ~1) - 12
            while y < cy + 12 {
                let r0 = p + y * w, r1 = p + (y + 1) * w   // G B / R G
                var x = (cx & ~1) - 12
                while x < cx + 12 {
                    sg += Int(r0[x]) + Int(r1[x + 1])
                    sb += Int(r0[x + 1]) * 2
                    sr += Int(r1[x]) * 2
                    n += 2
                    x += 2
                }
                y += 2
            }
            guard n > 0 else { return nil }
            return (Double(sr) / Double(n), Double(sg) / Double(n), Double(sb) / Double(n))
        }
    }

    /// Mean RGB of a ~25px patch around the given relative point, in the
    /// signal's own (gamma-encoded) domain — measured on the Flex: the
    /// video.adj gains multiply the encoded signal ~linearly (red 1553→1024
    /// moved the red channel by the same ratio), so NO linearization here.
    /// A second click converges any residual.
    static func averagePatch(in img: CGImage, rx: Double, ry: Double) -> (r: Double, g: Double, b: Double)? {
        let n = 25
        let cx = Int(rx * Double(img.width)), cy = Int(ry * Double(img.height))
        let x0 = min(max(cx - n / 2, 0), max(img.width - n, 0))
        let y0 = min(max(cy - n / 2, 0), max(img.height - n, 0))
        let w = min(n, img.width), h = min(n, img.height)
        guard let crop = img.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            r += Double(buf[i]) / 255
            g += Double(buf[i + 1]) / 255
            b += Double(buf[i + 2]) / 255
        }
        let cnt = Double(w * h)
        return (r / cnt, g / cnt, b / cnt)
    }

    /// Right-click action: push current UI settings to one specific partition.
    func applySettings(toCine n: Int) {
        guard n > 0 else { return }
        let w = resWidth, h = resHeight, r = max(frameRate, 10), pt = postTriggerFrames
        let periodNS = 1e9 / Double(r)
        let expNS = Int(min(periodNS * 0.997, max(1000.0, (shutterAngle / 360.0) * periodNS)))
        runCommandAsync { conn -> Int in
            var ok = 0
            for c in ["set c\(n).res \(w) x \(h)", "set c\(n).rate \(r)",
                      "set c\(n).exp \(expNS)", "set c\(n).ptframes \(pt)"] {
                ok += (try conn.command(c)).contains("Ok") ? 1 : 0
            }
            return ok
        } onResult: { [weak self] ok in
            self?.appendLog("applied settings to c\(n) (\(ok ?? 0)/4 ok)")
            self?.refreshAll()
        }
    }

    /// Commit a user-chosen frame rate AND nudge the operator to re-do the black
    /// reference. The sensor's black shade (fixed-pattern-noise calibration) is
    /// rate-dependent, so changing the frame rate makes the existing one stale —
    /// and on a camera with no working shutter (e.g. Flex #10706) that can only be
    /// redone by hand with the lens capped, so the app can't do it automatically.
    /// Fires only on an ACTUAL change from this user-action path; telemetry syncs
    /// of `frameRate` never trigger it (they update `committedFrameRate` instead).
    func applyFrameRate(_ r: Int) {
        let changed = committedFrameRate != 0 && r != committedFrameRate
        frameRate = r
        committedFrameRate = r
        applySettings()
        if changed {
            // The old black reference no longer matches this rate — mark it stale
            // (also re-arms the "black balance first?" gate before a white balance)
            // and pop a center-screen reminder that can run the black ref in place.
            blackRefDone = false
            blackShadeReminderRate = r
            showBlackShadeReminder = true
            appendLog("black-ref reminder: frame rate → \(r) fps (black shade may be stale)")
        }
    }

    /// Cines currently holding footage in RAM (stored shots, or a cine mid-capture).
    /// These MUST be wiped before a repartition: re-slicing camera memory while RAM
    /// is occupied leaves the live-view buffer mis-aligned and garbles the SDI
    /// ("quadrupled" image — VERIFIED on Flex 2K, esp. high→low partition changes).
    private func ramFootageCineIDs() -> [Int] {
        cines.filter {
            $0.id > 0 && ($0.state == .stored || $0.state == .waitTrigger || $0.state == .postTrigger)
        }.map(\.id)
    }

    /// Wipe RAM footage, then give the camera a beat to ACTUALLY release the
    /// memory before an alloc/partition re-slice. The settle delay is the crucial
    /// part — a fast clear-then-realloc still reproduces the garble. Runs on the
    /// camera queue (a background serial queue), so nothing else can interleave and
    /// the sleep never touches the UI thread.
    /// Settle time (seconds) the camera needs to fully release RAM after a clear
    /// before it can re-slice memory without garbling the live view. Bumped from
    /// 1.5→3.0 (Buddy still saw a pixelated SDI after a shrink with takes in RAM).
    static let repartitionSettleSeconds: Double = 3.0

    private static func clearRAMBeforeRepartition(_ conn: CameraConnection, ids: [Int]) {
        guard !ids.isEmpty else { return }
        for n in ids { _ = try? conn.command("del {cine:\(n)}") }
        Thread.sleep(forTimeInterval: repartitionSettleSeconds)
    }

    func setPartitions(_ count: Int) {
        // Snapshot RAM footage on the main actor before hopping to the camera
        // queue; both repartition paths wipe it first + settle (see above).
        let occupiedIDs = ramFootageCineIDs()
        // VEO-class cameras take a direct partition count; Flex-class needs
        // the alloc memory-slicing dance (from PCC packet capture).
        if supportsCinesVar {
            // The VEO repartition verb is `partition <N>` — NOT `set cam.cines`.
            // `set cam.cines N` is silently no-op'd ("Ok!" but cam.cines stays
            // put); the body confirms it as a destructive op. `partition N`
            // applies immediately AND auto-arms every cine (c0 live, c1..cN RDY),
            // so no follow-up state writes are needed. (Verified live on VEO4K.)
            runCommandAsync { conn -> String in
                CameraModel.clearRAMBeforeRepartition(conn, ids: occupiedIDs)
                return try conn.command("partition \(count)", timeout: 5.0)
            } onResult: { [weak self] result in
                self?.appendLog("partitions → \(count): \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
                self?.finishRepartition(count)
            }
            return
        }
        guard cineMem > 0, count >= 1 else { return }
        let per = cineMem / count
        let list = Array(repeating: "\(per)", count: count).joined(separator: ",")
        runCommandAsync { conn -> String in
            // Clear any unsaved RAM shots and let the camera free the memory BEFORE
            // re-slicing it — without this the live-view buffer mis-aligns and the
            // SDI garbles (verified on the Flex). alloc erases RAM anyway, so this
            // costs nothing but the settle delay.
            CameraModel.clearRAMBeforeRepartition(conn, ids: occupiedIDs)
            let resp = try conn.command("alloc {\(list)}", timeout: 5.0)
            _ = try? conn.command("set c0.state { PRE ACT }")
            for i in 1...count {
                _ = try? conn.command("set c\(i).state { RDY ABL }")
            }
            // Second settle: let the freshly re-sliced cines + live buffer stabilize
            // before the app re-applies res/rate/exp on top (finishRepartition).
            Thread.sleep(forTimeInterval: 1.0)
            return resp
        } onResult: { [weak self] result in
            let cleared = occupiedIDs.isEmpty ? "" : " (cleared \(occupiedIDs.count) RAM shot\(occupiedIDs.count == 1 ? "" : "s") first)"
            self?.appendLog("alloc \(count) partitions\(cleared): \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
            self?.finishRepartition(count)
        }
    }

    /// After a repartition (which erases RAM and re-arms every cine), the old
    /// in/out marks were sized for the previous partition length, so clear them
    /// to the new clip range — but re-apply the user's settings (incl. the
    /// trigger position) so the freshly armed partitions keep what was set.
    private func finishRepartition(_ count: Int) {
        // Reflect the freshly re-sliced layout LOCALLY before applySettings runs.
        // The re-slice re-armed the camera as c0=live + c1..cN=ready with NO
        // rolling (waitTrigger) cine. If we let applySettings read the STALE
        // pre-repartition list, it finds the old rolling cine (e.g. c4) and does
        // `rec {cine:4}` — but after a shrink c4 is OUT OF RANGE, which re-creates
        // a phantom active cine and corrupts the live feed ("outside range" + a
        // black/pixelated SDI). Seeding the new layout makes applySettings' restart
        // target nil, so it can't re-arm a partition that no longer exists.
        cines = [CineSlot(id: 0, flags: ["PRE", "ACT"])] +
                (1...count).map { CineSlot(id: $0, flags: ["RDY", "ABL"]) }
        if selectedCine > count { selectedCine = 1 }   // old selection may be gone
        applySettings()                                // re-push res/rate/exp/trigger position
        refreshCineStates()                            // reconcile with the camera's real state
        refreshSelectedCineRange(resetTrim: true)      // reset in/out to the new range
    }

    // MARK: - Playback

    /// Builds the right vplay for the current playback source (PVP scrubs mag
    /// takes with exactly this single-frame form, per packet capture).
    private func vplayCmd(first: Int, last: Int) -> String {
        switch playbackSource {
        case .ram(let n):
            return "vplay {cine:\(n), firstframe:\(first), lastframe:\(last)}"
        case .mag(let idx):
            // Mag takes are addressed DIRECTLY by their flash index with
            // `from:mag` — 0-based, NO partition offset. (Verified live on the
            // Flex: 10-take mag → cine:0…9 Ok, cine:10 "invalid cine number";
            // the old partitionCount+1+idx scheme always errored.)
            return "vplay {cine:\(idx), firstframe:\(first), lastframe:\(last), from:mag}"
        }
    }

    /// Applies a speed multiplier to the camera's SDI playback IN PLACE — no
    /// vplay restart, so the speed slider ramps mid-clip. Verified on the Flex:
    /// `video.play.step N` skips frames (N× fast), `video.play.speed N` divides
    /// (1/N slow-mo), they combine multiplicatively (speed:2 step:3 → 1.5×),
    /// and both persist across vplay re-issues (loops keep the ramp).
    /// (`vplay {rate:}` does NOT exist on this firmware — rejected.)
    private func applyPlaybackSpeed(_ m: Double) {
        let speed: Int, step: Int
        if m >= 1 {
            // Quantize to half-steps: whole multiples ride step alone; the
            // in-betweens (1.5×, 2.5×…) use step over speed:2.
            let halves = max(2, Int((m * 2).rounded()))
            if halves % 2 == 0 { speed = 1; step = halves / 2 }
            else { speed = 2; step = halves }
        } else {
            speed = max(1, Int((1 / max(m, 0.01)).rounded())); step = 1
        }
        sendSimple("set video.play {speed:\(speed), step:\(step)}", label: nil)
    }

    var playbackIsMag: Bool {
        if case .mag = playbackSource { return true }
        return false
    }

    /// Frame range the deck timeline spans, for whichever source is loaded.
    var playbackRange: (lo: Double, hi: Double) {
        switch playbackSource {
        case .ram(let n):
            let slot = cines.first(where: { $0.id == n })
            let lo = Double(slot?.firstFrame ?? 0)
            return (lo, max(Double(slot?.lastFrame ?? 1), lo + 1))
        case .mag(let idx):
            let t = magTakes.first(where: { $0.id == idx })
            let lo = Double(t?.firstFrame ?? 0)
            return (lo, max(Double(t?.lastFrame ?? 1), lo + 1))
        }
    }

    var playbackSourceLabel: String {
        switch playbackSource {
        case .ram(let n): return "C\(n)"
        case .mag(let idx): return "\(idx + 1)F"
        }
    }

    /// Switches the deck to a CineMag take: range, playhead, and all transport
    /// controls then drive the mag clip — independent of RAM state.
    func selectMagTake(_ take: MagTake) {
        playbackSource = .mag(take.id)
        mode = .play
        inPoint = Double(take.firstFrame)
        outPoint = Double(take.lastFrame)
        playFrame = Double(take.firstFrame)
        isPlaying = false
        playTask?.cancel(); playTask = nil
        // A mag take plays out the camera's SDI (it can't stream over Ethernet
        // on this firmware) — switch the viewer to SDI so it shows here. If the
        // SDI capture isn't running, say so instead of silently doing nothing.
        if sdi.isRunning {
            viewerSource = .sdi
        } else {
            appendLog("mag take \(take.label): playing on the camera's SDI out — connect the SDI capture to see it in the viewer")
        }
        sendSimple(vplayCmd(first: take.firstFrame, last: take.firstFrame), label: "deck → mag \(take.label)")
    }

    /// `fullClip` ignores the in/out trim and loops the whole recorded clip —
    /// used by review/auto-playback, where the trim is for the edit, not review.
    /// `from` overrides where playback begins (an absolute frame).
    private var playFullClip = false
    private var reviewLo = 0, reviewHi = 0

    // MARK: Offline clip playback on the Video Out monitor

    /// Plays a downloaded clip on the existing Video Out window. Prefers the SDI
    /// PROXY .mov (smooth, hardware-decoded, baked-in color) and falls back to
    /// decoding the raw .cine only if no proxy exists. Opening the windows is the
    /// caller's job. Returns to live when stopped.
    func playClipOnVideoOut(_ clip: ClipEntry) {
        stopOfflinePlayback()
        offlineClip = clip
        offlineClipURL = clip.url
        lastOfflineClip = clip
        if let proxy = clip.proxyURL, !preferRawPlayback {
            startProxyPlayback(proxy, clip: clip)
        } else {
            startCinePlayback(clip.url)
        }
    }

    /// Transcodes a downloaded .cine into a sibling .mov proxy (H.264) so clips
    /// that were offloaded without proxy-on-download still get a smooth, small
    /// viewing copy. Runs off the main thread; publishes progress.
    func generateProxy(for clip: ClipEntry, completion: (() -> Void)? = nil) {
        guard clip.proxyURL == nil, proxyGenClip == nil else { return }
        let out = clip.url.deletingPathExtension().appendingPathExtension("mov")
        proxyGenClip = clip.url
        proxyGenProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let reader = try CineReader(url: clip.url)
                let settings = Debayer16.RenderSettings(info: reader.info)
                let opts = CineTranscoder.Options(codec: .h264, fps: reader.info.playbackFPS,
                                                  settings: settings, info: reader.info)
                var lastReported = -1
                try CineTranscoder(reader: reader).transcode(to: out, options: opts) { p in
                    let pct = Int(p * 100)
                    if pct != lastReported {
                        lastReported = pct
                        Task { @MainActor in self?.proxyGenProgress = p }
                    }
                    return true
                }
                await MainActor.run {
                    self?.proxyGenProgress = nil; self?.proxyGenClip = nil
                    self?.appendLog("proxy generated → \(out.lastPathComponent)")
                    completion?()
                }
            } catch {
                await MainActor.run {
                    self?.proxyGenProgress = nil; self?.proxyGenClip = nil
                    self?.appendLog("proxy generation failed: \(error)")
                }
            }
        }
    }

    /// Smooth, color-baked path: one AVPlayer shared by Video Out + the Clip
    /// Playback window (so they stay in sync), looping.
    private func startProxyPlayback(_ url: URL, clip: ClipEntry) {
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .none
        proxyEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero); p.play()
        }
        // Map the playhead time → an approximate clip frame for the heads-up.
        let total = Int(clip.lookup["Frames"] ?? "") ?? 0
        proxyTimeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 12), queue: .main) { [weak self, weak p] t in
            guard let self, let item = p?.currentItem else { return }
            let dur = item.duration.seconds
            guard dur.isFinite, dur > 0 else { return }
            let frac = min(max(t.seconds / dur, 0), 1)
            self.proxyFrac = frac
            self.proxyFrame = total > 0 ? Int((frac * Double(total - 1)).rounded()) : Int(t.seconds * 1000)
        }
        proxyPlayer = p
        proxyPlaying = true
        p.play()
        appendLog("Video Out playback (proxy) → \(url.lastPathComponent)")
    }

    /// Fallback path: decode the raw .cine on the Mac (slower, ungraded).
    private func startCinePlayback(_ url: URL) {
        let p = CinePlayerModel(url: url)
        p.loopPlayback = true
        offlinePlayer = p
        offlineImageCancel = p.$image.receive(on: RunLoop.main).sink { [weak self] img in
            self?.offlineImage = img
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { p.play() }
        appendLog("Video Out playback (raw .cine) → \(url.lastPathComponent)")
    }

    /// Generates proxies for every clip that doesn't have one, one at a time
    /// (transcoding is heavy). Safe to call while one is already running.
    func generateAllProxies(_ clips: [ClipEntry]) {
        guard proxyGenClip == nil else { return }
        proxyQueueAdvance(clips.filter { $0.proxyURL == nil }, 0)
    }
    private func proxyQueueAdvance(_ list: [ClipEntry], _ i: Int) {
        guard i < list.count else { return }
        generateProxy(for: list[i]) { [weak self] in
            self?.proxyQueueAdvance(list, i + 1)
        }
    }

    /// Stops offline playback; the Video Out window returns to the live/RAM feed.
    func stopOfflinePlayback() {
        if let obs = proxyTimeObserver { proxyPlayer?.removeTimeObserver(obs); proxyTimeObserver = nil }
        if let obs = proxyEndObserver { NotificationCenter.default.removeObserver(obs); proxyEndObserver = nil }
        proxyPlayer?.pause(); proxyPlayer = nil
        proxyFrame = 0; proxyFrac = 0
        offlineImageCancel?.cancel(); offlineImageCancel = nil
        offlinePlayer?.shutdown(); offlinePlayer = nil
        offlineImage = nil
        offlineClip = nil
        offlineClipURL = nil
    }

    /// Hotkey toggle (C): if a clip is playing on Video Out, go back to live;
    /// otherwise replay the last clip that was shown there.
    func toggleOfflinePlayback() {
        if isPlayingOffline {
            stopOfflinePlayback()
        } else if let clip = lastOfflineClip {
            playClipOnVideoOut(clip)
        }
    }

    private var playRangeRetried = false
    func startPlayback(from startFrame: Int? = nil, fullClip: Bool = false) {
        guard !isPlaying else { return }
        // The clip's frame range must be loaded first, or `vplay` runs 0…0 and
        // the SDI sticks at frame zero — this is why iPad playback failed right
        // after a record until the laptop played first (which primed the range).
        // Load it on demand, then retry once.
        let r = playbackRange
        if r.hi <= r.lo + 1 {
            if !playRangeRetried {
                playRangeRetried = true
                refreshSelectedCineRange(then: { [weak self] in
                    self?.startPlayback(from: startFrame, fullClip: fullClip)
                })
            } else {
                playRangeRetried = false
                appendLog("play: clip C\(selectedCine) has no frames yet")
            }
            return
        }
        playRangeRetried = false
        stopOfflinePlayback()  // camera reclaims the Video Out monitor
        playFullClip = fullClip
        let n = selectedCine
        let clipLo = fullClip ? Int(playbackRange.lo) : Int(inPoint)
        let hi = fullClip ? Int(playbackRange.hi) : Int(outPoint)
        // Where to begin: an explicit start frame, else the playhead if in range.
        // The camera `vplay` must START there too — otherwise SDI playback begins
        // at the clip top and the software jump is invisible.
        let start: Int = {
            if let s = startFrame { return min(max(s, clipLo), hi) }
            let p = Int(playFrame)
            return (p >= clipLo && p < hi) ? p : clipLo
        }()
        // Review plays FROM the start frame and loops from there. The in/out
        // SAVE range (gold marks) is never touched here, so the stored RAM
        // partition stays fully open — only the live playback begins at the hero.
        reviewLo = start; reviewHi = hi
        playFrame = Double(start)
        let startSpeed = playbackSpeed
        sendSimple(vplayCmd(first: start, last: hi), label: "play")
        // Always push the speed (even at 1×) so a leftover ramp from the last
        // session can't haunt this one — step/speed persist camera-side.
        applyPlaybackSpeed(startSpeed)
        isPlaying = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else { return }
            var f = start
            var lastSpeed = startSpeed   // re-issue the SDI vplay only when this changes
            while !Task.isCancelled {
                // Read range live each pass so in/out can move during normal playback.
                let (playing, scrubbing, first, last, loop, eth, speed) = await MainActor.run {
                    let r = self.playFullClip ? (self.reviewLo, self.reviewHi)
                                              : (Int(self.inPoint), Int(self.outPoint))
                    return (self.isPlaying, self.isScrubbing, r.0, r.1,
                            self.loopPlayback,
                            // Mag takes can't stream over Ethernet on this firmware —
                            // their playback lives on the camera/SDI side only.
                            !self.playbackIsMag && (self.viewerSource == .ethernet || !self.sdi.isRunning),
                            self.playbackSpeed)
                }
                guard playing else { break }
                if scrubbing {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    f = await MainActor.run { Int(self.playFrame) }
                    continue
                }
                if f < first { f = first }
                if eth {
                    await self.fetchPlaybackFrame(cine: n, frame: f)
                    await MainActor.run { self.playFrame = Double(f) }
                    // Speed ≥ 1× skips frames to go faster; < 1× adds dwell time.
                    f += speed >= 1 ? max(1, Int(speed.rounded())) : 1
                    if speed < 1 {
                        let extra = UInt64((1.0 / speed - 1.0) * 33_000_000)
                        if extra > 0 { try? await Task.sleep(nanoseconds: extra) }
                    }
                } else {
                    // SDI plays camera-side — ramp its speed in place when the
                    // slider moves (no vplay restart, playback never jumps).
                    if speed != lastSpeed {
                        lastSpeed = speed
                        await MainActor.run { self.applyPlaybackSpeed(speed) }
                    }
                    // SDI playback runs on the camera — track its real frame
                    // number (PVP does the same via video.play.fn).
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let fn: Int? = await withCheckedContinuation { cont in
                        Task { @MainActor in
                            self.runCommandAsync { conn in
                                PhantomProtocol.find("fn", in: try conn.get("video.play.fn"))?.intValue
                            } onResult: { v in cont.resume(returning: v ?? nil) }
                        }
                    }
                    if let fn {
                        await MainActor.run { self.playFrame = Double(fn) }
                        f = fn + 1
                    } else {
                        f += 1
                    }
                }
                if f > last {
                    if loop {
                        f = first
                        if !eth {
                            // Camera-side playback needs a fresh vplay per loop —
                            // but NEVER after a Go Live raced past us. (speed/step
                            // persist across vplay, so the ramp carries into the loop.)
                            let stillPlaying = await MainActor.run { self.isPlaying && !Task.isCancelled }
                            if stillPlaying {
                                await MainActor.run {
                                    self.sendSimple(self.vplayCmd(first: first, last: last), label: nil)
                                }
                            }
                        }
                    } else {
                        await MainActor.run { self.isPlaying = false }
                        break
                    }
                }
            }
        }
    }

    /// Returns the camera's video output to the live image (PVP's Live button:
    /// `set video.play.live:1`) and puts the app back in Live mode.
    func goLive() {
        stopOfflinePlayback()  // Video Out returns to the live feed
        isPlaying = false
        autoJumpWork?.cancel()
        playTask?.cancel(); playTask = nil
        sendSimple("set video.play.live:1", label: "go live")
        // Re-assert shortly after — a vplay queued by the play loop can land
        // behind the first go-live on the camera and flip it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendSimple("set video.play.live:1", label: nil)
        }
        mode = .live
        startLiveLoop()
    }

    /// Resets the in/out trim marks to the full clip (clears any trimming).
    func clearInOut() {
        let (lo, hi) = playbackRange
        inPoint = lo
        outPoint = hi
    }

    func markIn() {
        inPoint = min(playFrame, outPoint)
    }

    func markOut() {
        outPoint = max(playFrame, inPoint)
    }

    func stopPlayback() {
        isPlaying = false
        autoJumpWork?.cancel()
        playTask?.cancel(); playTask = nil
        sendSimple(vplayCmd(first: Int(playFrame), last: Int(playFrame)), label: "pause")
    }

    func stepFrame(_ delta: Int) {
        if isPlaying { stopPlayback() }
        let f = min(max(Int(playFrame) + delta, Int(inPoint)), Int(outPoint))
        playFrame = Double(f)
        scrub(to: f)
    }

    /// Picks a partition and immediately shows it: a stored clip jumps the SDI /
    /// playback to that cine; a recording or empty partition goes live. (id 0 =
    /// the LIVE chip → live.)
    func selectCine(_ n: Int) {
        guard n > 0 else { goLive(); return }
        selectedCine = n
        let slot = cines.first(where: { $0.id == n })
        if slot?.state == .stored {
            // Force the source back to RAM. selectedCine's didSet only flips
            // playbackSource to .ram on a CHANGE — but playing a CineMag take
            // leaves selectedCine untouched, so re-clicking the already-selected
            // partition wouldn't fire it, leaving playbackSource = .mag and just
            // replaying the mag take (the "go Live and back" bug). Set it here.
            playbackSource = .ram(n)
            mode = .play
            refreshSelectedCineRange(resetTrim: true)
            goToFrame(slot?.firstFrame ?? 0)   // push this cine to the SDI now
        } else {
            // Recording (red) or empty/ready — nothing to review, show live.
            goLive()
        }
    }

    /// Jumps the playhead to an absolute frame number and shows it (no playback).
    /// Frame numbers are partition-absolute, so they line up with a synced robot
    /// move (robot frame 0 = Phantom frame 0).
    func goToFrame(_ frame: Int) {
        let (lo, hi) = playbackRange
        let f = min(max(Double(frame), lo), hi)
        if isPlaying { stopPlayback() }
        playFrame = f
        scrub(to: Int(f))
    }

    /// "Auto review" playback. The VEO can't move the playhead without moving
    /// the SDI playback start, so a direct vplay from the hero frame looks like
    /// the clip got trimmed. Instead: the camera starts playing from the clip
    /// START (SDI clearly shows the full clip), then a beat later the SOFTWARE
    /// jumps the playhead to the hero frame — reading as a software jump, not a
    /// camera trim. The in/out save range is never touched (stays full clip).
    private var autoJumpWork: DispatchWorkItem?
    /// "Go to, then play" — exactly what you'd do by hand: scrub the playhead to
    /// the hero frame (the timeline-slider action), wait a beat for the software
    /// + VEO to settle, then hit the normal Play button. This tool sends NO
    /// custom signal to the camera — Play loops the full in/out range, so the
    /// camera's playback reopens to the whole clip (no stuck "trimmed" range),
    /// and the save in/out is never touched.
    func playFromFrame(_ frame: Int) {
        autoJumpWork?.cancel()
        if isPlaying { stopPlayback() }
        let (lo, hi) = playbackRange
        let hero = Int(min(max(Double(frame), lo), hi))
        goToFrame(hero)                                   // scrub slider → hero
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.startPlayback()                          // press Play (normal)
        }
        autoJumpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Sets the trim out point to an absolute frame (typed), clamped to the clip.
    func setOutFrame(_ frame: Int) {
        let (lo, hi) = playbackRange
        outPoint = min(max(Double(frame), max(inPoint, lo)), hi)
    }
    /// Sets the trim in point to an absolute frame (typed), clamped to the clip.
    func setInFrame(_ frame: Int) {
        let (lo, hi) = playbackRange
        inPoint = min(max(Double(frame), lo), min(outPoint, hi))
    }

    /// Auto-playback: when on, a finished recording starts playing back on its
    /// own from `autoPlayStartFrame` (absolute), so a synced robot move can be
    /// reviewed from the hero frame hands-free.
    @Published var autoPlayEnabled = false
    @Published var autoPlayStartFrame = 0

    private var scrubFetchInFlight = false
    private var lastScrubSend = Date.distantPast

    /// Called continuously while the playhead is dragged: keeps the SDI and
    /// the in-app picture following the finger, throttled so the camera and
    /// the Ethernet pipe keep up.
    func liveScrub(to frame: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastScrubSend) > 0.08 else { return }
        lastScrubSend = now
        sendSimple(vplayCmd(first: frame, last: frame), label: nil)
        // In-app frame preview (RAM sources only); skip if a fetch is mid-air.
        guard !playbackIsMag, viewerSource == .ethernet || !sdi.isRunning, !scrubFetchInFlight else { return }
        scrubFetchInFlight = true
        let n = selectedCine
        Task { [weak self] in
            await self?.fetchPlaybackFrame(cine: n, frame: frame)
            await MainActor.run { self?.scrubFetchInFlight = false }
        }
    }

    func scrub(to frame: Int) {
        sendSimple(vplayCmd(first: frame, last: frame), label: nil)
        // In-app frame fetch is RAM-only; mag scrubs show on the SDI.
        guard !playbackIsMag, viewerSource == .ethernet else { return }
        let n = selectedCine
        Task { [weak self] in await self?.fetchPlaybackFrame(cine: n, frame: frame) }
    }

    private func fetchPlaybackFrame(cine: Int, frame: Int) async {
        let wb = Debayer.WhiteBalance(red: Float(wbRed), green: 1.0, blue: Float(wbBlue))
        let g = Float(gain)
        let pk = await MainActor.run { self.focusPeaking }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runCommandAsync { conn -> (CGImage?, PhantomFrame) in
                let f = try conn.grabFrame(cine: cine, start: frame)
                return (Debayer.halfResBGRA(frame: f, wb: wb, gain: g, peaking: pk), f)
            } onResult: { [weak self] result in
                if let (image, raw) = result {
                    self?.lastRawFrame = raw
                    if let image { self?.viewerImage = image }
                    if let self, let l = Self.meanLuma(of: raw) {
                        // Playback steps through consecutive RECORDED frames, so
                        // these samples are 1/record-rate apart — true flicker.
                        self.flicker.sampleRateHz = Double(self.frameRate)
                        self.flicker.push(meanLuma: l)
                    }
                }
                cont.resume()
            }
        }
    }

    /// Reads consecutive recorded frames at the record rate, feeding each to the
    /// flicker detector live so the Hz/amplitude reading converges as it goes
    /// (an "averaging" scan). Stoppable any time with `stopFlickerScan()`.
    @Published var flickerScanning = false
    private var flickerScanCancel = false
    func scanFlickerOnClip(frames: Int = 400) {
        guard !flickerScanning, selectedCine > 0 || playbackIsMag else { return }
        let n = selectedCine
        let startFrame = Int(playFrame)
        let rate = frameRate
        flickerScanning = true
        flickerScanCancel = false
        flicker.forceSampling = true
        flicker.reset()
        flicker.sampleRateHz = Double(rate)
        runCommandAsync { [weak self] conn -> Int in
            var idx = startFrame, count = 0
            while count < frames {
                if self?.flickerScanCancel ?? true { break }          // read on bg; Bool is fine
                guard let f = try? conn.grabFrame(cine: n, start: idx) else { break }   // clip end
                if let l = CameraModel.meanLuma(of: f) {
                    Task { @MainActor in self?.flicker.push(meanLuma: l) }
                }
                count += 1; idx += 1
            }
            return count
        } onResult: { [weak self] c in
            guard let self else { return }
            self.flicker.forceSampling = false
            self.flickerScanning = false
            let r = self.flicker.reading
            self.appendLog("flicker scan: \(c ?? 0) frames — \(r.flickering ? "DETECTED \(Int(r.frequencyHz)) Hz" : "clean")")
        }
    }

    /// Ends an in-progress flicker scan, keeping whatever it has measured so far.
    func stopFlickerScan() { flickerScanCancel = true }

    // MARK: - Download

    /// Downloads the selected cine's in/out range as a .cine file.
    func downloadSelectedCine() {
        downloadCine(selectedCine, first: Int(inPoint), last: Int(outPoint))
    }

    // MARK: - CineMag offload station (thumbnails, options, batch) — the same
    // treatment as the CineStation window, but over the camera's own GigE.

    @Published var magThumbs: [Int: CGImage] = [:]
    @Published var magThumbHeight: Double = UserDefaults.standard.object(forKey: "magThumbHeight") as? Double ?? 45 {
        didSet { UserDefaults.standard.set(magThumbHeight, forKey: "magThumbHeight") }
    }
    @Published var magMakeProxy = UserDefaults.standard.object(forKey: "magProxy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(magMakeProxy, forKey: "magProxy") }
    }
    @Published var magClipPDF = UserDefaults.standard.object(forKey: "magClipPDF") as? Bool ?? true {
        didSet { UserDefaults.standard.set(magClipPDF, forKey: "magClipPDF") }
    }
    @Published var magConvert: String = UserDefaults.standard.string(forKey: "magConvert") ?? "None" {
        didSet { UserDefaults.standard.set(magConvert, forKey: "magConvert") }
    }
    @Published var magDownloadedTakes: Set<Int> = []
    @Published var magDownloadingTake: Int?
    // Per-take trim range (trigger-relative frames). Absent = whole take.
    @Published var magTrimIn: [Int: Int] = [:]
    @Published var magTrimOut: [Int: Int] = [:]
    @Published var magQueuedTakes: [Int] = []
    @Published var magBatchTotal = 0
    @Published var magClipPDFs: [Int: URL] = [:]
    @Published var magLastReport: URL?
    private var magThumbFetchRunning = false
    private var magBatchActive = false

    /// Pulls the middle frame of every take without a thumbnail (one
    /// `img cnt:1 fmt:flash` read each) on its own connection, develops it, and
    /// caches a poster. Yields the moment a download/erase starts.
    func fetchMagThumbnails() {
        guard connected, !magThumbFetchRunning, downloadProgress == nil, magBusy == nil else { return }
        let missing = magTakes.filter { magThumbs[$0.id] == nil && $0.width > 0 && $0.height > 0 }
        guard !missing.isEmpty else { return }
        magThumbFetchRunning = true
        let host = self.host
        Thread.detachNewThread { [weak self] in
            func ui(_ b: @escaping @MainActor () -> Void) { Task { @MainActor in b() } }
            defer { ui { [weak self] in self?.magThumbFetchRunning = false } }
            let c = CameraConnection(host: host)
            do {
                try c.connect(); try c.startDataChannel()
                for take in missing {
                    let stop = DispatchQueue.main.sync { [weak self] () -> Bool in
                        self == nil || self?.downloadProgress != nil || self?.magBusy != nil
                    }
                    if stop { break }   // downloads own the wire — step aside
                    let mid = take.firstFrame + (take.lastFrame - take.firstFrame) / 2
                    guard let packed = try? c.grabFramesFlash(cine: take.id, start: mid, count: 1,
                                                              width: take.width, height: take.height),
                          let img = MagOffload.developThumbnail(packed10: packed,
                                                                width: take.width, height: take.height)
                    else { continue }
                    ui { [weak self] in self?.magThumbs[take.id] = img }
                }
            } catch { }
            c.close()
        }
    }

    /// End-of-day: queue every not-yet-downloaded take, pull them in turn, then
    /// roll one combined DIT report.
    func downloadAllMagTakes() {
        guard connected, downloadProgress == nil, magBusy == nil else { return }
        let pending = magTakes.map(\.id).filter { !magDownloadedTakes.contains($0) }
        guard !pending.isEmpty else { return }
        magQueuedTakes = pending
        magBatchTotal = pending.count
        magBatchActive = true
        pumpMagDownloadQueue()
    }

    private func pumpMagDownloadQueue() {
        guard downloadProgress == nil else { return }
        guard !magQueuedTakes.isEmpty else {
            if magBatchActive {
                magBatchActive = false
                let clips = projectClips()
                if !clips.isEmpty {
                    downloadStatus = "Building DIT report…"
                    exportReport(clips) { [weak self] pdf in
                        self?.magLastReport = pdf
                        self?.downloadStatus = "Batch complete — report: \(pdf.lastPathComponent)"
                    }
                }
            }
            fetchMagThumbnails()
            return
        }
        let next = magQueuedTakes.removeFirst()
        if let take = magTakes.first(where: { $0.id == next }) { downloadMagTake(take) }
        else { pumpMagDownloadQueue() }
    }

    /// Downloads a CineMag take from the CAMERA to the project folder — the
    /// camera-side twin of the CineStation offload. TCP `img fmt:flash` loop
    /// (pcap-verified against PCC), full treatment: verify (MD5 sidecar), poster
    /// thumbnail, optional GPU proxy + format convert, metadata sidecars, and a
    /// per-clip PDF. ~40 MB/s on the Flex's GigE.
    func downloadMagTake(_ take: MagTake) {
        guard downloadProgress == nil else { return }
        let host = self.host
        let doVerify = verifyDownloads
        let doProxy = magMakeProxy
        let doPDF = magClipPDF
        let convertName = magConvert
        let wantIn = magTrimIn[take.id], wantOut = magTrimOut[take.id]
        downloadCancelled = false
        downloadProgress = 0
        downloadStatus = "Connecting…"
        magOpResult = nil
        magDownloadingTake = take.id
        let stem = take.name.isEmpty ? "Mag_\(take.label)" : take.name.replacingOccurrences(of: "/", with: "-")
        let dest = destinationURL(defaultBase: stem, ext: "cine")
        let name = dest.lastPathComponent
        Thread.detachNewThread { [weak self] in
            func ui(_ b: @escaping @MainActor () -> Void) { Task { @MainActor in b() } }
            let conn = CameraConnection(host: host)
            do {
                try conn.connect()
                try conn.startDataChannel()
                let fc = try conn.get("fc\(take.id)")
                guard let res = PhantomProtocol.find("res", in: fc)?.sizeValue else {
                    throw PhantomError.protocolError("no res for mag take \(take.label)")
                }
                let fullFirst = PhantomProtocol.find("firstfr", in: fc)?.intValue ?? take.firstFrame
                let fullLast = PhantomProtocol.find("lastfr", in: fc)?.intValue ?? take.lastFrame
                // Apply the trim (clamped to the take's real bounds) if one is set.
                let first = min(max(wantIn ?? fullFirst, fullFirst), fullLast)
                let last = max(min(wantOut ?? fullLast, fullLast), first)
                // Identity + develop come from the take itself (shooting camera) — the
                // fcN struct carries the baked adj{} snapshot from record time. Stamp its
                // WB / tone / colour matrix into the .cine (unknown fields → template).
                let fcadj = PhantomProtocol.find("adj", in: fc)?.dictValue ?? [:]
                var wbR: Float = 0, wbB: Float = 0
                if let r = PhantomProtocol.find("wbred", in: fcadj)?.doubleValue, r > 0.01,
                   let b = PhantomProtocol.find("wbblue", in: fcadj)?.doubleValue, b > 0.01 {
                    wbR = Float(r); wbB = Float(b)
                } else if let r = PhantomProtocol.find("red", in: fcadj)?.doubleValue, r > 0,
                          let b = PhantomProtocol.find("blue", in: fcadj)?.doubleValue, b > 0 {
                    let g = max(PhantomProtocol.find("green", in: fcadj)?.doubleValue ?? 1, 0.01)
                    wbR = Float(r / g); wbB = Float(b / g)
                }
                let toneStr = PhantomProtocol.find("tone", in: fcadj)?.stringValue
                var cal: [Float] = []
                if let cm = PhantomProtocol.find("cmatrix", in: fcadj)?.stringValue {
                    let nums = cm.split(whereSeparator: { " \"\t".contains($0) }).compactMap { Float($0) }
                    if nums.count >= 9 { cal = Array(nums.suffix(9)) }
                }
                let meta = CineMetadata(
                    width: res.width, height: res.height,
                    frameRate: PhantomProtocol.find("rate", in: fc)?.intValue ?? 24,
                    exposureNs: PhantomProtocol.find("exp", in: fc)?.intValue ?? 0,
                    serial: PhantomProtocol.find("serial", in: fc)?.intValue ?? 0,
                    cfa: PhantomProtocol.find("cfa", in: fc)?.intValue ?? 3,
                    firstImageNo: first, totalFrames: last - first + 1, firstMovieImage: first,
                    triggerSecs: UInt32(truncatingIfNeeded: PhantomProtocol.find("secs", in: fc)?.intValue ?? 0),
                    triggerFrac: UInt32(truncatingIfNeeded: PhantomProtocol.find("frac", in: fc)?.intValue ?? 0),
                    cameraModel: PhantomProtocol.find("model", in: fc)?.stringValue ?? "Phantom",
                    // From the TAKE, not the connected body — a CineMag take may
                    // have been shot on a different camera. 0 when the take struct
                    // doesn't carry hwver, which leaves CameraVersion unset rather
                    // than stamping the wrong camera.
                    cameraVersion: PhantomProtocol.find("hwver", in: fc)?.intValue ?? 0,
                    cineName: dest.deletingPathExtension().lastPathComponent,
                    wbRed: wbR, wbBlue: wbB,
                    toneString: toneStr ?? "", toneKnown: toneStr != nil, calMatrix: cal)
                let t0 = Date()
                try conn.downloadMagCine(cine: take.id, to: dest, meta: meta,
                                         firstFrame: first, lastFrame: last,
                                         cancelled: { [weak self] in self?.downloadCancelled ?? true }) { done, total in
                    let mbps = Double(done * res.width * res.height) * 1.25 / max(Date().timeIntervalSince(t0), 0.01) / 1e6
                    ui { [weak self] in
                        self?.downloadProgress = Double(done) / Double(max(total, 1))
                        self?.downloadStatus = String(format: "Mag %@  %d/%d fr  %.0f MB/s", take.label, done, total, mbps)
                    }
                }
                conn.close()
                var vr = CineVerify.Result(ok: true, message: "not verified", md5: nil)
                if doVerify {
                    ui { [weak self] in self?.downloadProgress = 0; self?.downloadStatus = "Verifying \(name)…" }
                    vr = CineVerify.verify(url: dest, expectedFrames: last - first + 1) { p in
                        ui { [weak self] in self?.downloadProgress = p }
                    }
                    if let md5 = vr.md5 { CineVerify.writeChecksum(md5, for: dest) }
                }
                if vr.ok { ClipThumbnail.generate(for: dest) }
                // Post-steps on the verified file: GPU proxy + optional convert.
                if vr.ok, doProxy, !(self?.downloadCancelled ?? true) {
                    let proxyURL = dest.deletingPathExtension().appendingPathExtension("mov")
                    try? MagOffload.gpuTranscode(src: dest, to: proxyURL, codec: .h264, resolution: .hd1080) { [weak self] pct, fps in
                        ui { self?.downloadProgress = pct
                             self?.downloadStatus = String(format: "Proxy %@… %d%%  (%.0f fps)", take.label, Int(pct*100), fps) }
                        return !(self?.downloadCancelled ?? true)
                    }
                }
                if vr.ok, let codec = GPUTranscoder.Codec(rawValue: convertName), !(self?.downloadCancelled ?? true) {
                    let suffix = convertName.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
                    let outURL = dest.deletingPathExtension().appendingPathExtension("\(suffix).mov")
                    try? MagOffload.gpuTranscode(src: dest, to: outURL, codec: codec, resolution: .full) { [weak self] pct, fps in
                        ui { self?.downloadProgress = pct
                             self?.downloadStatus = String(format: "%@ %@… %d%%  (%.0f fps)", convertName, take.label, Int(pct*100), fps) }
                        return !(self?.downloadCancelled ?? true)
                    }
                }
                ui { [weak self] in
                    guard let self else { return }
                    self.downloadProgress = nil
                    self.magDownloadingTake = nil
                    if vr.ok {
                        self.magDownloadedTakes.insert(take.id)
                        self.writeClipSidecars(url: dest, cine: meta, md5: vr.md5, first: first, last: last)
                        if doPDF { self.makeMagClipPDF(for: take, at: dest) }
                        self.magOpResult = "Downloaded \(take.label) → \(name)\(doVerify ? "  ✓ verified" : "")"
                        self.downloadStatus = self.magOpResult ?? ""
                        self.appendLog("mag take \(take.label) → \(name) (flash TCP)")
                        if doVerify {
                            self.lastVerify = CameraModel.VerifyStatus(ok: true, clip: name, message: "OK")
                        }
                    } else {
                        self.magOpResult = "⚠️ \(take.label) verify FAILED: \(vr.message)"
                        self.downloadStatus = self.magOpResult ?? ""
                        NSSound.beep()
                    }
                    self.pumpMagDownloadQueue()
                }
            } catch {
                conn.close()
                try? FileManager.default.removeItem(at: dest)
                ui { [weak self] in
                    guard let self else { return }
                    self.downloadProgress = nil
                    self.magDownloadingTake = nil
                    self.magOpResult = "Mag download \(take.label) failed: \(error)"
                    self.downloadStatus = "Mag download failed: \(error)"
                    if self.downloadCancelled { self.magQueuedTakes = []; self.magBatchActive = false }
                    else { self.pumpMagDownloadQueue() }
                }
            }
        }
    }

    /// One-page DIT PDF for a single downloaded mag take, beside the .cine.
    private func makeMagClipPDF(for take: MagTake, at dest: URL) {
        let parsed = CameraModel.parseSidecar(dest.appendingPathExtension("xml"))
        var fields = parsed
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
        let entry = ClipEntry(url: dest, name: dest.lastPathComponent, sizeBytes: size,
                              thumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil,
                              fields: fields, md5: md5, date: Date())
        let pdf = dest.deletingPathExtension().appendingPathExtension("pdf")
        let project = projectName
        Thread.detachNewThread { [weak self] in
            DITReport.exportPDF([entry], project: project, to: pdf)
            Task { @MainActor in self?.magClipPDFs[take.id] = pdf }
        }
    }

    /// Downloads a cine on its own camera connection so live control keeps
    /// working. nil range = whole cine. deleteAfter = auto-save mode: clear
    /// the partition (re-arming the camera) once the file is safe.
    func downloadCine(_ n: Int, first: Int? = nil, last: Int? = nil, deleteAfter: Bool = false) {
        guard downloadProgress == nil else { return }
        // The Flex jams if it serves a download while writing to the CineMag —
        // hold off until any mag save/erase finishes.
        guard magBusy == nil, magSavingCine == nil else {
            downloadStatus = "CineMag is busy — try the download again in a moment."
            return
        }
        let host = self.host
        let rangeFirst = first, rangeLast = last
        let throttle = Int(downloadThrottle)
        let doVerify = verifyDownloads
        // Packing choice → which transport/format downloadCine uses. Auto lets it pick
        // the fastest complete path; a forced choice honors the user (10-bit packed needs
        // 10G, so it falls back to Auto if there's no 10G link; 12-bit forces the full-
        // depth TCP path). tenGig drives the MB/s readout's bytes/pixel (ximg = 10-bit
        // packed = 1.25 B/px, TCP = 16-bit = 2 B/px).
        // Was `autodetect(...) != nil`, which is true for a 1G interface and
        // cannot know whether /dev/bpf actually opens — so the fast path was
        // claimed available when it could never run, and the MB/s readout was
        // then scored with the wrong bytes/pixel. preflight() checks both.
        let preflight = XimgReceiver.preflight(cameraIP: host)
        let tenGigAvail = preflight.pathCanRun
        let useXimg: Bool?
        switch downloadPacking {
        case .auto:     useXimg = nil
        case .packed10: useXimg = tenGigAvail ? true : nil
        case .wide12:   useXimg = false
        }
        downloadCancelled = false
        downloadProgress = 0
        downloadStatus = "Connecting…"
        let dest = destinationURL(defaultBase: "C\(n)", ext: "cine")
        let name = dest.lastPathComponent

        // Optional SDI proxy: play the same range out the SDI and record it
        // while the full-quality download runs.
        if proxyOnDownload && sdi.isRunning, let pf = rangeFirst, let pl = rangeLast {
            let proxyURL = dest.deletingPathExtension().appendingPathExtension("mov")
            // Cue the first frame, start recording, then roll once it's actually
            // capturing — so the proxy doesn't miss the opening frames.
            sendSimple("vplay {cine:\(n), firstframe:\(pf), lastframe:\(pf)}", label: "proxy cue")
            let seconds = Double(pl - pf + 1) / 24.0 + 2.0
            sdi.startProxyRecording(to: proxyURL) { [weak self] in
                guard let self else { return }
                self.sendSimple("vplay {cine:\(n), firstframe:\(pf), lastframe:\(pl)}", label: "proxy vplay")
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.sdi.stopProxyRecording()
                }
            }
        }

        Thread.detachNewThread { [weak self] in
            let conn = CameraConnection(host: host)
            func ui(_ block: @escaping @MainActor () -> Void) { Task { @MainActor in block() } }
            do {
                try conn.connect()
                try conn.startDataChannel()
                let info = try conn.get("info")
                let c = try conn.get("c\(n)")
                guard let res = PhantomProtocol.find("res", in: c)?.sizeValue else {
                    throw PhantomError.protocolError("no res for c\(n)")
                }
                let first = rangeFirst ?? (PhantomProtocol.find("firstfr", in: c)?.intValue ?? 0)
                let last = rangeLast ?? (PhantomProtocol.find("lastfr", in: c)?.intValue ?? 0)
                // DEVELOP STATE — read the clip's real look off the camera so the .cine
                // header carries it (WB, tone curve, colour matrix, trigger time). The
                // per-cine c{n}.adj is the snapshot taken at record time; fall back to the
                // live video.adj if a body doesn't expose it. Without this, files carried
                // template placeholders and rendered washed-out/off-colour in PCC/Seance/
                // Fuse/Resolve (verified against Seance downloads of the same takes).
                let cadj = (try? conn.get("c\(n).adj")) ?? (try? conn.get("video.adj")) ?? [:]
                var wbR: Float = 0, wbB: Float = 0
                if let r = PhantomProtocol.find("wbred", in: cadj)?.doubleValue, r > 0.01,
                   let b = PhantomProtocol.find("wbblue", in: cadj)?.doubleValue, b > 0.01 {
                    wbR = Float(r); wbB = Float(b)                    // VEO-class: direct floats
                } else if let r = PhantomProtocol.find("red", in: cadj)?.doubleValue, r > 0,
                          let b = PhantomProtocol.find("blue", in: cadj)?.doubleValue, b > 0 {
                    let g = max(PhantomProtocol.find("green", in: cadj)?.doubleValue ?? 1, 0.01)
                    wbR = Float(r / g); wbB = Float(b / g)            // PH16: 1024-scaled, green = reference
                }
                let toneStr = PhantomProtocol.find("tone", in: cadj)?.stringValue
                var cal: [Float] = []
                if let cm = PhantomProtocol.find("cmatrix", in: cadj)?.stringValue {
                    let nums = cm.split(whereSeparator: { " \"\t".contains($0) }).compactMap { Float($0) }
                    if nums.count >= 9 { cal = Array(nums.suffix(9)) }   // drop the "cal" label token
                }
                let trig = PhantomProtocol.find("trigtime", in: c)?.dictValue ?? [:]
                let trigSecs = UInt32(truncatingIfNeeded: PhantomProtocol.find("secs", in: trig)?.intValue ?? 0)
                let trigFrac = UInt32(truncatingIfNeeded: PhantomProtocol.find("frac", in: trig)?.intValue ?? 0)

                let meta = CineMetadata(
                    width: res.width, height: res.height,
                    frameRate: PhantomProtocol.find("rate", in: c)?.intValue ?? 24,
                    exposureNs: PhantomProtocol.find("exp", in: c)?.intValue ?? 0,
                    serial: PhantomProtocol.find("serial", in: info)?.intValue ?? 0,
                    cfa: PhantomProtocol.find("cfa", in: info)?.intValue ?? 3,
                    firstImageNo: first,
                    totalFrames: PhantomProtocol.find("frcount", in: c)?.intValue ?? (last - first + 1),
                    firstMovieImage: PhantomProtocol.find("firstfr", in: c)?.intValue ?? first,
                    triggerSecs: trigSecs, triggerFrac: trigFrac,
                    cameraModel: PhantomProtocol.find("model", in: info)?.stringValue ?? "Phantom",
                    // hwver → SETUP CameraVersion, so the file identifies the body
                    // that actually shot it (Flex = 135) instead of inheriting the
                    // VEO4K template donor's identity.
                    cameraVersion: PhantomProtocol.find("hwver", in: info)?.intValue ?? 0,
                    cineName: dest.deletingPathExtension().lastPathComponent,
                    wbRed: wbR, wbBlue: wbB,
                    toneString: toneStr ?? "", toneKnown: toneStr != nil, calMatrix: cal)
                let t0 = Date()
                // Read the transport the connection ACTUALLY chose, live, inside
                // the progress callback — not a guess made before the transfer.
                // A TCP transfer scored with the ximg constant reads ~37% low,
                // which is how a real ~7 MB/s came out as "5 MB/s".
                try conn.downloadCine(cine: n, to: dest, meta: meta,
                                      firstFrame: first, lastFrame: last,
                                      useXimg: useXimg,
                                      throttlePercent: throttle,
                                      cancelled: { [weak self] in
                                          // read on background thread; Bool is fine
                                          self?.downloadCancelled ?? true
                                      }) { done, total in
                    let bytesPerPixel = conn.lastDownloadUsedXimg ? 1.25 : 2.0   // 10-bit packed vs P16
                    let mbps = Double(done * res.width * res.height) * bytesPerPixel / max(Date().timeIntervalSince(t0), 0.01) / 1e6
                    let remain = Double(total - done) * Date().timeIntervalSince(t0) / Double(max(done, 1))
                    ui { [weak self] in
                        self?.downloadProgress = Double(done) / Double(total)
                        self?.downloadStatus = String(format: "%d/%d frames  %.0f MB/s  ~%.0fs left",
                                                      done, total, mbps, remain)
                    }
                }
                // Verify the written file BEFORE we trust it or erase the source.
                var verifiedOK = true
                var verifyTail = ""
                var hash: String? = nil
                var failMessage = ""
                if doVerify {
                    ui { [weak self] in self?.downloadProgress = 0; self?.downloadStatus = "Verifying…" }
                    let result = CineVerify.verify(url: dest, expectedFrames: last - first + 1) { p in
                        ui { [weak self] in self?.downloadProgress = p }
                    }
                    verifiedOK = result.ok
                    hash = result.md5
                    if !result.ok { failMessage = result.message }
                    if let md5 = result.md5 { CineVerify.writeChecksum(md5, for: dest) }
                    verifyTail = result.ok ? "  ✓ verified (md5 \(result.md5?.prefix(8) ?? ""))"
                                           : "  ⚠️ VERIFY FAILED: \(result.message)"
                }
                // Only erase the camera partition if the copy is good.
                if deleteAfter && verifiedOK {
                    _ = try? conn.command("del {cine: \(n)}")
                }
                conn.close()
                if verifiedOK { ClipThumbnail.generate(for: dest) }   // poster frame for the clip browser / report
                let ok = verifiedOK, tail = verifyTail, md5Final = hash, fail = failMessage  // immutable for the closure
                ui { [weak self, meta] in
                    guard let self else { return }
                    self.downloadProgress = nil
                    self.downloadStatus = (ok ? "Saved \(name)" : "⚠️ \(name) — VERIFY FAILED, re-download") + tail
                    // Mark the clip safe only if it verified AND we saved its WHOLE
                    // recorded range — a trimmed/failed download stays unprotected, so
                    // those keep warning on overwrite.
                    if !deleteAfter && ok {
                        let slot = self.cines.first(where: { $0.id == n })
                        let coversAll = (rangeFirst == nil && rangeLast == nil)
                            || (slot.map { (rangeFirst ?? .min) <= $0.firstFrame && (rangeLast ?? .max) >= $0.lastFrame } ?? true)
                        if coversAll { self.savedCines.insert(n) }
                    }
                    if ok {
                        self.writeClipSidecars(url: dest, cine: meta, md5: md5Final, first: first, last: last)
                    }
                    self.appendLog("downloaded c\(n) -> \(name)\(deleteAfter && ok ? " (partition cleared)" : "")\(tail)")
                    if doVerify {
                        // Success = quiet status icon; failure = must-acknowledge alert.
                        let status = CameraModel.VerifyStatus(ok: ok, clip: name, message: fail)
                        self.lastVerify = status
                        if !ok { NSSound.beep(); self.verifyFailedAlert = status }
                    } else {
                        self.showDownloadToast(ok: true, title: "Download complete", detail: name)
                    }
                    self.pumpAutoSave()
                }
            } catch {
                conn.close()
                ui { [weak self] in
                    self?.downloadProgress = nil
                    self?.downloadStatus = "Download failed: \(error)"
                    self?.appendLog("download error: \(error)")
                }
            }
        }
    }

    func cancelDownload() { downloadCancelled = true }

    /// Free space (bytes) on the save-folder's volume, or nil if unknown.
    func volumeFreeBytes() -> Int64? {
        let v = try? URL(fileURLWithPath: saveFolderPath)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
    /// Rough bytes a download of `frames` at the current resolution will write
    /// (the .cine stores 16bpp, so 2 bytes/pixel + a little overhead).
    func estimatedDownloadBytes(frames: Int) -> Int64 {
        Int64(max(frames, 0)) * Int64(max(resWidth, 1)) * Int64(max(resHeight, 1)) * 2
    }
    var freeSpaceString: String {
        guard let b = volumeFreeBytes() else { return "" }
        return String(format: "%.0f GB free", Double(b) / 1e9)
    }
    /// True if the volume is too full for `frames` (keeps a 2 GB head-room).
    func downloadWontFit(frames: Int) -> Bool {
        guard let free = volumeFreeBytes() else { return false }
        return estimatedDownloadBytes(frames: frames) + 2_000_000_000 > free
    }

    /// `<saveFolder>/<project>` — where this project's clips and sidecars live.
    func currentProjectFolder() -> URL {
        var dir = URL(fileURLWithPath: saveFolderPath)
        let proj = Self.sanitize(projectName)
        if !proj.isEmpty { dir.appendPathComponent(proj) }
        return dir
    }

    /// Every downloaded .cine in the project folder, with its sidecar metadata,
    /// thumbnail and checksum gathered for the browser / report.
    func projectClips() -> [ClipEntry] {
        let dir = currentProjectFolder()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "cine" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
                let size = rv?.fileSize ?? 0
                let date = rv?.creationDate ?? rv?.contentModificationDate ?? .distantPast
                let thumb = ClipThumbnail.url(for: url)
                let hasThumb = FileManager.default.fileExists(atPath: thumb.path)
                let md5 = (try? String(contentsOf: url.appendingPathExtension("md5"), encoding: .utf8))?
                    .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
                return ClipEntry(url: url, name: url.lastPathComponent, sizeBytes: size,
                                 thumb: hasThumb ? thumb : nil,
                                 fields: Self.parseSidecar(url.appendingPathExtension("xml")),
                                 md5: md5, date: date)
            }
    }

    /// Parses a `<clip>.cine.xml` sidecar into ordered (key, value) pairs.
    static func parseSidecar(_ url: URL) -> [(String, String)] {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let re = try? NSRegularExpression(pattern: "<([A-Za-z0-9]+)>(.*?)</\\1>", options: [.dotMatchesLineSeparators])
        var out: [(String, String)] = []
        re?.enumerateMatches(in: xml, range: NSRange(xml.startIndex..., in: xml)) { m, _, _ in
            guard let m, let kr = Range(m.range(at: 1), in: xml), let vr = Range(m.range(at: 2), in: xml) else { return }
            let k = String(xml[kr])
            guard k != "clip" else { return }
            let v = String(xml[vr])
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            out.append((k, v))
        }
        return out
    }

    /// Writes the DIT report (CSV + thumbnailed PDF) into the project folder on a
    /// background thread (the contact strips render frames, so it takes a moment),
    /// then calls back on the main actor with the PDF URL.
    func exportReport(_ clips: [ClipEntry], completion: @escaping (URL) -> Void) {
        let dir = currentProjectFolder()
        let base = Self.sanitize(projectName.isEmpty ? "Phantom" : projectName)
        let projName = projectName
        Thread.detachNewThread {
            DITReport.exportCSV(clips, to: dir.appendingPathComponent("\(base)_Report.csv"))
            let pdf = dir.appendingPathComponent("\(base)_Report.pdf")
            DITReport.exportPDF(clips, project: projName, to: pdf)
            Task { @MainActor in
                self.appendLog("DIT report → \(base)_Report.pdf / .csv")
                completion(pdf)
            }
        }
    }

    /// Renders thumbnails for any clips missing one (e.g. downloaded before this
    /// feature, or re-scanned), off the main thread.
    func generateMissingThumbnails(_ clips: [ClipEntry], done: @escaping () -> Void) {
        let missing = clips.filter { $0.thumb == nil }.map(\.url)
        guard !missing.isEmpty else { done(); return }
        Thread.detachNewThread {
            for u in missing { ClipThumbnail.generate(for: u) }
            Task { @MainActor in done() }
        }
    }

    /// Writes the `.cine.xml` metadata sidecar (production fields + camera‑derived
    /// values) and appends to the project `.mhl` checksum list.
    func writeClipSidecars(url: URL, cine: CineMetadata, md5: String?, first: Int, last: Int) {
        guard writeSidecars else { return }
        let iso = ISO8601DateFormatter()
        var fields: [(String, String)] = [("File", url.lastPathComponent)]
        fields += meta.pairs
        var camera: [(String, String)] = []
        // Read authoritative values back from the written .cine header (real fps,
        // exposure → computed shutter angle, WB, trigger time) — falling back to
        // what we asked the writer for if it somehow can't be re-opened.
        if let r = try? CineReader(url: url) {
            let i = r.info
            camera.append(("Camera", i.cameraModel.isEmpty ? cine.cameraModel : i.cameraModel))
            camera.append(("Serial", String(i.serial)))
            camera.append(("Resolution", "\(i.width)×\(i.height)"))
            camera.append(("FrameRate", String(format: "%g fps", i.frameRate)))
            camera.append(("PlaybackFPS", String(format: "%g fps", i.playbackFPS)))
            if i.exposureNs > 0 {
                camera.append(("Exposure", String(format: "%.1f µs", Double(i.exposureNs) / 1000)))
                let angle = Double(i.exposureNs) * i.frameRate * 360 / 1e9   // verified 180° on real files
                if angle > 0 && angle <= 360.5 { camera.append(("ShutterAngle", String(format: "%.1f°", angle))) }
            }
            camera.append(("WhiteBalance", String(format: "R %.3f B %.3f", i.wbGainRed, i.wbGainBlue)))
            camera.append(("Frames", "\(i.frameCount)"))
            camera.append(("Duration", String(format: "%.2fs", i.durationSeconds)))
            if i.triggerSecs > 0 {
                camera.append(("RecordedTime", iso.string(from: Date(timeIntervalSince1970: Double(i.triggerSecs)))))
            }
        } else {
            camera.append(("Camera", cine.cameraModel))
            camera.append(("Serial", String(cine.serial)))
            camera.append(("Resolution", "\(cine.width)×\(cine.height)"))
            camera.append(("FrameRate", "\(cine.frameRate) fps"))
            if cine.exposureNs > 0 {
                camera.append(("Exposure", String(format: "%.1f µs", Double(cine.exposureNs) / 1000)))
                let angle = Double(cine.exposureNs) * Double(cine.frameRate) * 360 / 1e9
                if angle > 0 { camera.append(("ShutterAngle", String(format: "%.1f°", angle))) }
            }
            camera.append(("Frames", "\(last - first + 1)"))
        }
        camera.append(("InOut", "\(first)–\(last)"))
        camera.append(("Downloaded", iso.string(from: Date())))
        fields += camera
        if let md5 { fields.append(("MD5", md5)) }
        ClipSidecar.writeMetadataXML(fields, for: url)

        if let md5,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()
            let mhl = url.deletingLastPathComponent()
                .appendingPathComponent("\(Self.sanitize(projectName.isEmpty ? "Phantom" : projectName)).mhl")
            ClipSidecar.appendMHL(file: mhl, clipName: url.lastPathComponent,
                                  size: size, md5: md5, modDate: modDate)
        }
    }

    // MARK: - CineMag

    func refreshMag() {
        runCommandAsync { conn in
            try CameraModel.readMag(on: conn)
        } onResult: { [weak self] result in
            guard let self, let r = result else { return }
            let idsBefore = Set(self.magTakes.map(\.id))
            self.magTakes = r.takes
            self.magInfo = r.info
            self.magUsed = r.used
            self.magSize = r.size
            if !r.debugFields.isEmpty { self.appendLog("mag take fields: \(r.debugFields)") }
            // A different set of takes = a new/erased mag: drop stale thumbnails.
            if idsBefore != Set(r.takes.map(\.id)) {
                self.magThumbs = [:]; self.magDownloadedTakes = []; self.magClipPDFs = [:]
            }
            self.fetchMagThumbnails()
        }
    }

    /// Reads a CineMag take list + summary from ANY connection — the live camera's
    /// or a CineStation's. Both serve the same `get mag` / `get fc<N>.*` tree, so
    /// this one reader drives both. Call on the connection's own serial queue
    /// (CameraConnection is not thread safe). Prefers a single `get fc<i>` per take
    /// (the whole struct) and falls back to per-field gets on firmware that won't
    /// answer the bare variable.
    static func readMag(on conn: CameraConnection) throws
        -> (takes: [MagTake], info: String, used: Double, size: Double, debugFields: String) {
        let mag = try conn.get("mag")
        let count = PhantomProtocol.find("takes", in: mag)?.intValue ?? 0
        let size = PhantomProtocol.find("size", in: mag)?.doubleValue ?? 0
        let used = PhantomProtocol.find("used", in: mag)?.doubleValue ?? 0
        // Mag health: errcode ≠ 0 is a genuine CineMag fault ("MAG ERR" — a bad
        // seat or a faulted mag, which is what a "cinemag failure" on a frame read
        // means). state 5 = writing a take, 8 = erasing. Surface it so a failed mag
        // reads plainly in the window instead of only failing a preview/download.
        let state = PhantomProtocol.find("state", in: mag)?.intValue ?? -1
        let errcode = PhantomProtocol.find("errcode", in: mag)?.intValue ?? 0
        let health: String
        if errcode != 0      { health = "⚠️ CineMag ERROR (code \(errcode)) — reseat the mag" }
        else if state == 5   { health = "CineMag writing…" }
        else if state == 8   { health = "CineMag erasing…" }
        else                 { health = "" }
        let infoLine: String
        if count > 0 {
            let base = String(format: "%d takes — %.0f / %.0f GB used", count, used/1e6, size/1e6)
            infoLine = health.isEmpty ? base : "\(health)  ·  \(base)"
        } else {
            infoLine = errcode != 0 ? "⚠️ CineMag ERROR (code \(errcode)) — reseat the mag"
                                    : "No CineMag or empty"
        }
        var takes: [MagTake] = []
        var debugFields = ""
        for i in 0..<min(count, 64) {
            var t = MagTake(id: i)
            let whole = (try? conn.get("fc\(i)")) ?? [:]
            func f(_ keys: String...) -> PhValue? {
                for k in keys { if let v = PhantomProtocol.find(k, in: whole) { return v } }
                return nil
            }
            if let r = f("res")?.sizeValue {                    // whole-struct read worked
                t.width = r.width; t.height = r.height
                if let rd = f("rate")?.doubleValue { t.rateDouble = rd; t.rate = Int(rd.rounded()) }
                t.frames      = f("frcount")?.intValue ?? 0
                t.firstFrame  = f("firstfr")?.intValue ?? 0
                t.lastFrame   = f("lastfr")?.intValue ?? 0
                // The CLIP name specifically (meta.name) — NOT a bare "name"
                // search, which ambiguously also matches info.name (the shooting
                // camera's name, e.g. "10706"), so some takes showed it and some
                // didn't. Clip name is usually blank unless the operator set one.
                t.name        = f("meta")?.dictValue?["name"]?.stringValue ?? ""
                t.exposureNs  = f("exp", "exposure")?.intValue ?? 0
                t.playbackFPS = f("pbrate", "playrate", "pbfps", "playbackrate")?.doubleValue ?? 0
                // Shot time is trigtime.secs (epoch seconds); frac is IRIG flags.
                if let secs = f("trigtime")?.dictValue?["secs"]?.doubleValue, secs > 1_000_000_000 {
                    t.triggerSecs = UInt32(min(secs, Double(UInt32.max)))
                }
                if i == 0 {
                    let inner: [String: PhValue] = (whole.count == 1 ? whole.values.first?.dictValue : nil) ?? whole
                    debugFields = inner.keys.sorted().joined(separator: ", ")
                }
            } else {
                if let r = PhantomProtocol.find("res", in: (try? conn.get("fc\(i).res")) ?? [:])?.sizeValue {
                    t.width = r.width; t.height = r.height
                }
                t.rate = PhantomProtocol.find("rate", in: (try? conn.get("fc\(i).rate")) ?? [:])?.intValue ?? 0
                t.rateDouble = Double(t.rate)
                t.frames = PhantomProtocol.find("frcount", in: (try? conn.get("fc\(i).frcount")) ?? [:])?.intValue ?? 0
                t.firstFrame = PhantomProtocol.find("firstfr", in: (try? conn.get("fc\(i).firstfr")) ?? [:])?.intValue ?? 0
                t.lastFrame = PhantomProtocol.find("lastfr", in: (try? conn.get("fc\(i).lastfr")) ?? [:])?.intValue ?? 0
                t.name = PhantomProtocol.find("name", in: (try? conn.get("fc\(i).meta.name")) ?? [:])?.stringValue ?? ""
                t.exposureNs = PhantomProtocol.find("exp", in: (try? conn.get("fc\(i).exp")) ?? [:])?.intValue ?? 0
                if let secs = PhantomProtocol.find("secs", in: (try? conn.get("fc\(i).trigtime")) ?? [:])?.doubleValue,
                   secs > 1_000_000_000 {
                    t.triggerSecs = UInt32(min(secs, Double(UInt32.max)))
                }
            }
            takes.append(t)
        }
        return (takes, infoLine, used, size, debugFields)
    }

    // MARK: - CineMag media management

    /// In-flight mag operation label (drives the busy UI); nil = idle.
    @Published var magBusy: String?
    /// Result of the last mag operation, surfaced in the manager sheet.
    @Published var magOpResult: String?

    /// Deletes ONE take off the CineMag — where the firmware allows it.
    /// Wire command (SDK: PhDeleteCine): `del {cine:N}`,
    /// mag cine number = ramPartitions + 1 + index.
    ///
    /// TESTED LIVE on the Flex (swver 797, CineMag): the camera answers "Ok!"
    /// but deletes NOTHING — its CineMag is append-only flash and only supports
    /// the full `ferase`. So never trust the ack: compare the take count
    /// before/after and tell the user the truth.
    func deleteMagTake(_ take: MagTake) {
        // Same direct flash addressing as mag playback: cine:<take.id> with
        // `from:mag` (verified for vplay live on the Flex). The RAM-partition
        // state check guards against firmware that IGNORES the from:mag arg —
        // if the same-numbered RAM cine changed state, we stop trusting del.
        let cineNo = take.id
        magBusy = "Deleting take \(take.label)…"
        runCommandAsync { conn -> (Bool, Bool) in
            let takes = { PhantomProtocol.find("takes", in: (try? conn.get("mag.takes")) ?? [:])?.intValue ?? -1 }
            let ramState = { (try? conn.command("get c\(cineNo).state"))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?" }
            let before = takes()
            let ramBefore = ramState()
            let reply = try conn.command("del {cine:\(cineNo), from:mag}", timeout: 30)
            Thread.sleep(forTimeInterval: 1.0)   // give the mag a beat to update
            let removed = reply.contains("Ok") && takes() < before
            let ramTouched = ramState() != ramBefore
            return (removed, ramTouched)
        } onResult: { [weak self] result in
            guard let self else { return }
            self.magBusy = nil
            let (removed, ramTouched) = result ?? (false, false)
            if ramTouched {
                self.appendLog("⚠️ mag delete \(take.label): RAM c\(cineNo) state CHANGED — del ignored from:mag on this firmware! Do not use per-take delete.")
                self.magOpResult = "⚠️ The camera applied the delete to RAM instead of the mag — per-take mag delete is NOT safe on this firmware. Use Erase for the whole mag."
                self.refreshCineStates()
            } else if removed {
                self.appendLog("mag delete \(take.label) (flash cine \(cineNo)): deleted")
                self.magOpResult = "Deleted take \(take.label)."
            } else {
                self.appendLog("mag delete \(take.label): firmware refused (append-only mag)")
                self.magOpResult = "This camera's CineMag can't delete individual takes — its flash is append-only. Download what you want to keep, then use Erase to reclaim the whole mag (same as PCC)."
            }
            self.refreshMag()
        }
    }

    /// Erases the ENTIRE CineMag (PCC's PhNVMErase → wire `ferase`). Flash
    /// erase runs camera-side for a while — poll the mag until it comes back.
    func eraseMag() {
        magBusy = "Erasing CineMag…"
        runCommandAsync { conn in
            try conn.command("ferase", timeout: 30)
        } onResult: { [weak self] result in
            guard let self else { return }
            let r = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no reply"
            self.appendLog("ferase: \(r)")
            if !r.hasPrefix("Ok") {
                self.magBusy = nil
                self.magOpResult = "Camera refused the erase: \(r)"
                return
            }
            self.pollMagErase(deadline: Date().addingTimeInterval(300))
        }
    }

    /// Polls until the erase REALLY completes (or 5 min deadline). The takes/used
    /// counters zero out immediately, but the physical flash wipe keeps running:
    /// mag.state stays 8 (erasing) with mag.progress counting DOWN the blocks
    /// left, then the state returns to 4 (ready). Verified live on the Flex —
    /// a 264 GB CineMag II wipes in ~1-2 min.
    private func pollMagErase(deadline: Date) {
        runCommandAsync { conn -> (Int, Int) in
            let state = PhantomProtocol.find("state", in: (try? conn.get("mag.state")) ?? [:])?.intValue ?? -1
            let left = PhantomProtocol.find("progress", in: (try? conn.get("mag.progress")) ?? [:])?.intValue ?? -1
            return (state, left)
        } onResult: { [weak self] r in
            guard let self else { return }
            let (state, left) = r ?? (-1, -1)
            if state >= 0, state != 8, left <= 0 {
                self.magBusy = nil
                self.magOpResult = "CineMag erased."
                self.refreshMag()
            } else if Date() > deadline {
                self.magBusy = nil
                self.magOpResult = "Erase still running on the camera — refresh in a minute."
                self.refreshMag()
            } else {
                if left > 0 { self.magBusy = "Erasing CineMag… \(left) blocks left" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.pollMagErase(deadline: deadline)
                }
            }
        }
    }

    /// Plays a CineMag take to the camera's SDI output. Mag takes are addressed
    /// directly by flash index (0-based) with `from:mag` — no partition offset
    /// (verified live on the Flex; the old ramPartitions+1+N scheme errored).
    func playMagTake(_ take: MagTake) {
        sendSimple("vplay {cine:\(take.id), firstframe:\(take.firstFrame), lastframe:\(take.lastFrame), from:mag}",
                   label: "mag take \(take.label) → SDI (cine \(take.id))")
    }

    // MARK: - Plumbing

    private func sendSimple(_ cmd: String, label: String?) {
        runCommandAsync { conn in
            try conn.command(cmd)
        } onResult: { [weak self] result in
            if let label {
                self?.appendLog("\(label): \(result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")")
            }
        }
    }

    /// Runs work on the serial camera queue, delivers the result on the main actor.
    /// Errors are logged and delivered as nil.
    private func runCommandAsync<T>(_ work: @escaping (CameraConnection) throws -> T,
                                    onResult: @escaping (T?) -> Void) {
        guard let conn else { onResult(nil); return }
        camQueue.async { [weak self] in
            do {
                let result = try work(conn)
                Task { @MainActor in
                    self?.consecutiveErrors = 0
                    onResult(result)
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.appendLog("error: \(error)")
                    self.consecutiveErrors += 1
                    // A run of failures means the camera is gone (power cycle,
                    // cable pull). Drop cleanly and keep trying to reconnect.
                    if self.connected && self.consecutiveErrors >= 5 {
                        self.connectionLost()
                    }
                    onResult(nil)
                }
            }
        }
    }

    private func connectionLost() {
        disconnect()
        statusLine = "Camera lost — waiting for it to come back…"
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connected else {
                    self?.reconnectTimer?.invalidate()
                    self?.reconnectTimer = nil
                    return
                }
                self.discoverAndConnect()
            }
        }
    }
}

/// Post-download integrity checking (ShotPut-style, as far as a streamed source
/// allows). Runs on the download's background thread — not main-actor isolated.
///
/// We can't re-read the camera's volatile source to compare hashes, so instead we
/// confirm the *written* file is whole and sound — re-open the .cine, check the
/// frame count, read the last frame (catches truncation) — then compute an MD5 and
/// drop a `.md5` sidecar plus an md5sum-compatible `Checksums.md5` manifest. That
/// hash then travels with the clip so every later copy can be re-verified (the
/// manifest opens straight in ShotPut Pro or `md5sum -c`).
enum CineVerify {
    struct Result { let ok: Bool; let message: String; let md5: String? }

    static func verify(url: URL, expectedFrames: Int, progress: (Double) -> Void) -> Result {
        // 1. Structural: header parses, frame count matches, last frame readable.
        do {
            let reader = try CineReader(url: url)
            let got = reader.info.frameCount
            if expectedFrames > 0 && got != expectedFrames {
                return Result(ok: false, message: "frame count \(got) ≠ expected \(expectedFrames)", md5: nil)
            }
            if got > 0 { _ = try reader.readRawFrame(got - 1) }   // not truncated
        } catch {
            return Result(ok: false, message: "unreadable .cine (\(error))", md5: nil)
        }
        // 2. Checksum the bytes that actually landed on disk.
        do {
            return Result(ok: true, message: "OK", md5: try md5Hex(url, progress: progress))
        } catch {
            return Result(ok: false, message: "checksum read failed (\(error))", md5: nil)
        }
    }

    static func md5Hex(_ url: URL, progress: (Double) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        var hasher = Insecure.MD5()
        var read = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            read += chunk.count
            if total > 0 { progress(Double(read) / Double(total)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `<clip>.cine.md5` and appends an md5sum-format line to the project's
    /// `Checksums.md5` manifest (`<hash><space><space><filename>`).
    static func writeChecksum(_ md5: String, for url: URL) {
        let line = "\(md5)  \(url.lastPathComponent)\n"
        try? Data(line.utf8).write(to: url.appendingPathExtension("md5"))
        let manifest = url.deletingLastPathComponent().appendingPathComponent("Checksums.md5")
        if let handle = try? FileHandle(forWritingTo: manifest) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: manifest)
        }
    }
}

/// Renders a poster-frame JPEG thumbnail for a downloaded .cine, for the clip
/// browser / DIT report. Runs off the main thread (uses PhantomCore directly).
enum ClipThumbnail {
    static func folder(for clip: URL) -> URL {
        clip.deletingLastPathComponent().appendingPathComponent("Thumbnails")
    }
    static func url(for clip: URL) -> URL {
        folder(for: clip).appendingPathComponent(clip.deletingPathExtension().lastPathComponent + ".jpg")
    }

    @discardableResult
    static func generate(for clip: URL, maxDim: Int = 480) -> URL? {
        guard let reader = try? CineReader(url: clip) else { return nil }
        let idx = max(0, reader.info.frameCount / 2)          // mid-clip poster frame
        guard let frame = try? reader.readFrame(idx) else { return nil }
        var s = Debayer16.RenderSettings(info: reader.info)
        if let wb = Debayer16.autoWhiteBalance(frame: frame, cfa: reader.info.cfa,
                                               blackLevel16: reader.info.blackLevel16) {
            s.wbRed = wb.red; s.wbBlue = wb.blue
        }
        guard let full = Debayer16.render(frame: frame, cfa: reader.info.cfa, settings: s),
              let thumb0 = downscale(full, maxDim: maxDim) else { return nil }
        // Vertical mode: bake the rotation so posters match the rotated feed/exports.
        let thumb = MagOffload.rotateCW(thumb0, degrees: ExportRotation.current)
        let dir = folder(for: clip)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = url(for: clip)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        try? (data as Data).write(to: out)
        return out
    }

    private static func downscale(_ img: CGImage, maxDim: Int) -> CGImage? {
        let scale = Double(maxDim) / Double(max(img.width, img.height))
        if scale >= 1 { return img }
        let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Builds the end-of-day DIT report — a CSV spreadsheet and a thumbnailed PDF.
enum DITReport {
    static func exportCSV(_ clips: [ClipEntry], to url: URL) {
        var keys: [String] = []
        for c in clips { for (k, _) in c.fields where !keys.contains(k) { keys.append(k) } }
        keys.removeAll { $0 == "File" || $0 == "MD5" }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["File,SizeGB,MD5," + keys.map(q).joined(separator: ",")]
        for c in clips {
            let d = c.lookup
            var row = [q(c.name), String(format: "%.2f", c.sizeGB), q(c.md5 ?? "")]
            row += keys.map { q(d[$0] ?? "") }
            rows.append(row.joined(separator: ","))
        }
        try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ clips: [ClipEntry], project: String, to url: URL) {
        let pageW: CGFloat = 612, pageH: CGFloat = 792, M: CGFloat = 40
        var media = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { return }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = saved }

        let gold = NSColor(red: 0.82, green: 0.65, blue: 0.27, alpha: 1)
        let ink = NSColor(white: 0.10, alpha: 1)
        let green = NSColor(red: 0.13, green: 0.55, blue: 0.30, alpha: 1)
        let proj = project.isEmpty ? "Phantom" : project
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let gen = df.string(from: Date())

        func text(_ s: String, _ f: NSFont, _ c: NSColor, _ x: CGFloat, _ yy: CGFloat) {
            (s as NSString).draw(at: CGPoint(x: x, y: yy), withAttributes: [.font: f, .foregroundColor: c])
        }
        func textR(_ s: String, _ f: NSFont, _ c: NSColor, _ rx: CGFloat, _ yy: CGFloat) {
            let w = (s as NSString).size(withAttributes: [.font: f]).width
            (s as NSString).draw(at: CGPoint(x: rx - w, y: yy), withAttributes: [.font: f, .foregroundColor: c])
        }
        func fill(_ r: CGRect, _ c: NSColor) { ctx.setFillColor(c.cgColor); ctx.fill(r) }
        func hline(_ x1: CGFloat, _ x2: CGFloat, _ yy: CGFloat, _ c: NSColor, _ w: CGFloat) {
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
            ctx.move(to: CGPoint(x: x1, y: yy)); ctx.addLine(to: CGPoint(x: x2, y: yy)); ctx.strokePath()
        }
        func drawFit(_ img: CGImage, _ cell: CGRect) {  // full frame, aspect-fit (no crop)
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let s = min(cell.width / iw, cell.height / ih)
            let dw = iw * s, dh = ih * s
            fill(cell, NSColor(white: 0.10, alpha: 1))   // backing (only shows if the cap letterboxes)
            ctx.draw(img, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
            ctx.setStrokeColor(NSColor(white: 0.78, alpha: 1).cgColor); ctx.setLineWidth(0.5); ctx.stroke(cell)
        }
        func field(_ label: String, _ value: String, _ x: CGFloat, _ yy: CGFloat) {
            text(label.uppercased(), .systemFont(ofSize: 7), .gray, x, yy + 10)
            text(value, .systemFont(ofSize: 10, weight: .medium), ink, x, yy)
        }
        func num(_ s: String?) -> Double { Double((s ?? "").filter { "0123456789.".contains($0) }) ?? 0 }

        var pageNo = 0
        func footer() {
            hline(M, pageW - M, 34, NSColor(white: 0.85, alpha: 1), 0.5)
            text("Phantom Control — DIT Report — \(gen)", .systemFont(ofSize: 7.5), .gray, M, 22)
            textR("Page \(pageNo)", .systemFont(ofSize: 7.5), .gray, pageW - M, 22)
        }
        var y: CGFloat = 0
        func startPage(_ big: Bool) {
            ctx.beginPDFPage(nil); pageNo += 1
            if big {
                fill(CGRect(x: 0, y: pageH - 74, width: pageW, height: 74), ink)
                fill(CGRect(x: 0, y: pageH - 78, width: pageW, height: 4), gold)
                text("DIT REPORT", .systemFont(ofSize: 9, weight: .bold), gold, M, pageH - 30)
                text(proj, .boldSystemFont(ofSize: 24), .white, M, pageH - 58)
                textR(gen, .systemFont(ofSize: 10), NSColor(white: 0.8, alpha: 1), pageW - M, pageH - 30)
                let totalGB = clips.reduce(0) { $0 + $1.sizeGB }
                let totalDur = clips.reduce(0) { $0 + num($1.lookup["Duration"]) }
                textR(String(format: "%d clips · %.1f GB · %d:%02d", clips.count, totalGB,
                             Int(totalDur) / 60, Int(totalDur) % 60),
                      .systemFont(ofSize: 11, weight: .medium), .white, pageW - M, pageH - 56)
                // Offload / verification summary (ShotPut-style).
                let verN = clips.filter { $0.md5 != nil }.count
                let allOK = verN == clips.count && !clips.isEmpty
                let iso = ISO8601DateFormatter()
                let dts = clips.compactMap { ($0.lookup["Downloaded"]).flatMap { iso.date(from: $0) } }
                let sdf = DateFormatter(); sdf.dateFormat = "MMM d · HH:mm"
                let window = dts.isEmpty ? "—" : "\(sdf.string(from: dts.min()!)) – \(sdf.string(from: dts.max()!))"
                let dest = clips.first.map { $0.url.deletingLastPathComponent().path } ?? ""
                var vy = pageH - 98
                text("STATUS", .systemFont(ofSize: 7), .gray, M, vy + 10)
                text(allOK ? "✓ Verified (\(verN)/\(clips.count))" : "⚠ \(verN)/\(clips.count) verified",
                     .systemFont(ofSize: 11, weight: .bold), allOK ? green : .systemOrange, M, vy)
                field("Checksum", "MD5", M + 150, vy)
                field("Offload window", window, M + 250, vy)
                vy -= 28
                let destShown = dest.count > 78 ? "…" + dest.suffix(76) : dest
                field("Destination", destShown.isEmpty ? "—" : destShown, M, vy)
                hline(M, pageW - M, vy - 9, NSColor(white: 0.9, alpha: 1), 0.5)
                // Shoot info block from the first clip's sidecar.
                let d0 = clips.first?.lookup ?? [:]
                var info: [(String, String)] = []
                func add(_ l: String, _ k: String) { if let v = d0[k], !v.isEmpty { info.append((l, v)) } }
                add("Client", "Client"); add("Production", "Production"); add("Job", "Job")
                add("Director", "Director"); add("DP", "DP"); add("Operator", "CameraOperator")
                if let cam = d0["Camera"] { info.append(("Camera", cam + (d0["Serial"].map { " #\($0)" } ?? ""))) }
                let iy = vy - 32
                for (i, pair) in info.enumerated() {
                    let col = i % 2, row = i / 2
                    field(pair.0, pair.1, M + CGFloat(col) * 268, iy - CGFloat(row) * 28)
                }
                let rows = (info.count + 1) / 2
                y = iy - CGFloat(max(rows - 1, 0)) * 28 - 18
                hline(M, pageW - M, y, gold.withAlphaComponent(0.6), 1); y -= 16
            } else {
                text(proj + " — DIT Report (cont.)", .systemFont(ofSize: 9, weight: .bold), .gray, M, pageH - 34)
                hline(M, pageW - M, pageH - 42, NSColor(white: 0.85, alpha: 1), 0.5)
                y = pageH - 60
            }
        }

        let rowH: CGFloat = 104
        startPage(true)
        for (idx, c) in clips.enumerated() {
            if y - rowH < 50 { footer(); ctx.endPDFPage(); startPage(false) }
            let top = y
            if idx % 2 == 1 { fill(CGRect(x: M - 6, y: top - rowH + 8, width: pageW - 2 * M + 12, height: rowH - 4),
                                   NSColor(white: 0.965, alpha: 1)) }
            let d = c.lookup
            func trunc(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
            let ax = M, rx = pageW - M, stripX: CGFloat = 358

            // Contact strip on the right — each frame drawn at the CAPTURED aspect
            // ratio, full-frame (no cropping), so the report shows exactly what was
            // shot. Cell width is fixed by the layout; cell height follows the
            // clip's own aspect. 3 frames (head / middle / tail) so each is legible.
            let cells = 3, gap: CGFloat = 3
            let stripW = rx - stripX
            let cw = (stripW - gap * CGFloat(cells - 1)) / CGFloat(cells)
            let strip = DITReport.stripFrames(c.url, count: cells)
            var posterImg: CGImage?
            if let t = c.thumb, let src = CGImageSourceCreateWithURL(t as CFURL, nil) {
                posterImg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            let aspect: CGFloat = {
                if let f = strip.first { return CGFloat(f.width) / CGFloat(max(1, f.height)) }
                if let p = posterImg { return CGFloat(p.width) / CGFloat(max(1, p.height)) }
                return 16.0 / 9.0
            }()
            let ch = min(84, cw / aspect)            // full-frame height for this aspect
            let cyTop = top - 6 - ch
            for i in 0..<cells {
                let cell = CGRect(x: stripX + CGFloat(i) * (cw + gap), y: cyTop, width: cw, height: ch)
                if i < strip.count { drawFit(strip[i], cell) }
                else if let p = posterImg { drawFit(p, cell) }
                else { fill(cell, NSColor(white: 0.2, alpha: 1)) }
            }

            // Left text block.
            text(c.name, .boldSystemFont(ofSize: 13), ink, ax, top - 12)
            textR(String(format: "%.2f GB", c.sizeGB), .boldSystemFont(ofSize: 11), ink, stripX - 12, top - 12)
            if let md5 = c.md5 {
                text("MD5 " + md5.prefix(16), .systemFont(ofSize: 8), .gray, ax, top - 26)
                text("✓ VERIFIED", .systemFont(ofSize: 8, weight: .bold), green, ax + 156, top - 26)
            } else {
                text("not verified", .systemFont(ofSize: 8, weight: .bold), .systemOrange, ax, top - 26)
            }
            let fmtLine = [d["Resolution"], d["FrameRate"], d["ShutterAngle"]].compactMap { $0 }.joined(separator: "  ·  ")
            text(fmtLine, .systemFont(ofSize: 9), .darkGray, ax, top - 40)
            let camLine = [d["Camera"].map { $0 + (d["Serial"].map { " #\($0)" } ?? "") },
                           d["WhiteBalance"].map { "WB \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
            if !camLine.isEmpty { text(trunc(camLine, 60), .systemFont(ofSize: 8.5), .gray, ax, top - 53) }
            let durLine = [d["Duration"], d["Frames"].map { "\($0) fr" }, d["InOut"].map { "in/out \($0)" },
                           (d["RecordedTime"] ?? d["Downloaded"]).map { "REC \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !durLine.isEmpty { text(trunc(durLine, 62), .systemFont(ofSize: 8.5), .gray, ax, top - 66) }
            let lensLine = [d["Lens"], d["FocalLength"], d["Aperture"], d["NDFilter"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            if !lensLine.isEmpty { text(trunc(lensLine, 48), .systemFont(ofSize: 9, weight: .medium), ink, ax, top - 79) }
            let stLine = [d["Scene"].map { "Sc \($0)" }, d["Take"].map { "Tk \($0)" }, d["Notes"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            if !stLine.isEmpty { text(trunc(stLine, 58), .systemFont(ofSize: 8.5), .gray, ax, top - 92) }

            y = top - rowH
            hline(M, pageW - M, y + 6, NSColor(white: 0.86, alpha: 1), 0.5)
        }
        footer(); ctx.endPDFPage(); ctx.closePDF()
    }

    /// Renders `count` evenly-spaced frames across a .cine for the contact strip.
    static func stripFrames(_ url: URL, count: Int) -> [CGImage] {
        guard let r = try? CineReader(url: url), r.info.frameCount > 0 else { return [] }
        let n = r.info.frameCount
        var s = Debayer16.RenderSettings(info: r.info)
        var out: [CGImage] = []
        for i in 0..<count {
            let idx = count <= 1 ? n / 2 : i * (n - 1) / (count - 1)
            guard let f = try? r.readFrame(min(max(idx, 0), n - 1)) else { continue }
            if i == 0, let wb = Debayer16.autoWhiteBalance(frame: f, cfa: r.info.cfa, blackLevel16: r.info.blackLevel16) {
                s.wbRed = wb.red; s.wbBlue = wb.blue
            }
            if let img = Debayer16.render(frame: f, cfa: r.info.cfa, settings: s) {
                out.append(downscale(img, 300) ?? img)
            }
        }
        return out
    }

    private static func downscale(_ img: CGImage, _ maxDim: Int) -> CGImage? {
        let sc = Double(maxDim) / Double(max(img.width, img.height))
        if sc >= 1 { return img }
        let w = max(1, Int(Double(img.width) * sc)), h = max(1, Int(Double(img.height) * sc))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Writes the per-clip metadata XML sidecar and the project MHL (Media Hash List)
/// — the standard hand-off that opens in ShotPut Pro, Silverstack, etc.
enum ClipSidecar {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// `<clip>.cine.xml` — every field as a tag.
    static func writeMetadataXML(_ fields: [(String, String)], for url: URL) {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<clip>\n"
        for (k, v) in fields { xml += "  <\(k)>\(esc(v))</\(k)>\n" }
        xml += "</clip>\n"
        try? Data(xml.utf8).write(to: url.appendingPathExtension("xml"))
    }

    /// Appends a `<hash>` entry to (or creates) the project's MHL 1.1 file.
    static func appendMHL(file mhlURL: URL, clipName: String, size: Int, md5: String, modDate: Date) {
        let now = iso(Date())
        let entry =
            "  <hash>\n" +
            "    <file>\(esc(clipName))</file>\n" +
            "    <size>\(size)</size>\n" +
            "    <lastmodificationdate>\(iso(modDate))</lastmodificationdate>\n" +
            "    <md5>\(md5)</md5>\n" +
            "    <hashdate>\(now)</hashdate>\n" +
            "  </hash>\n"
        if let existing = try? String(contentsOf: mhlURL, encoding: .utf8),
           let range = existing.range(of: "</hashlist>") {
            let merged = existing.replacingCharacters(in: range, with: entry + "</hashlist>\n")
            try? merged.write(to: mhlURL, atomically: true, encoding: .utf8)
        } else {
            let head =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<hashlist version=\"1.1\">\n" +
                "  <creatorinfo>\n" +
                "    <name>\(esc(NSFullUserName()))</name>\n" +
                "    <hostname>\(esc(ProcessInfo.processInfo.hostName))</hostname>\n" +
                "    <tool>Phantom Control</tool>\n" +
                "    <startdate>\(now)</startdate>\n" +
                "    <finishdate>\(now)</finishdate>\n" +
                "  </creatorinfo>\n"
            try? (head + entry + "</hashlist>\n").write(to: mhlURL, atomically: true, encoding: .utf8)
        }
    }
}
