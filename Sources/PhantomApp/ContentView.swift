import SwiftUI
import AVFoundation
import PhantomCore
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import ImageIO

/// Clean, control-less AVPlayer surface (for the Video Out monitor's proxy feed).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = layer
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v.layer as? AVPlayerLayer)?.player = player
    }
}

/// Heads-up reference overlay for offline clip playback — frame/position + the
/// clip's recorded metadata (res, fps, shutter, exposure, recorded time).
struct ClipHeadsUp: View {
    @EnvironmentObject var model: CameraModel
    var body: some View {
        if let c = model.offlineClip {
            let d = c.lookup
            let total = Int(d["Frames"] ?? "") ?? 0
            let frame = model.isPlayingProxy ? model.proxyFrame : (model.offlinePlayer?.frameIndex ?? 0)
            let line2 = [d["Resolution"], d["FrameRate"], d["ShutterAngle"]].compactMap { $0 }.joined(separator: "  ·  ")
            let line3 = [d["Exposure"].map { "exp \($0)" }, d["RecordedTime"]].compactMap { $0 }.joined(separator: "  ·  ")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.isPlayingProxy ? "PROXY" : "RAW")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(model.isPlayingProxy ? Color.cyan.opacity(0.85) : Color.orange.opacity(0.85))
                        .foregroundStyle(.black).clipShape(Capsule())
                    Text(c.name).font(.caption.bold()).lineLimit(1)
                }
                Text("frame \(frame)\(total > 0 ? " / \(total)" : "")")
                    .font(.caption.monospaced())
                if !line2.isEmpty { Text(line2).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                if !line3.isEmpty { Text(line3).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
        }
    }
}

/// App version, read from the bundle Info.plist (set by build_app.sh from the
/// VERSION file + auto-incrementing build number). Shown so a beta tester can
/// tell you exactly which build they're on: "0.3.0 (build 42)".
enum AppInfo {
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    static var versionString: String { "v\(shortVersion) (build \(build))" }
}

/// Renders a string as a crisp QR-code NSImage (for the phone-remote URL).
func makeQRImage(_ string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let ci = filter.outputImage else { return nil }
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

/// SmallHD-style tool bar — every tool is a consistent "pill": click to toggle,
/// and tools with options have a chevron that drops a settings popover.
struct MonitorBar: View {
    let model: CameraModel          // for the Guides popover (not observed — bar stays cheap)
    @ObservedObject var monitor: SDIProcessor
    @ObservedObject var flicker: FlickerDetector
    @Binding var showGrid: Bool
    @Binding var gridDivisions: Int
    @Binding var gridCrosshair: Bool
    @Binding var gridColorName: String
    @Binding var gridOpacity: Double
    @Binding var guidesVisible: Bool
    let openFrameGuides: () -> Void
    let openVideoOutput: () -> Void
    let openClips: () -> Void
    let chooseLUT: () -> Void
    let onPeakingChange: (Bool) -> Void
    let onFlickerChange: (Bool) -> Void
    /// Flicker tool parked until detection is tuned (Daniel, 2026-07-08).
    private let showFlickerTool = false
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // ── Exposure / focus ──────────────────────────────
                ToolPill("False Color", icon: "paintpalette", isOn: $monitor.tools.falseColor,
                         help: "False-colour exposure map", key: "F") {
                    pillPanel(width: 270) {
                        panelHeader("False Color", $monitor.tools.falseColor)
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scale").foregroundStyle(.secondary).font(.caption)
                            Picker("", selection: $monitor.tools.falseColorMode) {
                                ForEach(SDIProcessor.falseColorModes, id: \.id) { Text($0.name).tag($0.id) }
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        Toggle("Show legend", isOn: $monitor.tools.showLegend)
                        Text(falseColorBlurb).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                ToolPill("Focus", icon: "viewfinder", isOn: $monitor.tools.peaking,
                         help: "Focus peaking — highlights in-focus edges", key: "E") {
                    pillPanel(width: 260) {
                        panelHeader("Focus Peaking", $monitor.tools.peaking)
                        Divider()
                        sliderRow("Sensitivity", low: "Less", high: "More",
                                  value: Binding(get: { (0.5 - monitor.tools.peakingThreshold) / 0.35 },
                                                 set: { monitor.tools.peakingThreshold = 0.5 - $0 * 0.35 }))
                        swatches("Colour", options: ["red", "yellow", "green", "blue"],
                                 selected: monitor.tools.peakingColor) { monitor.tools.peakingColor = $0 }
                    }
                }

                ToolPill("Zebra", icon: "line.diagonal", isOn: $monitor.tools.zebra,
                         help: "Zebra stripes over clipped highlights", key: "Z") {
                    pillPanel(width: 250) {
                        panelHeader("Zebra", $monitor.tools.zebra)
                        Divider()
                        percentRow("Level", value: $monitor.tools.zebraLevel, range: 0.5...1.0)
                        Text("Stripes appear above this luma level.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider().frame(height: 16)

                // ── Scopes (right-click any for placement / size / background) ──
                ToolPill("Histogram", icon: "chart.bar", isOn: $monitor.showHistogram,
                         help: "Luma histogram", key: "H") { scopePanel }
                ToolPill("Waveform", icon: "waveform.path.ecg", isOn: $monitor.showWaveform,
                         help: "Luma waveform — exposure across the frame", key: "W") { scopePanel }
                ToolPill("Vectorscope", icon: "circle.hexagongrid", isOn: $monitor.showVectorscope,
                         help: "Vectorscope — hue & saturation distribution", key: "V") { scopePanel }

                Divider().frame(height: 16)

                // ── Framing ───────────────────────────────────────
                ToolPill("Grid", icon: "grid", isOn: $showGrid, help: "Composition grid", key: "G") { gridPanel }

                ToolPill("Guides", icon: "aspectratio", isOn: $guidesVisible,
                         help: "Frame guides — show/hide", key: "A") {
                    FrameGuidesView(onPopOut: { openFrameGuides() })
                        .environmentObject(model).frame(width: 470, height: 460)
                }

                ToolPill("Video Out", icon: "rectangle.on.rectangle", isActive: false,
                         help: "External monitor / HDMI out  [⌘⇧M]", key: nil,
                         leftAction: { openVideoOutput() }) { videoOutPanel }

                Divider().frame(height: 16)

                // ── Orientation (pure toggles) ────────────────────
                ToolPill("Invert", icon: "circle.lefthalf.striped.horizontal", isOn: $monitor.tools.invert,
                         help: "Invert the image", key: "N")
                ToolPill("Flip H", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                         isOn: $monitor.tools.flipH, help: "Flip the image horizontally", key: "X")
                ToolPill("Flip V", icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                         isOn: $monitor.tools.flipV, help: "Flip the image vertically", key: "Y")
                Button {
                    let c = monitor.tools.rotate
                    monitor.tools.rotate = c == 0 ? 90 : (c == 90 ? 270 : 0)
                    ExportRotation.current = monitor.tools.rotate   // bake into exports/thumbnails
                } label: {
                    Label(monitor.tools.rotate == 0 ? "Vertical"
                          : "Vertical \(monitor.tools.rotate == 90 ? "↻" : "↺")",
                          systemImage: "rotate.right").lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(active: monitor.tools.rotate != 0))
                .help("Vertical mode — rotate the feed 90° for a camera mounted on its side (tap: off → CW → CCW)")

                // Anamorphic desqueeze — display only (recordings stay squeezed).
                // Left-click toggles off ↔ 2×; right-click picks the factor.
                ToolPill("Ana", icon: "rectangle.compress.vertical",
                         isActive: monitor.tools.anamorphic != 1.0,
                         help: "Anamorphic desqueeze — unsqueeze the monitor to the true taking aspect (display only)",
                         key: nil,
                         leftAction: { monitor.tools.anamorphic = monitor.tools.anamorphic != 1.0 ? 1.0 : 2.0 }) {
                    pillPanel(width: 220) {
                        Text("Anamorphic Desqueeze").font(.headline)
                        Text("Unsqueezes the monitor to the real taking aspect. Display only — the camera keeps recording the squeezed frame.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        ForEach([1.0, 1.33, 1.5, 1.8, 2.0], id: \.self) { f in
                            Button {
                                monitor.tools.anamorphic = f
                            } label: {
                                HStack {
                                    Text(f == 1.0 ? "Off (1.0×)" : String(format: "%.2f× squeeze", f))
                                    Spacer()
                                    if monitor.tools.anamorphic == f {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().frame(height: 16)

                // ── Flicker (custom analysis) ─────────────────────
                // HIDDEN for now per Daniel (2026-07-08): detection needs more
                // tuning before it earns a spot in the bar. The engine and the
                // K hotkey still exist — restore by flipping this to true.
                if showFlickerTool {
                    ToolPill("Flicker", icon: "light.beacon.max", isOn: $flicker.enabled,
                             help: "Highlight flickering areas + detect flicker frequency", key: "K") {
                        pillPanel(width: 250) {
                            panelHeader("Flicker", $flicker.enabled)
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Overlay sensitivity").foregroundStyle(.secondary).font(.caption)
                                Picker("", selection: Binding(get: { monitor.flickerSensitivity },
                                                              set: { monitor.flickerSensitivity = $0 })) {
                                    Text("Low").tag(0.08); Text("Med").tag(0.045); Text("High").tag(0.03)
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            Text("Higher catches subtle banding; lower shows only strong flicker.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Divider().frame(height: 16)
                }

                // ── LUT ───────────────────────────────────────────
                ToolPill(monitor.tools.lutName.isEmpty ? "LUT" : monitor.tools.lutName,
                         icon: "cube", isActive: !monitor.tools.lutName.isEmpty,
                         help: "Load a 3D LUT (.cube)",
                         leftAction: { chooseLUT() }) {
                    pillPanel(width: 230) {
                        Text("3D LUT").font(.headline)
                        Button { chooseLUT() } label: { Label("Load .cube…", systemImage: "folder") }
                        if !monitor.tools.lutName.isEmpty {
                            Text(monitor.tools.lutName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Button(role: .destructive) { monitor.clearLUT() } label: {
                                Label("Clear LUT", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(theme.chrome(0.14))
        .onChange(of: monitor.tools.peaking) { _, on in onPeakingChange(on) }
        .onChange(of: flicker.enabled) { _, on in onFlickerChange(on) }
    }

    private var falseColorBlurb: String {
        switch monitor.tools.falseColorMode {
        case "spectrum": return "Smooth pink→red gradient across exposure."
        case "elzone":   return "Stops from black (under) to white (over); grey at middle grey."
        default:         return "ARRI scale — red clips, green is 18% grey, purple crushes."
        }
    }

    // Shared scope settings — placement, size and background for all the scopes.
    // (Right-click any of Histogram / Waveform / Vectorscope to reach this.)
    private var scopePanel: some View {
        pillPanel(width: 250) {
            Text("Scopes").font(.headline)
            Toggle("Histogram", isOn: $monitor.showHistogram)
            Toggle("Waveform", isOn: $monitor.showWaveform)
            Toggle("Vectorscope", isOn: $monitor.showVectorscope)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Position").foregroundStyle(.secondary).font(.caption)
                Picker("", selection: $monitor.scopeCorner) {
                    Image(systemName: "arrow.up.left").tag(0)
                    Image(systemName: "arrow.up.right").tag(1)
                    Image(systemName: "arrow.down.left").tag(2)
                    Image(systemName: "arrow.down.right").tag(3)
                }.pickerStyle(.segmented).labelsHidden()
            }
            percentRow("Size", value: $monitor.scopeScale, range: 0.6...1.8)
            VStack(alignment: .leading, spacing: 4) {
                Text("Background").foregroundStyle(.secondary).font(.caption)
                Picker("", selection: $monitor.scopeLightBG) {
                    Text("Dark").tag(false); Text("Light").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    // Grid settings — clean rebuild: divisions (None = crosshair-only), an
    // independent centre crosshair, colour swatches, and an opacity slider.
    private var gridPanel: some View {
        pillPanel(width: 280) {
            panelHeader("Grid", $showGrid)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Divisions").foregroundStyle(.secondary).font(.caption)
                Picker("", selection: $gridDivisions) {
                    Text("None").tag(1)
                    Text("2×2").tag(2)
                    Text("Thirds").tag(3)
                    Text("4×4").tag(4)
                    Text("6×6").tag(6)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Toggle("Centre crosshair", isOn: $gridCrosshair)
            swatches("Colour", options: CameraModel.gridColors.map(\.0),
                     colorFor: { name in CameraModel.gridColors.first { $0.0 == name }?.1 ?? .white },
                     selected: gridColorName) { gridColorName = $0 }
            percentRow("Opacity", value: $gridOpacity, range: 0.05...1)
        }
    }

    // MARK: Popover building blocks (shared by every tool's settings panel)

    /// Right-click menu for the Video Out pill — full-screen the mirror feed,
    /// toggle overlays on it, or jump to offline downloaded-clip playback.
    private var videoOutPanel: some View {
        pillPanel(width: 300) {
            Text("Video Out").font(.headline)
            Text("Mirror the live / RAM-playback feed to a second display or HDMI out.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                openVideoOutput()
            } label: {
                Label("Open Video Out window", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                openVideoOutput()
                model.videoOutFullScreenTick += 1
            } label: {
                Label("Full Screen on 2nd display", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: Binding(get: { model.videoOutOverlays },
                                 set: { model.videoOutOverlays = $0 })) {
                Text("Show grid / guides on output")
            }
            .toggleStyle(.switch)
            Divider()
            Text("Phone / iPad feed (H.264)").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Quality").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.streamBitrateMbps >= 25 ? "Max" : "\(Int(model.streamBitrateMbps)) Mbps")
                        .font(.caption.monospaced())
                }
                Slider(value: Binding(get: { model.streamBitrateMbps },
                                      set: { model.streamBitrateMbps = $0 }), in: 2...25, step: 1)
            }
            .help("Bitrate of the low-latency wireless feed. Higher = sharper; lower = more headroom for many devices / weaker Wi-Fi. Leave at Max unless the feed struggles.")
            Divider()
            Text("Offline clip playback").font(.caption).foregroundStyle(.secondary)
            Button {
                openClips()
            } label: {
                Label("Play a downloaded clip…", systemImage: "play.tv")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Opens Project Clips — tap a clip's ▶ to play it on this Video Out monitor (decoded on the Mac). It returns to live when you close the Clip Playback window, go Live, or play from RAM.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pillPanel<C: View>(width: CGFloat = 260,
                                    @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16).frame(width: width)
    }

    /// The on/off switch that headlines a settings panel.
    private func panelHeader(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.headline) }
            .toggleStyle(.switch)
    }

    /// A 0…1 slider with a caption and low/high end labels.
    private func sliderRow(_ label: String, low: String, high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Slider(value: value, in: 0...1)
            HStack { Text(low); Spacer(); Text(high) }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A slider with a live percentage readout.
    private func percentRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospaced())
            }
            Slider(value: value, in: range)
        }
    }

    /// A labelled row of colour swatches.
    private func swatches(_ label: String, options: [String],
                          colorFor: @escaping (String) -> Color = MonitorBar.namedColor,
                          selected: String, pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { name in
                    Button { pick(name) } label: {
                        Circle().fill(colorFor(name)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: selected == name ? 2.5 : 0))
                    }
                    .buttonStyle(.plain).help(name.capitalized)
                }
            }
        }
    }

    static func namedColor(_ n: String) -> Color {
        switch n {
        case "red": return .red; case "yellow": return .yellow
        case "green": return .green; case "blue": return .blue
        default: return .white
        }
    }
}

/// A monitor-bar pill. The whole padded area is clickable (no dead space):
///   • left-click toggles the tool on/off
///   • right-click drops the settings popover (for tools that have options)
/// Active tools fill with the accent colour for at-a-glance state.
struct ToolPill<Settings: View>: View {
    let title: String
    let icon: String
    let isActive: Bool
    let help: String?
    let key: String?
    let leftAction: () -> Void
    let settings: () -> Settings
    @State private var showSettings = false
    private var hasSettings: Bool { Settings.self != EmptyView.self }

    /// Hover tooltip: description, the keyboard shortcut, and a right-click hint.
    private var tooltip: String {
        var s = help ?? title
        if let key { s += "  [\(key)]" }
        if hasSettings { s += " · right-click for options" }
        return s
    }

    var body: some View {
        Button(action: leftAction) { Label(title, systemImage: icon).lineLimit(1) }
            .buttonStyle(PillButtonStyle(active: isActive))
            .overlay { if hasSettings { RightClickCatcher { showSettings = true } } }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings() }
            .help(tooltip)
            .fixedSize()
    }
}

extension ToolPill {
    /// Toggle pill (left-click) with a right-click settings popover.
    init(_ title: String, icon: String, isOn: Binding<Bool>, help: String? = nil, key: String? = nil,
         @ViewBuilder settings: @escaping () -> Settings) {
        self.title = title; self.icon = icon; self.isActive = isOn.wrappedValue
        self.help = help; self.key = key
        self.leftAction = { isOn.wrappedValue.toggle() }; self.settings = settings
    }
    /// Custom left-click action with a right-click settings popover (e.g. LUT).
    init(_ title: String, icon: String, isActive: Bool, help: String? = nil, key: String? = nil,
         leftAction: @escaping () -> Void, @ViewBuilder settings: @escaping () -> Settings) {
        self.title = title; self.icon = icon; self.isActive = isActive
        self.help = help; self.key = key
        self.leftAction = leftAction; self.settings = settings
    }
}

extension ToolPill where Settings == EmptyView {
    /// Plain toggle pill — left-click flips the bound flag, no options menu.
    init(_ title: String, icon: String, isOn: Binding<Bool>, help: String? = nil, key: String? = nil) {
        self.title = title; self.icon = icon; self.isActive = isOn.wrappedValue
        self.help = help; self.key = key
        self.leftAction = { isOn.wrappedValue.toggle() }; self.settings = { EmptyView() }
    }
}

/// Invisible overlay that catches right-clicks (and passes left-clicks through to
/// the button below) so a pill can left-click-toggle yet right-click-configure.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { V(action) }
    func updateNSView(_ v: NSView, context: Context) { (v as? V)?.action = action }
    final class V: NSView {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func rightMouseDown(with event: NSEvent) { action() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return self
            default: return nil   // left-clicks fall through to the button
            }
        }
    }
}

/// The shared pill look. Because the padding lives *inside* the button style, the
/// entire rounded area is the hit target (the fix for the old dead-space pills).
struct PillButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.accentColor
                             : Color.white.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .foregroundStyle(active ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }
}

/// A thin draggable divider that resizes an adjacent panel (on its trailing /
/// bottom side) and writes the new size back through the binding.
private struct ResizeHandle: View {
    @Binding var size: Double
    let range: ClosedRange<Double>
    let vertical: Bool        // true: vertical bar resizing width; false: horizontal bar resizing height
    @State private var start: Double?
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        ZStack {
            theme.chrome(0.20)
            // .primary follows the colour scheme, so the grip stays visible at
            // every brightness — a fixed white line vanishes once the handle
            // inverts in Light.
            Rectangle().fill(Color.primary.opacity(0.25))
                .frame(width: vertical ? 1 : 30, height: vertical ? 30 : 1)
        }
        .frame(width: vertical ? 7 : nil, height: vertical ? nil : 7)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .contentShape(Rectangle())
        // Resize cursor via a balanced tracking area (NOT NSCursor.push/pop,
        // which leaks an unbalanced global cursor stack and wedges system UI).
        .background(ResizeCursor(cursor: vertical ? .resizeLeftRight : .resizeUpDown))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if start == nil { start = size }
                    let d = vertical ? v.translation.width : v.translation.height
                    size = min(max((start ?? size) - d, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil; NSCursor.arrow.set() }   // never leave the resize cursor set
        )
    }
}

/// Shows a cursor over its area using an AppKit tracking area — the system
/// balances it automatically, unlike NSCursor.push()/pop() which can leak an
/// unbalanced global cursor stack and freeze system overlays (Spotlight/Dock).
private struct ResizeCursor: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> NSView { Tracking(cursor: cursor) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Tracking)?.cursor = cursor }
    final class Tracking: NSView {
        var cursor: NSCursor
        private var area: NSTrackingArea?
        init(cursor: NSCursor) {
            self.cursor = cursor; super.init(frame: .zero)
            // If focus leaves while a resize cursor is showing (e.g. ⌘Space for
            // Spotlight, or the pointer slips off the bottom screen edge mid-drag),
            // restore the arrow so a custom cursor can't get wedged system-wide.
            NotificationCenter.default.addObserver(self, selector: #selector(restore),
                name: NSApplication.willResignActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self); NSCursor.arrow.set() }
        @objc private func restore() { NSCursor.arrow.set() }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let a = area { removeTrackingArea(a) }
            let a = NSTrackingArea(rect: .zero,
                                   options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                   owner: self)
            addTrackingArea(a); area = a
        }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    }
}

/// Grid + frame-guide overlay, drawn on the PICTURE (the aspect-fit image rect),
/// not the letterbox. Shared by the main viewer and the external SDI window.
struct MonitorOverlay: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        GeometryReader { geo in
            let rect = Self.fitted(aspect: model.monitor.imageAspect, in: geo.size)
            ZStack(alignment: .topLeading) {
                if model.guidesVisible {
                    ForEach(model.frameGuideList) { guide in
                        if guide.enabled {
                            let g = Self.guideRect(guide: guide, in: rect)
                            if guide.dimOutside > 0.01 {
                                Path { p in p.addRect(rect); p.addRect(g) }
                                    .fill(Color.black.opacity(guide.dimOutside), style: FillStyle(eoFill: true))
                            }
                            Path { $0.addRect(g) }.stroke(guide.color.opacity(guide.lineOpacity), lineWidth: 2)
                        }
                    }
                }
                if model.showGrid {
                    Path { p in
                        let n = max(model.gridDivisions, 1)
                        if n > 1 {
                            for i in 1..<n {
                                let fx = rect.minX + rect.width * CGFloat(i) / CGFloat(n)
                                let fy = rect.minY + rect.height * CGFloat(i) / CGFloat(n)
                                p.move(to: CGPoint(x: fx, y: rect.minY)); p.addLine(to: CGPoint(x: fx, y: rect.maxY))
                                p.move(to: CGPoint(x: rect.minX, y: fy)); p.addLine(to: CGPoint(x: rect.maxX, y: fy))
                            }
                        }
                        if model.gridCrosshair {
                            p.move(to: CGPoint(x: rect.midX - 16, y: rect.midY)); p.addLine(to: CGPoint(x: rect.midX + 16, y: rect.midY))
                            p.move(to: CGPoint(x: rect.midX, y: rect.midY - 16)); p.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 16))
                        }
                    }
                    .stroke(model.gridColor.opacity(model.gridOpacity), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func fitted(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        var w = size.width, h = size.height
        if aspect > size.width / size.height { h = w / aspect } else { w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
    static func guideRect(guide: FrameGuide, in rect: CGRect) -> CGRect {
        guard rect.height > 0 else { return rect }
        let ratio = CGFloat(guide.ratio)
        var w = rect.width, h = rect.height
        if ratio > rect.width / rect.height { h = w / ratio } else { w = h * ratio }
        w *= CGFloat(guide.scale); h *= CGFloat(guide.scale)
        let cx = rect.midX + CGFloat(guide.offsetX) * rect.width
        let cy = rect.midY + CGFloat(guide.offsetY) * rect.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

/// Clean, full-screen-able mirror of the processed SDI feed for an external
/// monitor (HDMI out) — image-flip / false-color / peaking are already baked
/// into the processed image; grid + frame guides are layered on top.
struct SDIOutputView: View {
    @EnvironmentObject var model: CameraModel
    @State private var window: NSWindow?
    @State private var floating = false
    @State private var pendingFull = false
    @State private var placed = false
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        ZStack {
            theme.viewerBackdrop(0.0)
            if let p = model.proxyPlayer {
                // Smooth, color-baked SDI proxy of an offloaded clip.
                PlayerLayerView(player: p)
            } else if let off = model.offlineImage {
                // Raw .cine fallback (no proxy available).
                Image(decorative: off, scale: 1.0).resizable().aspectRatio(contentMode: .fit)
            } else if let img = model.monitor.processedImage {
                Image(decorative: img, scale: 1.0).resizable().aspectRatio(contentMode: .fit)
            } else if let img = model.viewerImage {
                Image(decorative: img, scale: 1.0).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("No video signal — start the SDI viewer in Phantom Control")
                    .foregroundStyle(.secondary)
            }
            if model.isPlayingOffline {
                VStack {
                    HStack(alignment: .top) {
                        ClipHeadsUp()
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
            if model.videoOutOverlays {
                if model.overlayEnabled, let ov = model.overlayImage {
                    Image(decorative: ov, scale: 1.0)
                        .resizable().aspectRatio(contentMode: .fit)
                        .opacity(model.effectiveOverlayOpacity)
                }
                MonitorOverlay(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.viewerBackdrop(0.0))
        // Separate Window (id "video-output") — needs its own scheme, and its
        // overlays/badges must render against the theme, not a stale dark one.
        .themed()
        .ignoresSafeArea()
        .background(WindowAccessor { w in
            window = w
            w?.collectionBehavior.insert(.fullScreenPrimary)   // allow true full screen
            w?.isMovableByWindowBackground = true              // drag anywhere (no title bar)
            placeOnExternalDisplay(w)                          // pop to 2nd display + fullscreen
            applyPendingFull()                                 // a just-opened window can now fill
        })
        // The Video Out menu's "Full Screen on 2nd display" bumps this tick.
        .onChange(of: model.videoOutFullScreenTick) { _, _ in
            pendingFull = true
            applyPendingFull()
        }
        // Double-click → fills the whole display (menu bar hidden) for a clean
        // client/second-monitor feed. Double-click or Esc to exit.
        .onTapGesture(count: 2) { window?.toggleFullScreen(nil) }
        .contextMenu {
            let full = window?.styleMask.contains(.fullScreen) == true
            Button(full ? "Exit Full Screen" : "Full Screen (fill display)") {
                window?.toggleFullScreen(nil)
            }
            Button(floating ? "✓ Always on Top" : "Always on Top") {
                floating.toggle()
                window?.level = floating ? .floating : .normal
            }
            Button(model.videoOutOverlays ? "Hide Overlays (clean feed)" : "Show Overlays") {
                model.videoOutOverlays.toggle()
            }
        }
    }

    /// Fills the display if a full-screen request is pending and the window is
    /// ready. Retried from both the window callback and the tick observer so a
    /// just-opened window still goes full screen.
    private func applyPendingFull() {
        guard pendingFull, let w = window else { return }
        if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        pendingFull = false
    }

    /// On open, move the Video Out window onto the external display (if one is
    /// connected) and fill it — the client monitor is almost always the 2nd
    /// screen. Runs once. With no external display it leaves the window alone.
    private func placeOnExternalDisplay(_ w: NSWindow?) {
        guard let w, !placed else { return }
        placed = true
        guard let ext = NSScreen.screens.first(where: { $0 != NSScreen.main }) else { return }
        w.setFrame(ext.frame, display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
    }
}

/// Grabs the hosting NSWindow so SwiftUI can drive AppKit window behaviour
/// (e.g. toggling true full screen).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// The "set it and forget it" frame-guide editor — a closeable window with a
/// configurable row per guide (ratio, scale, position, color, line, dim).
struct FrameGuidesView: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject private var theme = AppTheme.shared
    var onPopOut: (() -> Void)? = nil   // when shown in a popover, lets you detach to a window
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Frame Guides").font(.headline)
                Spacer()
                if let onPopOut {
                    Button { onPopOut() } label: { Image(systemName: "macwindow.and.cursorarrow") }
                        .buttonStyle(.borderless)
                        .help("Open in a separate window")
                }
                Button { model.frameGuideList.append(FrameGuide()) } label: {
                    Label("Add Guide", systemImage: "plus")
                }
            }
            .padding()
            Divider()
            if model.frameGuideList.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "aspectratio").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No frame guides yet").foregroundStyle(.secondary)
                    Button("Add a guide") { model.frameGuideList.append(FrameGuide()) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($model.frameGuideList) { $guide in
                            GuideRowView(guide: $guide,
                                         srcW: model.resWidth, srcH: model.resHeight,
                                         onDelete: {
                                let gid = guide.id
                                model.frameGuideList.removeAll { $0.id == gid }
                            })
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 470, minHeight: 360, maxHeight: .infinity, alignment: .top)
        .background(theme.chrome(0.12))
        .themed()
    }
}

struct GuideRowView: View {
    @Binding var guide: FrameGuide
    let srcW: Int
    let srcH: Int
    let onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button { guide.enabled.toggle() } label: {
                    Image(systemName: guide.enabled ? "eye" : "eye.slash")
                        .foregroundStyle(guide.enabled ? Color.primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(guide.enabled ? "Hide this guide" : "Show this guide")
                Picker("", selection: $guide.ratioName) {
                    ForEach(CameraModel.frameGuidePresets, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().fixedSize()
                if guide.ratioName == "Custom" {
                    TextField("ratio", value: $guide.customRatio,
                              format: .number.precision(.fractionLength(2))).frame(width: 56)
                    Text(": 1").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $guide.colorName) {
                    ForEach(CameraModel.gridColors, id: \.0) { name, _ in Text(name.capitalized).tag(name) }
                }
                .labelsHidden().fixedSize()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            // Scale row shows the resulting crop RESOLUTION (px) at the source frame.
            HStack {
                Text("Scale").frame(width: 56, alignment: .leading).foregroundStyle(.secondary).font(.caption)
                Slider(value: $guide.scale, in: 0.2...1.0)
                let c = guide.cropResolution(srcW: srcW, srcH: srcH)
                Text("\(c.w)×\(c.h)").font(.caption.monospaced()).frame(width: 92, alignment: .trailing)
            }
            sliderRow("Line", $guide.lineOpacity, 0...1.0)
            sliderRow("Dim out", $guide.dimOutside, 0...1.0)
            HStack {
                Text("Offset").frame(width: 56, alignment: .leading).foregroundStyle(.secondary).font(.caption)
                Text("X").font(.caption2)
                Slider(value: $guide.offsetX, in: -0.5...0.5)
                Text("Y").font(.caption2)
                Slider(value: $guide.offsetY, in: -0.5...0.5)
                Button("Center") { guide.offsetX = 0; guide.offsetY = 0 }.font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    private func sliderRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 56, alignment: .leading).foregroundStyle(.secondary).font(.caption)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospaced()).frame(width: 92, alignment: .trailing)
        }
    }
}

/// Scrolling thumbnail grid of saved screen grabs — newest first, the most
/// recent rows visible and the rest of the project folder a scroll away.
struct ScreenshotGallery: View {
    let urls: [URL]
    let selectedName: String
    let onPick: (URL) -> Void
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                ForEach(urls, id: \.self) { url in
                    ScreenshotThumb(
                        url: url,
                        selected: url.deletingPathExtension().lastPathComponent == selectedName,
                        onTap: { onPick(url) }
                    )
                }
            }
            .padding(2)
        }
        .frame(maxHeight: 184)   // ~10 recent grabs reachable; older ones scroll
        .background(theme.viewerBackdrop(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// One gallery thumbnail. Loads a small downscaled image off the main thread
/// (the grabs are full 4K PNGs) and caches it for the view's lifetime.
struct ScreenshotThumb: View {
    let url: URL
    let selected: Bool
    let onTap: () -> Void
    @State private var thumb: NSImage?
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    theme.viewerBackdrop(0.18)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.12),
                        lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(url.deletingPathExtension().lastPathComponent)
        .task(id: url) { thumb = await Self.thumbnail(url) }
    }

    static func thumbnail(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// Onion-skin overlay controls (SmallHD-style): grab a reference frame, lay it
/// over the live image at adjustable opacity, and optionally blink between the
/// two to spot misalignment.
struct OverlayPanel: View {
    @EnvironmentObject var model: CameraModel
    var onPopOut: (() -> Void)? = nil   // detach to a window (also enables drag-and-drop)
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Image Overlay").font(.headline)
                Spacer()
                if let onPopOut {
                    Button { onPopOut() } label: { Image(systemName: "macwindow.and.cursorarrow") }
                        .buttonStyle(.borderless)
                        .help("Open in a separate window (drag-and-drop images here)")
                }
            }

            Button { model.grabScreenshot() } label: {
                Label("Grab Screenshot", systemImage: "camera").frame(maxWidth: .infinity)
            }
            // Thumbnail gallery (like the iPad app): newest grabs first, the
            // most recent ~10 visible, scroll for the rest of the project folder.
            let shots = model.screenshotURLs()
            if shots.isEmpty {
                Text("No screen grabs yet — tap Grab Screenshot")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScreenshotGallery(urls: shots, selectedName: model.overlayName) { url in
                    model.loadOverlay(url)
                }
            }

            if model.overlayImage != nil {
                Divider()
                Toggle(isOn: $model.overlayEnabled) {
                    Text(model.overlayName.isEmpty ? "Show overlay" : model.overlayName)
                        .lineLimit(1).truncationMode(.middle)
                }

                // Opacity (default 50%, SmallHD-style)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Opacity").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text("\(Int(model.overlayOpacity * 100))%").font(.caption.monospaced())
                    }
                    Slider(value: $model.overlayOpacity, in: 0...1)
                }
                .disabled(!model.overlayEnabled)

                // Blink: 0 = off … 10 = on/off ~2×/sec (matches SmallHD's scale)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Blink").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text(model.overlayBlinkSpeed == 0 ? "Off" : "Speed \(model.overlayBlinkSpeed)")
                            .font(.caption.monospaced())
                    }
                    Slider(value: Binding(get: { Double(model.overlayBlinkSpeed) },
                                          set: { model.overlayBlinkSpeed = Int($0.rounded()) }),
                           in: 0...10, step: 1)
                }
                .disabled(!model.overlayEnabled)

                Divider()
                HStack {
                    Button("Reveal Folder") { NSWorkspace.shared.open(model.screenshotsFolder()) }
                    Spacer()
                    Button("Clear", role: .destructive) { model.clearOverlay() }
                }
                .font(.callout)
            } else {
                Text("Grab a frame, load a saved grab, or drag an image in to start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
            .padding(2))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            CameraModel.loadOverlayDrop(providers, into: model)
        }
    }
}

/// Contact-sheet browser of the project's downloaded clips, with metadata,
/// checksum status and a one-click DIT report (CSV + PDF).
struct ClipBrowserView: View {
    @EnvironmentObject var model: CameraModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var theme = AppTheme.shared
    @State private var clips: [ClipEntry] = []
    @State private var working = false
    @State private var generating = false
    @State private var lastReport: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Project Clips").font(.headline)
                if !clips.isEmpty {
                    Text("\(clips.count) · \(String(format: "%.1f GB", clips.reduce(0) { $0 + $1.sizeGB }))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if generating { ProgressView().controlSize(.small) }
                if let pdf = lastReport {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([pdf]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }.help("Show the report in Finder")
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan the project folder")
                Button {
                    generating = true; lastReport = nil
                    model.exportReport(clips) { pdf in
                        generating = false; lastReport = pdf
                        NSWorkspace.shared.activateFileViewerSelecting([pdf])
                    }
                } label: {
                    Label(generating ? "Generating…" : "Export Report", systemImage: "doc.text")
                }
                .disabled(clips.isEmpty || generating)
                .help("Write a CSV + thumbnailed PDF DIT report into the project folder")
            }
            .padding()
            Divider()
            if clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No downloaded clips in this project yet").foregroundStyle(.secondary)
                    Text(model.currentProjectFolder().path).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)], spacing: 12) {
                        ForEach(clips) { clipCard($0) }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 440)
        .background(theme.chrome(0.12)).themed()
        .onAppear { reload() }
    }

    private func clipCard(_ c: ClipEntry) -> some View {
        let d = c.lookup
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Rectangle().fill(theme.viewerBackdrop(0.0))
                if let t = c.thumb, let img = NSImage(contentsOf: t) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 6))
            // Big play button DEAD CENTER → play on the Video Out monitor and pop
            // open the Clip Playback scrub window.
            .overlay {
                let playing = c.url == model.offlineClipURL
                Button {
                    if playing {
                        model.stopOfflinePlayback()          // toggle back to live
                    } else {
                        model.playClipOnVideoOut(c)
                        openWindow(id: "video-output")        // make sure the monitor is up
                        openWindow(id: "clip-playback")       // scrub window for this clip
                    }
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 3)
                }
                .buttonStyle(.plain)
                .help("Play this clip on the Video Out monitor + open the scrub window. Closing Project Clips, going Live, or playing from RAM returns Video Out to live.")
            }
            // Secondary: reveal in Finder (bottom-right).
            .overlay(alignment: .bottomTrailing) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([c.url])
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Reveal in Finder")
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.cyan, lineWidth: c.url == model.offlineClipURL ? 3 : 0)
            }
            HStack {
                Text(c.name).font(.caption.bold()).lineLimit(1)
                Spacer()
                Image(systemName: c.md5 != nil ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(c.md5 != nil ? Color.green : Color.secondary).font(.caption)
            }
            Text([d["Resolution"], d["FrameRate"], d["ShutterAngle"]].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            let prod = [d["Lens"], d["Scene"].map { "Sc \($0)" }, d["Take"].map { "Tk \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !prod.isEmpty { Text(prod).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Text(String(format: "%.2f GB", c.sizeGB)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(theme.chrome(0.16)).clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
        .help("Double-click to reveal in Finder")
    }

    private func reload() {
        clips = model.projectClips()
        if clips.contains(where: { $0.thumb == nil }), !working {
            working = true
            model.generateMissingThumbnails(clips) {
                working = false
                clips = model.projectClips()
            }
        }
    }
}

// MARK: - Project Clips side panel (lives in the Play-tab rail)

/// Compact, permanent clip browser in the right rail (Play tab). Collapsible;
/// single- or double-column thumbnail strip. The center ▶ plays a clip on the
/// Video Out monitor and opens the Clip Playback scrub window.
struct ProjectClipsPanel: View {
    @EnvironmentObject var model: CameraModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var theme = AppTheme.shared
    var standalone = false      // true = own tab (no disclosure wrapper)
    @State private var clips: [ClipEntry] = []
    @State private var working = false
    @State private var generating = false
    @AppStorage("clipPanelColumns") private var columns = 1
    @AppStorage("clipPanelExpanded") private var expanded = true
    @AppStorage("clipSort") private var sort = 0   // 0 newest · 1 oldest · 2 name · 3 size

    private var sortedClips: [ClipEntry] {
        switch sort {
        case 1: return clips.sorted { $0.date < $1.date }
        case 2: return clips.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case 3: return clips.sorted { $0.sizeBytes > $1.sizeBytes }
        default: return clips.sorted { $0.date > $1.date }   // newest first
        }
    }

    var body: some View {
        Group {
            if standalone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Project Clips").font(.headline)
                        if !clips.isEmpty {
                            Text("\(clips.count) · \(String(format: "%.1f GB", clips.reduce(0) { $0 + $1.sizeGB }))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if working { ProgressView().controlSize(.small) }
                    }
                    content
                }
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    content.padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("Project Clips").font(.caption).foregroundStyle(.secondary)
                        if !clips.isEmpty {
                            Text("\(clips.count) · \(String(format: "%.1f GB", clips.reduce(0) { $0 + $1.sizeGB }))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if working { ProgressView().controlSize(.small) }
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan the project folder")
                Button { columns = (columns == 1 ? 2 : 1) } label: {
                    Image(systemName: columns == 1 ? "square.grid.2x2" : "rectangle.grid.1x2")
                }
                .help(columns == 1 ? "Two columns" : "Single column")
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Newest first").tag(0)
                        Text("Oldest first").tag(1)
                        Text("Name").tag(2)
                        Text("Size").tag(3)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sort clips")
                Spacer()
                if generating { ProgressView().controlSize(.small) }
                Button {
                    generating = true
                    model.exportReport(clips) { pdf in
                        generating = false
                        NSWorkspace.shared.activateFileViewerSelecting([pdf])
                    }
                } label: { Label("Report", systemImage: "doc.text") }
                .disabled(clips.isEmpty || generating)
                .help("Export the DIT report (PDF + CSV) for this project")
            }
            .font(.caption)
            .buttonStyle(.borderless)

            Toggle(isOn: $model.preferRawPlayback) {
                Text("Play RAW (clean, no overlays)").font(.caption2)
            }
            .toggleStyle(.switch)
            .help("Play the raw .cine instead of the SDI proxy — a clean image with no baked-in monitoring overlays (ungraded, and slower to decode)")

            let needProxy = clips.filter { $0.proxyURL == nil }.count
            if needProxy > 0 || model.proxyGenClip != nil {
                Button {
                    model.generateAllProxies(clips)
                } label: {
                    if model.proxyGenClip != nil {
                        Label("Making proxies… \(Int((model.proxyGenProgress ?? 0) * 100))%",
                              systemImage: "wand.and.stars")
                    } else {
                        Label("Make all proxies (\(needProxy))", systemImage: "wand.and.stars")
                    }
                }
                .font(.caption)
                .disabled(model.proxyGenClip != nil)
                .help("Transcode every clip that doesn't have a .mov proxy yet (one at a time)")
            }

            if clips.isEmpty {
                Text("No downloaded clips in this project yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                          spacing: 8) {
                    ForEach(sortedClips) { clipTile($0) }
                }
            }
        }
    }

    private func clipTile(_ c: ClipEntry) -> some View {
        let playing = c.url == model.offlineClipURL
        return VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Rectangle().fill(theme.viewerBackdrop(0.0))
                if let t = c.thumb, let img = NSImage(contentsOf: t) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
                Button {
                    if playing {
                        model.stopOfflinePlayback()
                    } else {
                        model.playClipOnVideoOut(c)
                        openWindow(id: "video-output")
                        openWindow(id: "clip-playback")
                    }
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: columns == 1 ? 40 : 30))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
            }
            .frame(height: columns == 1 ? 120 : 78)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottomTrailing) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([c.url]) } label: {
                    Image(systemName: "folder")
                        .font(.caption2).padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding(4)
                .help("Reveal in Finder")
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5).stroke(Color.cyan, lineWidth: playing ? 2 : 0)
            }
            HStack(spacing: 4) {
                Text(c.name).font(.caption2.bold()).lineLimit(1)
                Spacer()
                Image(systemName: c.md5 != nil ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(c.md5 != nil ? Color.green : Color.secondary).font(.caption2)
            }
            HStack(spacing: 4) {
                Text(String(format: "%.1f GB", c.sizeGB)).font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                if c.proxyURL != nil {
                    Label("proxy", systemImage: "film.stack").font(.system(size: 9)).foregroundStyle(.cyan)
                } else if model.proxyGenClip == c.url {
                    HStack(spacing: 3) {
                        ProgressView(value: model.proxyGenProgress ?? 0).frame(width: 40)
                        Text("\(Int((model.proxyGenProgress ?? 0) * 100))%").font(.system(size: 9).monospaced())
                    }
                } else {
                    Button { model.generateProxy(for: c) } label: {
                        Label("Make proxy", systemImage: "wand.and.stars").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.proxyGenClip != nil)
                    .help("Transcode this .cine to a smooth .mov proxy")
                }
            }
        }
    }

    private func reload() {
        clips = model.projectClips()
        if clips.contains(where: { $0.thumb == nil }), !working {
            working = true
            model.generateMissingThumbnails(clips) {
                working = false
                clips = model.projectClips()
            }
        }
    }
}

// MARK: - Clip Playback control window (scrub the Video-Out offline clip)

/// A small control surface for the downloaded clip currently playing on the
/// Video Out monitor — scrub / play / step it independently of the RAM deck.
struct ClipPlaybackView: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        Group {
            if model.proxyPlayer != nil {
                // SDI proxy (.mov): AVPlayerLayer (NOT AVKit's VideoPlayer, which
                // crashes on generic-metadata init in SwiftPM apps) + a custom
                // scrubber/transport, with the heads-up overlay.
                ProxyPlaybackControls()
            } else if let player = model.offlinePlayer, let url = model.offlineClipURL {
                // Raw .cine fallback (no proxy on disk).
                ClipPlaybackControls(player: player).id(url)
                    .overlay(alignment: .topLeading) { ClipHeadsUp().padding(10) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No clip playing").foregroundStyle(.secondary)
                    Text("Hit the ▶ on a clip in Project Clips to play it on Video Out.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(theme.chrome(0.13)).themed()
        // Remember where the user parks this window across launches.
        .background(WindowAccessor { $0?.setFrameAutosaveName("ClipPlaybackWindow") })
        // Closing this window is what returns the Video Out monitor to live.
        .onDisappear { model.stopOfflinePlayback() }
    }
}

/// Observes one offline CinePlayerModel and gives it a big preview + scrubber +
/// transport. The Video Out monitor follows whatever this does.
struct ClipPlaybackControls: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject var player: CinePlayerModel
    @ObservedObject private var theme = AppTheme.shared

    var body: some View {
        let count = max(player.info?.frameCount ?? 1, 1)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tv").foregroundStyle(.cyan)
                Text(player.url.lastPathComponent).font(.callout.bold()).lineLimit(1)
                if let info = player.info {
                    Text("\(info.width)×\(info.height) · \(Int(info.frameRate)) fps")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.stopOfflinePlayback() } label: {
                    Label("Stop / Live", systemImage: "stop.fill")
                }
                .font(.caption)
                .help("Stop offline playback — Video Out returns to the live feed")
            }
            // Big preview so fine detail is visible while scrubbing.
            ZStack {
                theme.viewerBackdrop(0.0)
                if let img = player.image {
                    Image(decorative: img, scale: 1.0).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // scrubber
            GeometryReader { geo in
                let w = geo.size.width
                let frac = CGFloat(player.frameIndex) / CGFloat(max(count - 1, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.chrome(0.3)).frame(height: 6).offset(y: 9)
                    Capsule().fill(.cyan).frame(width: max(frac * w, 0), height: 6).offset(y: 9)
                    Rectangle().fill(.white).frame(width: 2, height: 22).offset(x: frac * w - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.stop()
                    let f = Double(min(max(v.location.x / w, 0), 1)) * Double(count - 1)
                    player.showFrame(Int(f))
                })
            }
            .frame(height: 24)
            HStack(spacing: 18) {
                Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill").font(.title2) }
                    .buttonStyle(.plain)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                Button { player.step(1) } label: { Image(systemName: "forward.frame.fill").font(.title2) }
                    .buttonStyle(.plain)
                Button { player.loopPlayback.toggle() } label: {
                    Image(systemName: "repeat").font(.title2)
                        .foregroundStyle(player.loopPlayback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(player.frameIndex + 1) / \(count)").font(.callout.monospaced())
            }
        }
        .padding(14)
    }
}

/// Proxy (.mov) transport for the Clip Playback window — uses AVPlayerLayer
/// (via PlayerLayerView), NOT AVKit's VideoPlayer, which crashes on init in a
/// SwiftPM-built app. The Video Out monitor shares the same AVPlayer.
struct ProxyPlaybackControls: View {
    @EnvironmentObject var model: CameraModel
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                ClipHeadsUp()
                Spacer()
                Button { model.stopOfflinePlayback() } label: {
                    Label("Stop / Live", systemImage: "stop.fill")
                }
                .font(.caption)
                .help("Stop offline playback — Video Out returns to the live feed")
            }
            if let p = model.proxyPlayer {
                PlayerLayerView(player: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Slider(value: Binding(get: { model.proxyFrac },
                                  set: { model.proxySeek(toFraction: $0) }), in: 0...1)
            HStack(spacing: 18) {
                Spacer()
                Button { model.proxyTogglePlay() } label: {
                    Image(systemName: model.proxyPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                Spacer()
                Text("frame \(model.proxyFrame)").font(.callout.monospaced())
            }
        }
        .padding(14)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: CameraModel
    @EnvironmentObject var cineStation: CineStationModel
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.openWindow) private var openWindow
    @State private var confirmPartitions = false
    @State private var pendingPartitions = 1
    // Safety notice — re-shown on every new beta version (version-keyed).
    @AppStorage("safetyAckVersion") private var safetyAckVersion = ""
    @State private var showSafetyNotice = false
    @State private var cineDropActive = false
    /// Right-rail tab. Camera/Save mirror the camera's live/play mode; Clips is a
    /// standalone offline-clip browser that leaves the camera mode untouched.
    private enum RailTab: Hashable { case camera, save, clips }
    @State private var railTab: RailTab = .camera

    var body: some View {
        VStack(spacing: 0) {
            // Draggable handles resize the settings rail (←→) and the partition
            // strip (↑↓); both sizes persist across launches via @AppStorage.
            HStack(spacing: 0) {
                viewer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(size: $railWidth, range: 300...720, vertical: true)
                rightRail
                    .frame(width: railWidth)
            }
            .frame(maxHeight: .infinity)
            ResizeHandle(size: $partitionHeight, range: 56...560, vertical: false)
            partitionStrip
                .frame(height: partitionHeight)
            statusBar
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(theme.chrome(0.12))
        .themed()
        // Drop a .cine anywhere to play it, or an image to load it as an overlay.
        .dropDestination(for: URL.self) { urls, _ in
            let cines = urls.filter { $0.pathExtension.lowercased() == "cine" }
            for url in cines { openWindow(value: url) }
            let images = urls.filter { CameraModel.overlayImageExts.contains($0.pathExtension.lowercased()) }
            if let img = images.first { model.importOverlay(from: img) }
            return !cines.isEmpty || !images.isEmpty
        } isTargeted: { cineDropActive = $0 }
        .overlay {
            if cineDropActive {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                        Text("Drop a .cine to play — or an image to overlay")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.white)
                }
                .allowsHitTesting(false)
            }
        }
        .background(monitorShortcuts)   // invisible layer that owns the hotkeys
        // Don't let the first text field grab focus on launch, or it eats every
        // keystroke and the monitoring hotkeys never fire.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { clearTextFocus() }
            // Safety notice, once per version.
            if safetyAckVersion != AppInfo.shortVersion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showSafetyNotice = true }
            }
        }
        .alert("Phantom Control — Beta Software", isPresented: $showSafetyNotice) {
            Button("I Understand") {
                safetyAckVersion = AppInfo.shortVersion
            }
        } message: {
            Text("""
            This is beta software. Please test every feature thoroughly before relying on it for a job — improper use could result in loss of footage.

            YOUR CAMERA IS SAFE. Phantom Control talks to your camera using the same standard Ethernet control commands as Vision Research's own PCC software — it reads status and sends normal settings, capture, and playback commands. It does NOT modify, update, or flash camera firmware, and nothing it does can physically harm the camera.

            The only real risk is DATA LOSS: actions that erase a CineMag, clear RAM, or overwrite files remove footage for good. These always ask you to confirm first — read the prompt before clicking.
            """)
        }
        .overlay(alignment: .top) { downloadToast }
        .animation(.spring(duration: 0.35), value: model.downloadToast)
        .alert("Verification failed", isPresented: Binding(
            get: { model.verifyFailedAlert != nil },
            set: { if !$0 { model.verifyFailedAlert = nil } })) {
            Button("OK", role: .cancel) { model.verifyFailedAlert = nil }
        } message: {
            if let v = model.verifyFailedAlert {
                Text("\(v.clip) did not pass verification:\n\(v.message)\n\nThe copy was NOT marked saved and the partition was not cleared — re-download it.")
            }
        }
        // Black-balance-first reminder before any white balance.
        .alert("Black balance first?", isPresented: $model.showBlackRefWarning) {
            Button("Run Black Reference, then WB") { model.blackRefThenWhiteBalance() }
            Button("Already did it on the camera") {
                // The body has its own black-ref button (next to the lens cap) —
                // trust the operator and stop nagging for this session.
                model.blackRefDone = true
                model.proceedWithPendingWhiteBalance()
            }
            Button("White balance anyway") { model.proceedWithPendingWhiteBalance() }
            Button("Cancel", role: .cancel) {
                model.pendingWhiteBalance = nil
                model.showBlackRefWarning = false
            }
        } message: {
            Text("You haven't taken a Black Reference through the app this session. White balancing without a black balance can throw the colour off, because a per-channel black offset skews the balance.\n\nCorrect order: cap the lens (or close the shutter), run Black Reference, THEN white balance off a grey card. If you already used the camera's own black-ref button, pick \"Already did it\".")
        }
        // Frame-rate change → the black shade is now stale (it's calibrated per
        // rate). Center-screen so it can't be missed, with a run-it-now button.
        .alert("Re-do Black Reference", isPresented: $model.showBlackShadeReminder) {
            Button("Run Black Reference") { model.blackReference() }
            Button("Already did it on the camera") { model.blackRefDone = true }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Frame rate changed to \(model.blackShadeReminderRate) fps. The sensor's black shade is calibrated per frame rate, so it's now stale — recordings will show fixed-pattern noise until you redo it.\n\nCap the lens, then tap Run Black Reference. (This camera has no auto shutter, so the lens must be capped for a valid reference.) If you already ran it from the camera's own button, pick \"Already did it\".")
        }
        // Master reset (Help ▸ Reset Camera). Destructive — warn before wiping.
        .alert("Reset Camera?", isPresented: $model.showResetCamera) {
            Button("Reset Camera", role: .destructive) { model.resetCamera() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears everything in RAM and returns the camera to a clean state:\n\n• Erases all unsaved shots in RAM\n• Full resolution at the maximum frame rate\n• 180° shutter · single partition\n• Clears any speed ramp\n• White balance to daylight (5600K) · base EI\n\nAnything not saved to a CineMag or your laptop will be lost. You'll be prompted to re-do the black reference (cap the lens) afterward.")
        }
    }

    @ViewBuilder
    private var downloadToast: some View {
        if let toast = model.downloadToast {
            HStack(spacing: 11) {
                Image(systemName: toast.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(toast.ok ? .green : .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.title).font(.callout.bold())
                    Text(toast.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke((toast.ok ? Color.green : Color.red).opacity(0.55), lineWidth: 1))
            .shadow(radius: 14, y: 5)
            .padding(.top, 14)
            .onTapGesture { model.dismissDownloadToast() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Keyboard shortcuts (monitoring)

    /// Hidden buttons that own the single-key monitoring hotkeys. Kept in the
    /// view tree (zero-size) so the shortcuts are always live while the main
    /// window is key. Plain keys yield to focused text fields automatically.
    private var monitorShortcuts: some View {
        ZStack {
            hotkey("f")  { model.monitor.tools.falseColor.toggle() }
            hotkey("f", [.shift]) { cycleFalseColorMode() }
            hotkey("e")  { model.monitor.tools.peaking.toggle() }
            hotkey("z")  { model.monitor.tools.zebra.toggle() }
            hotkey("h")  { model.monitor.showHistogram.toggle() }
            hotkey("w")  { model.monitor.showWaveform.toggle() }
            hotkey("v")  { model.monitor.showVectorscope.toggle() }
            hotkey("g")  { model.showGrid.toggle() }
            hotkey("a")  { model.guidesVisible.toggle() }
            hotkey("k")  { model.flicker.enabled.toggle() }
            hotkey("n")  { model.monitor.tools.invert.toggle() }
            hotkey("x")  { model.monitor.tools.flipH.toggle() }
            hotkey("y")  { model.monitor.tools.flipV.toggle() }
            hotkey("b")  { toggleOverlayHotkey() }
            hotkey("[")  { bumpScopeSize(-0.1) }
            hotkey("]")  { bumpScopeSize(0.1) }
            hotkey("\\") { model.monitor.scopeLightBG.toggle() }
            hotkey("m")  { togglePunch() }
            hotkey("c")  { model.toggleOfflinePlayback() }   // Video Out: clip ↔ live
            // ⌘1…⌘9 select Cine 1…9 in RAM.
            ForEach(1...9, id: \.self) { n in
                hotkey(KeyEquivalent(Character("\(n)")), [.command]) { selectCineByNumber(n) }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func hotkey(_ key: KeyEquivalent, _ mods: EventModifiers = [],
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.frame(width: 0, height: 0) }
            .buttonStyle(.plain)
            .keyboardShortcut(key, modifiers: mods)
    }

    private func cycleFalseColorMode() {
        let modes = SDIProcessor.falseColorModes.map(\.id)
        if !model.monitor.tools.falseColor { model.monitor.tools.falseColor = true; return }
        if let i = modes.firstIndex(of: model.monitor.tools.falseColorMode) {
            model.monitor.tools.falseColorMode = modes[(i + 1) % modes.count]
        }
    }
    private func toggleOverlayHotkey() {
        if model.overlayImage == nil { showOverlayPanel = true } else { model.overlayEnabled.toggle() }
    }
    private func bumpScopeSize(_ d: Double) {
        model.monitor.scopeScale = min(1.8, max(0.6, model.monitor.scopeScale + d))
    }
    private func selectCineByNumber(_ n: Int) {
        if model.cines.contains(where: { $0.id == n }) { model.selectCine(n) }
    }
    // Punch-in focus zoom.
    private func togglePunch() { punchZoom > 1 ? resetPunch() : setPunch(2) }
    private func setPunch(_ z: CGFloat) { punchZoom = z; punchZoomBase = z; punchOffset = .zero; punchOffsetBase = .zero }
    private func resetPunch() { setPunch(1) }
    private func clampPunch(_ s: CGSize) -> CGSize {
        let b = 360 * (punchZoom - 1)
        return CGSize(width: min(b, max(-b, s.width)), height: min(b, max(-b, s.height)))
    }
    /// Drop first-responder so no text field keeps eating keystrokes/hotkeys.
    private func clearTextFocus() { NSApp.keyWindow?.makeFirstResponder(nil) }

    // MARK: Viewer

    @State private var showRampSheet = false
    @State private var showShortcuts = false
    @State private var remoteURLNonce = 0   // bump to recompute the phone URL/QR after a Wi-Fi change
    @StateObject private var hotspot = FieldHotspot()   // "no Wi-Fi on set" helper
    @State private var showOverlayPanel = false
    @State private var showVideoOut = false
    @State private var showViewerImage = false
    @State private var showGenlock = false
    @State private var showSyncHelp = false

    private func syncHint(_ m: CameraModel.SyncMode) -> String {
        switch m {
        case .internalClock:
            return "Normal mode — the camera's own crystal sets the frame rate."
        case .externalFSync:
            return "Frame rate is driven by a frame-sync PULSE into the F-Sync line (capture cable). Use to gang multiple Phantoms: one outputs F-Sync, the others take it in. Note: a sync generator's tri-level/black-burst is NOT a frame pulse — see the ? help."
        case .irig:
            return "Frame rate is driven by an IRIG-B timecode signal (rates lock to multiples of 100 fps). Use when the house has an IRIG timecode generator."
        case .lockToVideo:
            return "Frame rate locks to the camera's video-out rate, snapping to 23.98 / 24 / 25 / 29.97 / 30."
        }
    }

    private var syncHelpView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Phantom Sync & Genlock").font(.headline)
                Group {
                    Text("**What this does** — it chooses what drives the camera's frame clock. By default that's the camera's own crystal (Internal). The other modes lock the timing to an outside source so the Phantom stays in step with other cameras or a house reference.")
                    Text("**The big gotcha: the VEO has no genlock port.** A broadcast camera takes a continuous video reference (tri-level / black burst) from a sync generator (Blackmagic, AJA GEN10) on a dedicated GENLOCK BNC. The VEO does NOT have that. Its only sync line is **F-Sync**, on the capture cable — and F-Sync is a *frame pulse* (one short pulse per frame), not a video-reference waveform. So you can't feed a sync generator's tri-level output straight into the VEO and expect a lock — they're different signals.")
                }
                .font(.caption)
                Divider()
                Text("The four sync sources").font(.subheadline.bold())
                Group {
                    helpRow("Internal", "The camera's crystal. Normal shooting.")
                    helpRow("External (F-Sync)", "A frame pulse on the F-Sync line sets the rate. THE way to sync multiple Phantoms: make one the master (F-Sync out), the rest slaves (F-Sync in). Camera-to-camera, frame-accurate.")
                    helpRow("IRIG timecode", "An IRIG-B timecode signal drives the rate (multiples of 100 fps). Use this to lock to a house timecode generator.")
                    helpRow("Lock to Video", "Rate follows the camera's video-out rate (23.98/24/25/29.97/30). The closest thing to classic genlock on a VEO.")
                }
                Divider()
                Text("Syncing to a sync generator (BMD / AJA)").font(.subheadline.bold())
                Text("The sync generator outputs tri-level, black burst, and word clock — none of which is a frame pulse, so none drives F-Sync directly. To bring a Phantom into a house-synced rig, either: feed the production an **IRIG-B timecode** and use IRIG mode; or use a device that converts the house reference into a per-frame pulse and feed that to F-Sync as External. For just ganging Phantoms together, skip the generator entirely and use F-Sync master/slave.")
                    .font(.caption)
                Text("Setup tips: F-Sync rides the 12-pin capture cable (mini-BOB breakout), not a BNC on the body. The pulse is a short negative pulse, active on the falling edge. Confirm the LOCKED light before you roll.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 380)
        }
        .frame(maxHeight: 460)
    }

    private func helpRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.bold())
            Text(body).font(.caption2).foregroundStyle(.secondary)
        }
    }
    @State private var showDownloadAdvanced = false
    @State private var showPackingHelp = false
    @State private var showMetadata = false
    @AppStorage("showCineInfo") private var showCineInfo = true
    @AppStorage("showSaveDownload") private var showSaveDownload = true
    @State private var confirmCapture = false
    @State private var showBrefReminderPopover = false
    @State private var confirmClear = false
    @State private var confirmClearAll = false
    @State private var confirmLowSpace = false
    @State private var gotoFrameValue = 0
    // Persisted panel sizes — your layout is remembered across launches.
    @AppStorage("railWidth") private var railWidth: Double = 380
    @AppStorage("partitionHeight") private var partitionHeight: Double = 72
    @State private var newPresetName = ""
    @State private var showSavePreset = false
    // Punch-in focus zoom state.
    @State private var punchZoom: CGFloat = 1
    @State private var punchZoomBase: CGFloat = 1
    @State private var punchOffset: CGSize = .zero
    @State private var punchOffsetBase: CGSize = .zero

    private var viewer: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Divider()
            MonitorBar(model: model,
                       monitor: model.monitor,
                       flicker: model.flicker,
                       showGrid: $model.showGrid,
                       gridDivisions: $model.gridDivisions,
                       gridCrosshair: $model.gridCrosshair,
                       gridColorName: $model.gridColorName,
                       gridOpacity: $model.gridOpacity,
                       guidesVisible: $model.guidesVisible,
                       openFrameGuides: { openWindow(id: "frame-guides") },
                       openVideoOutput: { openWindow(id: "video-output") },
                       openClips: { openWindow(id: "clips") },
                       chooseLUT: { model.chooseLUT() },
                       onPeakingChange: { on in
                           // One peaking switch drives both the SDI pipeline
                           // and the Ethernet viewer.
                           model.focusPeaking = on
                           model.rerenderLastFrame()
                       },
                       onFlickerChange: { on in
                           model.monitor.sampleFlicker = on
                           // Same switch lights up the spatial flicker overlay.
                           model.monitor.tools.flickerMap = on
                           if on { model.monitor.resetFlickerGrid() }
                           else { model.flicker.reset(); model.clearFlickerSample() }
                       })
            Divider()
            ZStack {
                theme.viewerBackdrop(0.0)
                if model.viewerSource == .sdi && model.sdi.isRunning {
                    // PICTURE tools ON → show the Core Image processed frames.
                    // Otherwise (nothing on, OR only a scope) → show the hardware
                    // AVCaptureVideoPreviewLayer, which composites smoothly at full
                    // frame rate (the processed path can't hold 30fps and made the
                    // feed jittery). A scope alone no longer drags the picture onto
                    // the slow path — it reads the raw buffer and the live view
                    // stays smooth. The viewer frame is pinned + clipped below, so
                    // this swap no longer bounces.
                    if model.monitor.needsProcessedPicture, let processed = model.monitor.processedImage {
                        Image(decorative: processed, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .scaleEffect(punchZoom).offset(punchOffset)
                    } else {
                        SDIPreviewView(session: model.sdi.session)
                            .scaleEffect(punchZoom).offset(punchOffset)
                    }
                } else if let img = model.viewerImage {
                    Image(decorative: img, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(punchZoom).offset(punchOffset)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(model.connected ? "Waiting for image…" : "Not connected")
                            .foregroundStyle(.secondary)
                    }
                }
                // Onion-skin overlay (a saved reference frame at reduced opacity).
                if model.overlayEnabled, let ov = model.overlayImage {
                    Image(decorative: ov, scale: 1.0)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(model.effectiveOverlayOpacity)
                        .allowsHitTesting(false)
                }
                // Viewer overlay: source + fps + SDI fallback warning
                VStack {
                    HStack {
                        if model.mode == .play && model.playbackIsMag && !(model.viewerSource == .sdi && model.sdi.isLive) {
                            Label("Mag take \(model.playbackSourceLabel) plays on the SDI monitor", systemImage: "tv")
                                .font(.caption)
                                .padding(6)
                                .background(.purple.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if model.viewerSource == .sdi && !model.sdi.isLive {
                            Label("SDI not live: \(model.sdi.statusMessage) — showing Ethernet feed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .padding(6)
                                .background(.orange.opacity(0.85))
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        // A leftover speed-ramp profile caps the shutter angle at low
                        // frame rates — make it visible with a one-tap Clear.
                        if model.rampActiveOnCamera {
                            HStack(spacing: 6) {
                                Label("Speed ramp active — shutter capped", systemImage: "bolt.fill")
                                    .font(.caption)
                                Button("Clear") { model.clearRampProfile() }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.black.opacity(0.22))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .padding(6)
                            .background(.yellow.opacity(0.92))
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                        if model.connected && (model.viewerSource == .ethernet || !model.sdi.isRunning) {
                            Text(String(format: "ETH %.0f fps", model.ethernetFPS))
                                .font(.caption.monospaced())
                                .padding(4)
                                .background(.black.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Spacer()
                }
                .padding(8)
                if model.monitor.tools.falseColor && model.monitor.tools.showLegend {
                    // SmallHD-style: full-width band chart along the top,
                    // dark on the left → clipped on the right.
                    VStack(spacing: 0) {
                        HStack(spacing: 1) {
                            ForEach(Array(SDIProcessor.falseColorLegend(model.monitor.tools.falseColorMode).reversed()), id: \.0) { item in
                                VStack(spacing: 1) {
                                    Rectangle().fill(item.2).frame(height: 14)
                                    Text(item.0)
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Text(item.1)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(.black.opacity(0.78))
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if model.monitor.showHistogram || model.monitor.showWaveform || model.monitor.showVectorscope {
                    let s = model.monitor.scopeScale
                    let light = model.monitor.scopeLightBG
                    HStack(alignment: .bottom, spacing: 8) {
                        if model.monitor.showHistogram, !model.monitor.histogram.isEmpty {
                            scopeBox("Histogram") { histogramView }
                                .frame(width: 300 * s, height: 150 * s)
                        }
                        if model.monitor.showWaveform, let wf = model.monitor.waveformImage {
                            scopeBox("Waveform") { waveformView(wf, light: light) }
                                .frame(width: 380 * s, height: 150 * s)
                        }
                        if model.monitor.showVectorscope, let vs = model.monitor.vectorscopeImage {
                            scopeBox("Vectorscope") {
                                ZStack {
                                    Image(decorative: vs, scale: 1).resizable()
                                    Circle().stroke(.white.opacity(0.22), lineWidth: 1)
                                    Path { p in
                                        p.move(to: CGPoint(x: 75, y: 0)); p.addLine(to: CGPoint(x: 75, y: 150))
                                        p.move(to: CGPoint(x: 0, y: 75)); p.addLine(to: CGPoint(x: 150, y: 75))
                                    }.stroke(.white.opacity(0.12), lineWidth: 0.5)
                                }
                                .aspectRatio(1, contentMode: .fit)
                            }
                            .frame(width: 150 * s, height: 150 * s)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: scopeAlignment)
                }
                if model.flicker.enabled {
                    VStack {
                        HStack {
                            Spacer()
                            flickerMeter
                                .padding(8)
                        }
                        Spacer()
                    }
                }
                MonitorOverlay(model: model)
                // Click-to-white-balance: click a neutral area, the camera's
                // wbal measures the raw sensor there. Punch zoom must be off
                // so the view→sensor mapping is honest.
                if model.wbPickMode {
                    wbPickOverlay
                }
            }
            // Pin the viewer to fill its space and clip, so a changing source
            // resolution (capture-card renegotiation) or per-frame size wobble
            // can never push the layout around and make the image bounce.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Clicking the picture drops keyboard focus out of any text field, so
            // the monitoring hotkeys work without the IP/name fields eating keys.
            .contentShape(Rectangle())
            .onTapGesture { clearTextFocus() }
            // Punch-in focus zoom: pinch to magnify, drag to pan.
            .simultaneousGesture(MagnificationGesture()
                .onChanged { s in punchZoom = min(8, max(1, punchZoomBase * s)) }
                .onEnded { _ in punchZoomBase = punchZoom; if punchZoom <= 1.02 { resetPunch() } })
            .simultaneousGesture(DragGesture()
                .onChanged { v in
                    guard punchZoom > 1 else { return }
                    punchOffset = clampPunch(CGSize(width: punchOffsetBase.width + v.translation.width,
                                                    height: punchOffsetBase.height + v.translation.height))
                }
                .onEnded { _ in punchOffsetBase = punchOffset })
            .overlay(alignment: .topTrailing) {
                if punchZoom > 1 {
                    Text(String(format: "%.1f×", punchZoom))
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            // Always-on playback deck (same on Camera and Play) — so you can
            // scrub/play any clip from either tab and the viewer never rescales.
            playbackDeck
        }
    }

    /// Full-viewer overlay while WB-pick is armed: crosshair cursorish banner,
    /// click → relative image coords → camera `wbal`. The clicked point is
    /// mapped through the letterboxing: the video frame (16:9 SDI, or the
    /// sensor's own aspect on Ethernet) is aspect-fit inside the view.
    private var wbPickOverlay: some View {
        GeometryReader { geo in
            let videoAspect: CGFloat = (model.viewerSource == .sdi && model.sdi.isRunning)
                ? 16.0 / 9.0
                : CGFloat(max(model.resWidth, 1)) / CGFloat(max(model.resHeight, 1))
            let fitW = min(geo.size.width, geo.size.height * videoAspect)
            let fitH = fitW / videoAspect
            let content = CGRect(x: (geo.size.width - fitW) / 2,
                                 y: (geo.size.height - fitH) / 2,
                                 width: fitW, height: fitH)
            ZStack {
                Color.black.opacity(0.15)
                VStack {
                    HStack(spacing: 10) {
                        Label("Click a white or neutral-gray area to white balance",
                              systemImage: "eyedropper.halffull")
                            .font(.callout.bold())
                        Button("Cancel") { model.wbPickMode = false }
                            .font(.callout)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 40)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let rx = (location.x - content.minX) / content.width
                let ry = (location.y - content.minY) / content.height
                guard rx >= 0, rx <= 1, ry >= 0, ry <= 1 else { return }
                model.whiteBalance(atRelativeX: Double(rx), y: Double(ry))
            }
            // Punch zoom would break the view→sensor mapping — reset it.
            .onAppear { resetPunch() }
        }
    }

    /// PVP-style deck: one timeline with gold in/out handles and a white
    /// playhead, plus a transport row with frame-step and loop.
    /// PCC-style strip above the viewer: presets, auto-save, SDI look,
    /// monitor assists, ramp, shortcuts.
    private var viewerToolbar: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(model.presets) { p in
                    Button("\(p.name)  (\(p.width)×\(p.height) @\(p.rate))") { model.apply(preset: p) }
                }
                if !model.presets.isEmpty { Divider() }
                Button("Save Current as Preset…") { showSavePreset = true }
                if !model.presets.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(model.presets) { p in
                            Button(p.name, role: .destructive) {
                                model.presets.removeAll { $0.id == p.id }
                            }
                        }
                    }
                }
            } label: { Label("Presets", systemImage: "square.stack.3d.up") }
                .frame(width: 110)

            Toggle(isOn: $model.autoSaveTriggered) {
                Label("Auto-save → Comp", systemImage: "arrow.down.doc")
            }
            .toggleStyle(.button)
            .help("Every triggered shot downloads to the project folder on this computer and the partition re-arms")

            Toggle(isOn: $model.autoSaveToMag) {
                Label(model.magSavingCine.map { "Mag ← C\($0)…" } ?? "Auto-save → Mag",
                      systemImage: "memorychip")
            }
            .toggleStyle(.button)
            .disabled(!model.connected || !model.magPresent)
            .help(model.magPresent
                  ? "Every triggered shot saves onto the CineMag (camera-side, no download). Right-click to choose whether the RAM copy is cleared (re-arm) or kept."
                  : "No CineMag on this camera — insert a mag to enable saving to it")
            .contextMenu {
                Button {
                    model.magSaveKeepsRAM = false
                } label: {
                    Label("After saving: clear RAM (re-arm)\(model.magSaveKeepsRAM ? "" : "  ✓")",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    model.magSaveKeepsRAM = true
                } label: {
                    Label("After saving: keep shot in RAM too\(model.magSaveKeepsRAM ? "  ✓" : "")",
                          systemImage: "memorychip.fill")
                }
            }

            Toggle(isOn: $model.autoSaveMagRestart) {
                Label("Continuous → Mag", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .toggleStyle(.button)
            .disabled(!model.connected || !model.magPresent)
            .help(model.magPresent
                  ? "Continuous record — the CAMERA saves each triggered partition to the CineMag and immediately re-arms it. With several partitions it rolls, triggers, saves and cycles back on its own, hands-free (auto.flashsave + auto.acqrestart). No download, no app in the loop; the setting persists on the camera."
                  : "No CineMag on this camera — insert a mag to enable continuous record")

            Button {
                model.toggleOSD()
            } label: {
                Label("OSD", systemImage: model.cameraOSD ? "captions.bubble.fill" : "captions.bubble")
            }
            .help("Camera on-screen overlay on/off (SDI)")

            Button { showVideoOut = true } label: { Label("Cam Guides", systemImage: "rectangle.inset.filled.badge.record") }
                .help("Camera-side video output: state borders, punch-in, sharpening (this is the Phantom's own output config, not the external monitor window)")
                .popover(isPresented: $showVideoOut) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera Video Output").font(.headline)
                        Text("The colored border around the image is the camera marking its state (red = recording pre-roll). All of this is camera-side, sent over Ethernet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach([("Recording (red box)", "wtr_color"),
                                 ("Triggered", "trg_color"),
                                 ("Stored", "cst_color"),
                                 ("Preview", "pre_color"),
                                 ("Acquiring", "acq_color")], id: \.1) { label, varName in
                            HStack {
                                Text(label).frame(width: 140, alignment: .leading).font(.callout)
                                Menu("Set…") {
                                    ForEach(CameraModel.borderColorChoices, id: \.0) { name, hex in
                                        Button(name) { model.setVideoVar(varName, hex) }
                                    }
                                }
                                .frame(width: 80)
                            }
                        }
                        Button("Reset Border Defaults") { model.resetBorderColors() }
                        Divider()
                        Toggle("1:1 Punch-in (focus check)", isOn: Binding(
                            get: { model.punchIn },
                            set: { _ in model.togglePunchIn() }))
                        HStack {
                            Text("Sharpening")
                            Menu("Set…") {
                                Button("Off") { model.setVideoVar("detail", "0") }
                                Button("Low") { model.setVideoVar("detail", "2") }
                                Button("Medium") { model.setVideoVar("detail", "4") }
                                Button("High") { model.setVideoVar("detail", "6") }
                            }
                            .frame(width: 90)
                        }
                    }
                    .padding(16)
                    .frame(width: 320)
                }

            Menu {
                Button("Linear (off)") { model.setTone(0) }
                // Medium/Strong/Highs are baked-in preset curves selected by the
                // numeric tone form, which VEO-class (supportsWBTemp) bodies reject
                // — on those bodies `tone` is the clean-EI curve register and the
                // preset curve strings aren't available, so hide them there.
                if !model.supportsWBTemp {
                    Button("Medium") { model.setTone(1) }
                    Button("Strong") { model.setTone(2) }
                    Button("Highs") { model.setTone(3) }
                }
                if model.supportsLog {
                    Divider()
                    Button("Log OFF") { model.setLogMode(0) }
                    Button("Log 1") { model.setLogMode(1) }
                    Button("Log 2") { model.setLogMode(2) }
                }
                if model.supportsWBTemp {
                    Divider()
                    Menu("White Balance (K)") {
                        ForEach([3200, 4300, 5500, 6500, 7500], id: \.self) { k in
                            Button("\(k)K") { model.setWBTemp(k) }
                        }
                    }
                }
            } label: { Label("Look", systemImage: "camera.filters") }
                .frame(width: 90)
                .help("Camera tone curve / log / WB for the SDI output")

            // Spot white balance — click a neutral patch on the live feed. It
            // balances BOTH the Ethernet display and the camera (SDI/recordings)
            // off that patch. Gated by the black-reference reminder.
            Button {
                if model.wbPickMode { model.wbPickMode = false }
                else { model.requestWhiteBalance { model.wbPickMode = true } }
            } label: {
                Label("WB", systemImage: "eyedropper.halffull")
            }
            .foregroundStyle(model.wbPickMode ? .orange : .primary)
            .help("Click, then click a white or neutral-GREY area — balances the Ethernet feed and the camera (SDI/recordings) from that spot. Do a Black Reference first for accurate colour.")

            Divider().frame(height: 16)

            Button { showRampSheet = true } label: { Label("Speed Ramp", systemImage: "speedometer") }
                .help("In-camera speed ramp (experimental)")

            Button { togglePunch() } label: {
                Label(punchZoom > 1 ? String(format: "Punch %.1f×", punchZoom) : "Punch-In",
                      systemImage: "plus.magnifyingglass")
            }
            .help("Magnify for critical focus — click for 2×, pinch to zoom, drag to pan, M to toggle")

            // Onion-skin overlay — left-click shows/hides it, right-click opens the
            // settings (grab/load/opacity/blink). With nothing loaded yet, a
            // left-click opens the panel so you can grab or load a reference.
            Button {
                if model.overlayImage == nil { showOverlayPanel = true }
                else { model.overlayEnabled.toggle() }
            } label: {
                Label(model.overlayEnabled ? "Overlay \(Int(model.overlayOpacity * 100))%" : "Overlay",
                      systemImage: "square.stack.3d.up")
            }
            .help("Onion-skin overlay — left-click show/hide, right-click for settings  [B]")
            .overlay { RightClickCatcher { showOverlayPanel = true } }
            .popover(isPresented: $showOverlayPanel, arrowEdge: .bottom) {
                OverlayPanel(onPopOut: { showOverlayPanel = false; openWindow(id: "overlay-panel") })
                    .environmentObject(model)
            }

            Spacer()

            Button { showShortcuts.toggle() } label: { Label("App Connect / Shortcuts", systemImage: "keyboard") }
                .help("Phone/iPad remote QR code, keyboard shortcuts, and Stream Deck endpoints")
                .popover(isPresented: $showShortcuts) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Keyboard Shortcuts").font(.headline)
                            Spacer()
                            Button {
                                PhantomControlApp.openReleaseNotes()
                            } label: {
                                Text("Phantom Control \(AppInfo.versionString)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("App version — click for release notes. Quote this when reporting a bug.")
                        }
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TRANSPORT").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text("""
                                Space   Trigger
                                C       Capture
                                L       Go Live
                                P       Play / Pause
                                ⇧P      Play from hero
                                ← →     Step frame
                                I / O   Mark In / Out
                                ⌘1–9    Select Cine 1–9
                                """).font(.callout.monospaced())
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MONITORING").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text("""
                                F    False Color    ⇧F cycle
                                E    Peaking
                                Z    Zebra
                                H    Histogram
                                W    Waveform
                                V    Vectorscope
                                G    Grid
                                A    Guides
                                N    Invert
                                X / Y  Flip H / V
                                B    Overlay      M  Punch-in zoom
                                [ ]  Scope size   \\  Scope BG
                                """).font(.callout.monospaced())
                            }
                        }
                        Divider()
                        Text("Phone remote — phone on the SAME Wi-Fi, then scan:").font(.caption)
                        HStack(alignment: .top, spacing: 12) {
                            if let qr = makeQRImage(model.remoteURLString) {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 130, height: 130)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Point the phone camera at the code, or type the address:")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(model.remoteURLString)
                                    .font(.callout.monospaced().bold())
                                    .textSelection(.enabled)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(model.remoteURLString, forType: .string)
                                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    Button { remoteURLNonce += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                        .help("Recompute after switching Wi-Fi networks")
                                }
                                .font(.caption)
                                .id(remoteURLNonce)
                                let others = model.remoteAltURLs
                                if !others.isEmpty {
                                    Text("If that doesn't load, try: \(others.joined(separator: "  ·  "))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Text("Make it a real home-screen app: open the address in SAFARI (not Chrome) → Share → Add to Home Screen. It launches full-screen with its own icon, and this address stays valid on any network.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider()
                        FieldHotspotSection(hotspot: hotspot, onNetworkUp: { remoteURLNonce += 1 })
                            .frame(maxWidth: 420, alignment: .leading)
                        Divider()
                        Text("Stream Deck: point Website actions at http://127.0.0.1:8989/trigger /capture /live /play /pause /proxy /download /preset/<name>")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(maxWidth: 420, alignment: .leading)
                        Text("Full guide: Help ▸ Phantom Control Help").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .onAppear { hotspot.refreshActive() }
                    // Explicit size — without it the popover balloons to the
                    // window height and pins the content off-screen.
                    .frame(width: 580)
                    .fixedSize(horizontal: false, vertical: true)
                }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.chrome(0.16))
        .sheet(isPresented: $showRampSheet) { rampSheet }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                if !newPresetName.isEmpty { model.saveCurrentAsPreset(named: newPresetName) }
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Saves \(model.resWidth)×\(model.resHeight) @\(model.frameRate)fps, \(Int(model.shutterAngle))° in the app.")
        }
    }

    private var rampSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In-Camera Speed Ramp").font(.headline)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(model.rampKnownBroken ? .red : .orange)
                Text(model.rampKnownBroken
                     ? "Confirmed NOT working on this Phantom Flex 2K — it records the whole take at the fastest rate. Built for VEO / Flex4K firmware."
                     : "Experimental. In-camera ramps are unverified on this camera — shoot a test before relying on them. (Confirmed not to work on the Flex 2K.)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background((model.rampKnownBroken ? Color.red : Color.orange).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))

            rampGraph
                .frame(height: 150)
                .padding(8)
                .background(theme.chrome(0.1), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text("Presets").font(.caption).foregroundStyle(.secondary)
                ForEach(CameraModel.RampPreset.allCases) { p in
                    Button(p.rawValue) { model.loadRampPreset(p) }
                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
                }
            }

            VStack(spacing: 6) {
                ForEach($model.rampSegments) { $seg in
                    let idx = model.rampSegments.firstIndex(where: { $0.id == seg.id }) ?? 0
                    let start = model.rampSegmentStarts.indices.contains(idx) ? model.rampSegmentStarts[idx] : 0
                    HStack(spacing: 6) {
                        Text(idx == 0 ? "Start" : "@ \(start)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        TextField("fps", value: $seg.rate, format: .number.grouping(.never)).frame(width: 54)
                        Text("fps for").font(.caption2).foregroundStyle(.secondary)
                        TextField("fr", value: $seg.durationFrames, format: .number.grouping(.never)).frame(width: 54)
                        Text("fr =").font(.caption2).foregroundStyle(.secondary)
                        TextField("s", value: Binding<Double>(
                            get: { seg.durationFrames <= 0 ? 0 : Double(seg.durationFrames) / Double(max(1, seg.rate)) },
                            set: { v in $seg.durationFrames.wrappedValue = max(0, Int((v * Double(max(1, seg.rate))).rounded())) }
                        ), format: .number.precision(.fractionLength(0...2))).frame(width: 48)
                        Text("s").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.rampSegments.removeAll { $0.id == seg.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button {
                    model.rampSegments.append(.init(rate: min(model.frameRate, model.rampMaxFPS), durationFrames: 250))
                } label: { Label("Add segment", systemImage: "plus.circle") }
                    .font(.caption).disabled(model.rampSegments.count >= 4)
                Spacer()
                if !model.rampSegments.isEmpty {
                    Text("Total \(model.rampTotalFrames) fr · \(String(format: "%.2f", model.rampTotalSeconds)) s  ·  max \(model.rampMaxFPS) fps")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text("max \(model.rampMaxFPS) fps · up to 4 segments")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text("Each row is a rate held for a duration — type frames or seconds and the other fills in. The first row starts at the trigger (frame 0); each next row picks up where the previous ended. Exposure is auto-set to hold your shutter angle.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Clear Ramp") { model.rampSegments = []; model.clearRampProfile(); showRampSheet = false }
                Spacer()
                Button("Cancel") { showRampSheet = false }
                Button("Apply Ramp") { model.applyRampProfile(); showRampSheet = false }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.rampSegments.filter { $0.rate > 0 && $0.durationFrames > 0 }.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// fps-over-frames plot of the current ramp segments (stepped line + dots).
    private var rampGraph: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pad: CGFloat = 6
            let segs = model.rampSegments.filter { $0.rate > 0 && $0.durationFrames > 0 }
            let starts: [Int] = { var a = 0; return segs.map { s in defer { a += s.durationFrames }; return a } }()
            let totalF = CGFloat(max(model.rampTotalFrames, 100))
            let maxR = CGFloat(max(model.rampMaxFPS, segs.map(\.rate).max() ?? 1))
            let px = { (f: Int) -> CGFloat in pad + CGFloat(f) / totalF * (w - 2*pad) }
            let py = { (r: Int) -> CGFloat in h - pad - CGFloat(r) / maxR * (h - 2*pad) }
            ZStack {
                if !segs.isEmpty {
                    Path { p in
                        p.move(to: CGPoint(x: px(0), y: py(segs[0].rate)))
                        for i in 1..<segs.count {
                            p.addLine(to: CGPoint(x: px(starts[i]), y: py(segs[i-1].rate)))
                            p.addLine(to: CGPoint(x: px(starts[i]), y: py(segs[i].rate)))
                        }
                        p.addLine(to: CGPoint(x: px(model.rampTotalFrames), y: py(segs[segs.count - 1].rate)))
                    }.stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    ForEach(Array(segs.enumerated()), id: \.element.id) { i, s in
                        Circle().fill(Color.purple).frame(width: 8, height: 8)
                            .position(x: px(starts[i]), y: py(s.rate))
                    }
                } else {
                    Text("Pick a preset or add a segment")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// Frames → time string at the current record rate (e.g. "1.45s" or "1:23").
    private func playTime(_ frames: Double) -> String {
        let r = Double(max(model.frameRate, 1))
        let t = frames / r
        if t < 60 { return String(format: "%.2fs", t) }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var playbackDeck: some View {
        let (lo, hi) = model.playbackRange
        let span = max(hi - lo, 1)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                // Zero-width layout passes (view teardown when switching to
                // Live) make this division non-finite — a NaN frame width is
                // a report-less SwiftUI crash. Clamp everything.
                let x: (Double) -> CGFloat = { v in
                    guard w > 0, span > 0 else { return 0 }
                    let f = CGFloat((v - lo) / span) * w
                    return f.isFinite ? min(max(f, 0), w) : 0
                }
                ZStack(alignment: .leading) {
                    // track
                    RoundedRectangle(cornerRadius: 4).fill(theme.chrome(0.25))
                        .frame(height: 12).offset(y: 7)
                    // selected in..out region
                    Rectangle().fill(Color.green.opacity(0.35))
                        .frame(width: max(x(model.outPoint) - x(model.inPoint), 0), height: 12)
                        .offset(x: x(model.inPoint), y: 7)
                    // in handle (gold) — wide invisible grab area
                    Capsule().fill(.yellow)
                        .frame(width: 6, height: 26)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                        .offset(x: x(model.inPoint) - 9)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            guard w > 0 else { return }
                            let val = lo + Double(min(max(v.location.x / w, 0), 1)) * span
                            if val.isFinite { model.inPoint = min(val, model.outPoint) }
                        })
                    // out handle (gold)
                    Capsule().fill(.yellow)
                        .frame(width: 6, height: 26)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                        .offset(x: x(model.outPoint) - 9)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            guard w > 0 else { return }
                            let val = lo + Double(min(max(v.location.x / w, 0), 1)) * span
                            if val.isFinite { model.outPoint = max(val, model.inPoint) }
                        })
                    // hero marker (auto-play frame) — a pure software cue; it
                    // never moves the camera's playhead or in/out.
                    if model.autoPlayStartFrame > Int(lo), model.autoPlayStartFrame < Int(hi) {
                        ZStack(alignment: .top) {
                            Rectangle().fill(.orange)
                                .frame(width: 2, height: 26)
                            Image(systemName: "triangle.fill")
                                .font(.system(size: 7)).foregroundStyle(.orange)
                                .offset(y: -7)
                        }
                        .offset(x: x(Double(model.autoPlayStartFrame)) - 1, y: -2)
                    }
                    // playhead (white)
                    Rectangle().fill(.white)
                        .frame(width: 2, height: 26)
                        .offset(x: x(model.playFrame) - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    guard w > 0 else { return }
                    model.isScrubbing = true
                    let val = lo + Double(min(max(v.location.x / w, 0), 1)) * span
                    guard val.isFinite else { return }
                    model.playFrame = val
                    model.liveScrub(to: Int(val))
                }.onEnded { _ in
                    model.scrub(to: Int(model.playFrame))
                    model.isScrubbing = false
                })
                // Scrub the playhead, then right-click to mark — no trips to the
                // separate buttons. All three mark at the current playhead.
                .contextMenu {
                    let f = Int(model.playFrame)
                    Button { model.markIn() } label: { Label("Mark In ⟦  (frame \(f))", systemImage: "arrow.right.to.line") }
                    Button { model.markOut() } label: { Label("Mark Out ⟧  (frame \(f))", systemImage: "arrow.left.to.line") }
                    Divider()
                    Button { model.autoPlayStartFrame = f } label: { Label("Mark Hero ◇  (frame \(f))", systemImage: "diamond.fill") }
                    if model.canSaveDeckClip {
                        Divider()
                        // Keep this clip → CineMag if one's loaded, else download.
                        Button { model.saveInOutSmart() } label: {
                            Label(model.saveDeckDestinationLabel,
                                  systemImage: model.magSize > 0 ? "externaldrive.fill.badge.plus" : "arrow.down.circle.fill")
                        }
                    }
                }
            }
            .frame(height: 28)

            // Trim + playhead readout: frame numbers AND seconds, so the gold
            // in/out marks line up with what you see, and it's clear the white
            // playhead is separate from the (unchanged) in/out save range.
            // One readout line: gold in/out marks, white playhead, and the
            // save-range length tucked beside the playhead (saves a row).
            HStack(spacing: 0) {
                Text("⟦ In \(Int(model.inPoint)) · \(playTime(model.inPoint))")
                    .foregroundStyle(.yellow)
                Spacer()
                Text("● \(Int(model.playFrame)) · \(playTime(model.playFrame))")
                    .foregroundStyle(.white)
                Text("   range \(Int(model.outPoint - model.inPoint) + 1)f · \(playTime(model.outPoint - model.inPoint + 1))")
                    .foregroundStyle(.secondary)
                // One-tap keep of the in→out range, right by the numbers: CineMag
                // if one's loaded (Flex), else download to the Mac (VEO / no mag).
                if model.canSaveDeckClip {
                    Button { model.saveInOutSmart() } label: {
                        Label(model.magSize > 0 ? "Save → Mag" : "Download",
                              systemImage: model.magSize > 0 ? "externaldrive.fill.badge.plus" : "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(model.magSize > 0 ? .purple : .green)
                    .padding(.leading, 10)
                    .help(model.saveDeckDestinationLabel + " — right-click the timeline for the same")
                    .disabled(model.magBusy != nil || model.magSavingCine != nil || model.downloadProgress != nil)
                }
                Spacer()
                Text("Out \(Int(model.outPoint)) · \(playTime(model.outPoint)) ⟧")
                    .foregroundStyle(.yellow)
            }
            .font(.caption2.monospaced())

            // Transport (centered) with the source label and the jump / record
            // / auto-play / live block overlaid at the LEFT and RIGHT edges of
            // the SAME row — uses the empty space beside the centered transport
            // so the deck stays short and the video feed stays large.
            ZStack {
            // Transport — dead center, bigger buttons. The In/Out frame fields
            // flank their buttons: they live-update as you drag the gold in/out
            // handles, and you can type an exact frame to set the trim.
            HStack(spacing: 16) {
                Spacer()
                Button("⟦ In") { model.markIn() }
                    .font(.body.bold())
                    .tint(.yellow)
                    .keyboardShortcut("i", modifiers: [])
                    .help("Mark In at playhead (\(Int(model.inPoint)))  [I]")
                TextField("in", value: Binding(
                    get: { Int(model.inPoint) },
                    set: { model.setInFrame($0) }), format: .number.grouping(.never))
                    .frame(width: 58)
                    .font(.callout.monospaced())
                    .help("In frame — type an exact frame, or drag the gold in handle and it updates here")
                Button { model.stepFrame(-10) } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(.plain).font(.title2)
                    .keyboardShortcut(.leftArrow, modifiers: [.shift])
                    .help("Back 10 frames  [⇧←]")
                Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(.plain).font(.title2)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Step back one frame  [←]")
                Button {
                    model.isPlaying ? model.stopPlayback() : model.startPlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [])
                .help("Play / Pause  [P]")
                Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(.plain).font(.title2)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Step forward one frame  [→]")
                Button { model.stepFrame(10) } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(.plain).font(.title2)
                    .keyboardShortcut(.rightArrow, modifiers: [.shift])
                    .help("Forward 10 frames  [⇧→]")
                Button { model.loopPlayback.toggle() } label: {
                    Image(systemName: "repeat")
                        .font(.title2)
                        .foregroundStyle(model.loopPlayback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Loop in→out")
                TextField("out", value: Binding(
                    get: { Int(model.outPoint) },
                    set: { model.setOutFrame($0) }), format: .number.grouping(.never))
                    .frame(width: 58)
                    .font(.callout.monospaced())
                    .help("Out frame — type an exact frame, or drag the gold out handle and it updates here")
                Button("Out ⟧") { model.markOut() }
                    .font(.body.bold())
                    .tint(.yellow)
                    .keyboardShortcut("o", modifiers: [])
                    .help("Mark Out at playhead (\(Int(model.outPoint)))  [O]")
                Divider().frame(height: 22)
                SpeedRampSlider()
                Spacer()
            }

            // Utilities — source at left; the jump / record / auto-play / live
            // controls tuck to the right in a 2-row block, LIVE directly above
            // PROXY, with Go-to on LIVE's row and Auto-play on PROXY's row.
            HStack(alignment: .center, spacing: 10) {
                Text(model.playbackSourceLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(model.playbackIsMag ? Color.purple.opacity(0.6) : Color.green.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    // Top row: Go to #  ····  LIVE
                    HStack(spacing: 12) {
                        HStack(spacing: 3) {
                            Text("Go to #").font(.caption2).foregroundStyle(.secondary)
                            TextField("frame", value: $gotoFrameValue, format: .number.grouping(.never))
                                .frame(width: 56)
                                .onSubmit { model.goToFrame(gotoFrameValue) }
                            Button("Go") { model.goToFrame(gotoFrameValue) }
                                .font(.caption)
                        }
                        .help("Jump the playhead to an absolute frame (synced with the robot — robot frame 0 = Phantom frame 0)")
                        Button {
                            model.clearInOut()
                        } label: {
                            Label("Clear In/Out", systemImage: "arrow.left.and.right.square")
                                .font(.caption)
                        }
                        .help("Reset the in/out trim marks to the full clip")
                        Button {
                            model.goLive()
                        } label: {
                            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                                .font(.callout.bold())
                                .frame(width: 78)
                        }
                        .tint(.cyan)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Back to the live camera image  [L]")
                        .keyboardShortcut("l", modifiers: [])
                    }
                    // Bottom row: Auto-play / hero  ····  PROXY
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Toggle(isOn: $model.autoPlayEnabled) {
                                Label("Auto-play", systemImage: "play.circle.fill")
                            }
                            .toggleStyle(.button)
                            .tint(.green)
                            .help("After each recording finishes, auto-play the whole clip with the SDI kept fully open (never trims the RAM range). The frame at right is just a software hero marker on the timeline.")
                            Text("hero ◇").font(.caption2).foregroundStyle(.orange)
                            TextField("frame", value: $model.autoPlayStartFrame, format: .number.grouping(.never))
                                .frame(width: 56)
                            Button { model.playFromFrame(model.autoPlayStartFrame) } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("p", modifiers: [.shift])
                            .help("Play the whole clip now from the hero frame (SDI stays fully open)  [⇧P]")
                        }
                        Button {
                            model.saveSDIProxy()
                        } label: {
                            Label(model.sdi.isProxyRecording ? "REC…" : "PROXY", systemImage: "record.circle")
                                .font(.callout.bold())
                                .frame(width: 78)
                        }
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.sdi.isRunning || model.sdi.isProxyRecording)
                        .help("Plays in→out and records the SDI to a .mov on the Desktop — works for RAM and mag takes")
                    }
                }
            }
            }   // ZStack — transport + edge controls share one row
        }
        .padding(10)
        .background(theme.chrome(0.15))
    }

    // MARK: Right rail

    private var rightRail: some View {
        VStack(spacing: 12) {
            connectionHeader
            // The tab now just swaps the SETTINGS shown (camera setup vs playback);
            // the timeline + partition strip stay put below, so playback is
            // controllable from either tab without the layout rescaling.
            Picker("", selection: $railTab) {
                Text("Camera").tag(RailTab.camera)
                Text("Save").tag(RailTab.save)
                Text("Clips").tag(RailTab.clips)
            }
            .pickerStyle(.segmented)
            .onChange(of: railTab) { _, tab in
                switch tab {
                case .camera:
                    // Real return to the live image, video out included.
                    if model.mode != .live { model.goLive() }
                case .save:
                    if model.mode != .play { model.mode = .play }
                    model.refreshSelectedCineRange()
                    if model.magTakes.isEmpty { model.refreshMag() }
                case .clips:
                    break   // offline browser — leave the camera mode as-is
                }
            }
            // Keep the tab in sync when the camera mode changes elsewhere
            // (e.g. selecting a stored cine), unless we're on the Clips tab.
            .onChange(of: model.mode) { _, m in
                if railTab != .clips { railTab = (m == .play) ? .save : .camera }
            }

            HStack {
                Text("Viewer").font(.callout).foregroundStyle(.secondary)
                // Custom binding so the "user picked this by hand" flag is set
                // ONLY from this control. An .onChange would also fire for the
                // launch auto-switch to SDI, which would disable the
                // late-enumeration retry that auto-switch exists to support.
                Picker("", selection: Binding(
                    get: { model.viewerSource },
                    set: { newValue in
                        model.viewerSourceUserSet = true
                        model.viewerSource = newValue
                    })) {
                    ForEach(CameraModel.ViewerSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: model.viewerSource) { _, src in
                    if src == .sdi {
                        model.sdi.requestAccessAndStart()
                    } else {
                        // Switching away used to leave the capture card claimed
                        // for the life of the process, locking Media Express and
                        // Desktop Video out until Phantom Control was quit.
                        model.sdi.stop()
                    }
                }
                // Ethernet feed: quality-vs-fps trade + live rate readout.
                if model.viewerSource == .ethernet || !model.sdi.isLive {
                    Text("Feed").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $model.feedMode) {
                        ForEach(CameraModel.FeedMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Ethernet preview trade-off. More FPS = 8-bit, faster. Better Image = 12-bit, ~half the frame rate but smoother, banding-free gradients (like PCC). Recordings are always full quality.")
                    if model.connected, model.ethernetFPS > 0.5 {
                        Text(String(format: "%.0f fps", model.ethernetFPS))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Toggle("Match SDI", isOn: $model.matchSDI)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Develop the Ethernet feed with the camera's own white balance and gamma (video.adj) so it matches the SDI feed. Off = the app's auto colour.")
                }
                Spacer()
            }

            // Ethernet feed caveat — a gentle, always-visible note so testers know
            // the live network preview is a raw monitor, not a colour-calibrated
            // match to SDI. Recordings/downloads are unaffected.
            if model.viewerSource == .ethernet || !model.sdi.isLive {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Ethernet is a live **raw preview** — ideal for framing and focus. Its colour is a close reference, not a calibrated match to the SDI feed, and you may see faint sensor banding. Your recordings and downloads are full quality and unaffected.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 2)
            }

            if model.viewerSource == .sdi {
                sdiPanel
            }

            ScrollView {
                switch railTab {
                case .camera: liveSettings
                case .save:   playInfo
                case .clips:  ProjectClipsPanel(standalone: true)
                }
            }

            Spacer(minLength: 0)

            captureButtons
        }
        .padding(12)
        .background(theme.chrome(0.16))
    }

    private var sdiPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(model.sdi.devices, id: \.uniqueID) { dev in
                        Button(dev.localizedName) { model.sdi.select(deviceID: dev.uniqueID) }
                    }
                    Divider()
                    Button("Rescan Devices") {
                        model.sdi.refreshDevices()
                        model.sdi.requestAccessAndStart()
                    }
                } label: {
                    Label(
                        model.sdi.devices.first(where: { $0.uniqueID == model.sdi.selectedDeviceID })?.localizedName
                            ?? "Choose capture device",
                        systemImage: "cable.connector"
                    )
                    .lineLimit(1)
                }
                Button {
                    model.sdi.forceReconnect()
                } label: { Image(systemName: "arrow.clockwise.circle") }
                    .help("Reconnect the SDI capture card (use when the feed drops or goes hit-and-miss)")
                Button {
                    model.sdi.stop()
                } label: { Image(systemName: "eject.circle") }
                    .disabled(!model.sdi.isRunning)
                    .help("Release the capture device so another app (Blackmagic Media Express, Desktop Video Setup) can use it, without quitting Phantom Control")
            }
            HStack(spacing: 6) {
                // Green ONLY when frames are genuinely arriving. A session can
                // be "running" while delivering nothing — that state is amber,
                // because there is no picture.
                Circle()
                    .fill(model.sdi.isLive ? .green : (model.sdi.isRunning ? .yellow : .orange))
                    .frame(width: 7, height: 7)
                Text(model.sdi.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.sdi.isRunning && !model.sdi.isLive {
                Text("The device is connected but sending no picture. Phantom Control is trying each capture format it offers. If this doesn't clear, check the camera's SDI output format — 50 Hz feeds (1080p50 / 1080i50) are the usual cause.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.sdi.authorized && AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                Button("Open Camera Privacy Settings") { model.sdi.openPrivacySettings() }
                    .font(.caption)
            }
        }
        .padding(8)
        .background(theme.chrome(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var connectionHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Circle()
                    .fill(model.connected ? .green : .red)
                    .frame(width: 9, height: 9)
                Text(model.connected ? model.cameraTitle : "No camera")
                    .font(.headline)
                Spacer()
            }
            HStack {
                TextField("Camera IP", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                if model.discoveredCameras.count > 1 || (model.connected && !model.discoveredCameras.isEmpty) {
                    Menu {
                        ForEach(model.discoveredCameras, id: \.host) { cam in
                            Button("\(cam.host)  (\(cam.protocolVersion))\(cam.host == model.host ? "  ✓" : "")") {
                                model.switchCamera(to: cam)
                            }
                        }
                        Divider()
                        Button("Rescan Network") { model.discoverAndConnect() }
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .frame(width: 36)
                    .help("Switch between discovered Phantom cameras")
                }
                if model.connected {
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button("Connect") { model.connect() }
                        .keyboardShortcut(.return, modifiers: [])
                    Button {
                        model.discoverAndConnect()
                    } label: { Image(systemName: "magnifyingglass") }
                        .help("Search: UDP broadcast + known camera IPs")
                }
            }
            // PCC-style network setup: offer to fix the Mac side automatically —
            // either no route to the camera's subnet, or the Mac is squatting on
            // the camera's own address (conflict).
            if !model.connected && model.needsNetworkSetup(for: model.host) {
                let conflict = model.hasAddressConflict(for: model.host)
                Button {
                    model.configureNetwork(for: model.host)
                } label: {
                    Label(conflict ? "Fix Address Conflict — Mac is using the camera's IP"
                                   : "Set Up Network for \(model.host)",
                          systemImage: conflict ? "exclamationmark.triangle.fill"
                                                : "network.badge.shield.half.filled")
                        .font(.caption)
                }
                .tint(conflict ? .orange : nil)
                .help(conflict
                      ? "Your Mac's adapter is set to \(model.host) — the camera's own address — so they conflict and the camera can't be reached. Click to give the Mac its own address instead (asks for your password once)."
                      : "Adds a network address on your wired adapter so this camera's subnet is reachable (asks for your password once)")
            }
            // Live connection status up here where people actually look — the
            // same line as the bottom status bar (searching / connecting /
            // network setup / errors), with a spinner while it's working.
            if !model.connected {
                let bad = ["failed", "No cameras", "lost", "cancelled", "conflict"]
                    .contains { model.statusLine.localizedCaseInsensitiveContains($0) }
                HStack(spacing: 6) {
                    if model.statusLine.hasSuffix("…") {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    } else if bad {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(model.statusLine)
                        .font(.caption)
                        .foregroundStyle(bad ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    private var liveSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRow("Resolution") {
                TextField("W", value: $model.resWidth, format: .number.grouping(.never))
                    .frame(width: 60)
                    .onSubmit { model.applySettings() }
                Text("×")
                TextField("H", value: $model.resHeight, format: .number.grouping(.never))
                    .frame(width: 60)
                    .onSubmit { model.applySettings() }
                Menu {
                    ForEach(model.resolutionPresets, id: \.label) { preset in
                        Button(preset.label) {
                            model.resWidth = preset.w
                            model.resHeight = preset.h
                            model.applySettings()
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            Text("Type any custom size in the boxes — the camera snaps it to its nearest legal sensor size. Or pick a preset ▾.")
                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
            settingsRow("Frame rate") {
                let maxFps = model.estimatedMaxFPS(width: model.resWidth, height: model.resHeight)
                Menu("\(model.frameRate)") {
                    let standard = [24, 25, 30, 48, 50, 60, 96, 100, 120, 150, 200, 240, 300,
                                    360, 500, 750, 1000, 1500, 2000, 3000, 5000]
                    ForEach(standard.filter { $0 <= maxFps } + [maxFps], id: \.self) { r in
                        Button(r == maxFps ? "\(r) fps  (max here)" : "\(r) fps") {
                            model.applyFrameRate(r)
                        }
                    }
                }
                .frame(width: 90)
                TextField("fps", value: $model.frameRate, format: .number.grouping(.never))
                    .frame(width: 60)
                    .onSubmit { model.applyFrameRate(model.frameRate) }
                Text("fps · ~\(maxFps) max").foregroundStyle(.secondary).font(.caption2)
            }
            settingsRow("Shutter") {
                Menu(String(format: "%.1f°", model.shutterAngle)) {
                    ForEach([11.25, 22.5, 45.0, 90.0, 120.0, 144.0, 172.8, 180.0, 270.0, 359.0], id: \.self) { angle in
                        Button(String(format: "%.2f°", angle)) {
                            model.shutterAngle = angle
                            model.applySettings()
                        }
                    }
                }
                .frame(width: 90)
                TextField("°", value: $model.shutterAngle, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 52)
                    .onSubmit { model.applySettings() }
                Text("°").foregroundStyle(.secondary)
            }
            if model.supportsWBTemp {
                // VEO-class (VEO, Flex 4K): EI is TWO controls. A calibrated tone curve
                // sets the CLEAN native EI (250…1250) with gain pinned at 1.0; extra
                // digital GAIN pushes above the ceiling (adds noise). Log mode locks both.
                settingsRow("ISO / EI") {
                    // 1) CLEAN EI — loads the calibrated "EI#### <points>" curve, gain 1.0.
                    Menu(model.logMode != 0 ? "locked (Log \(model.logMode))"
                         : (model.cleanEI > 0 ? "EI \(model.cleanEI)" : "Set EI…")) {
                        ForEach(CameraModel.cleanEILadder, id: \.self) { ei in
                            Button(model.haveToneCurve(ei) ? "EI \(ei)" : "EI \(ei)  (uncalibrated)") {
                                model.setCleanEI(ei)
                            }
                        }
                    }
                    .frame(width: 100)
                    .disabled(model.logMode != 0)

                    // 2) GAIN push — disabled until EI is pinned at the ceiling (1250).
                    Menu(model.eiGain > 1.001 ? String(format: "+%.2f×", model.eiGain) : "gain 1.0×") {
                        Button("1.0× (none)") { model.setGain(1.0) }
                        ForEach(model.gainEIChoices, id: \.self) { ei in
                            Button("EI \(ei)  (\(String(format: "%.2f", model.gainForEI(ei)))×)") {
                                model.setGain(model.gainForEI(ei))
                            }
                        }
                    }
                    .frame(width: 96)
                    .disabled(model.logMode != 0 || !model.gainUnlocked)

                    // Effective EI (= clean × gain) + base.
                    if model.effectiveEI > 0 {
                        Text(model.eiGain > 1.001
                             ? "= EI \(model.effectiveEI)  (\(model.cleanEI) +\(String(format: "%.2f", model.eiGain))×)"
                             : "= EI \(model.effectiveEI)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("base \(model.baseEI > 0 ? model.baseEI : 250)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .help(model.logMode != 0
                      ? "Log mode locks the EI — turn Log off (Look menu) to set EI"
                      : "Clean EI (250–1250) loads a calibrated tone curve with gain at 1.0. To go higher, set EI to 1250 then add gain (adds noise). Effective EI = clean × gain.")
            } else if model.baseEI > 0 {
                // Flex-class: EI via video gain (EI = base × gain/1024) — the
                // same field the camera's own EI menu writes (verified live).
                settingsRow("ISO / EI") {
                    Menu("EI \(model.currentEI)") {
                        ForEach(model.eiChoices, id: \.self) { ei in
                            Button(ei == model.baseEI ? "EI \(ei)  (native)" : "EI \(ei)") {
                                model.setEI(ei)
                            }
                        }
                    }
                    .frame(width: 110)
                    Text("base \(model.baseEI)").font(.caption2).foregroundStyle(.secondary)
                }
                .help("Exposure index — a develop gain over the sensor's native EI \(model.baseEI). Rides along as clip metadata; the raw stays raw. HQ mode locks it to native.")
            }
            if !model.videoSystemOptions.isEmpty {
                settingsRow("SDI output") {
                    Menu(CameraModel.videoSystemLabel(model.currentVideoSystem)) {
                        let opts = model.videoSystemOptions
                        let clean = opts.filter { $0.clean }
                        let other = opts.filter { !$0.clean }
                        ForEach(clean) { o in
                            Button(o.id == model.currentVideoSystem ? "✓ \(o.label)" : o.label) {
                                model.setVideoSystem(o.id)
                            }
                        }
                        if !other.isEmpty {
                            Section("PsF / interlaced — can bounce on USB capture") {
                                ForEach(other) { o in
                                    Button(o.id == model.currentVideoSystem ? "✓ \(o.label)" : o.label) {
                                        model.setVideoSystem(o.id)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 130)
                    Text("progressive = safest").font(.caption2).foregroundStyle(.secondary)
                }
                .help("The camera's SDI/HDMI output standard. Your AVMatrix UC2018 accepts all of these; use a progressive (p) format — 1080p30 is the clean default. PsF / interlaced formats can make a USB capture box's auto-detect bounce. Changing this briefly drops the SDI feed while it re-locks.")
            }
            Toggle("HQ mode (cleaner image, caps max fps)", isOn: $model.hqMode)
                .font(.caption)
                .onChange(of: model.hqMode) { _, _ in model.settingsEdited() }
            Toggle("Apply to all empty partitions", isOn: $model.applyToAllCines)
                .font(.caption)
            Text("Settings apply instantly — press Return after typing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            triggerPositionPanel

            Divider()
            HStack {
                Button("Black Ref") { model.blackReference() }
                    .tint(model.blackRefDone ? nil : .orange)
                    .help("Camera black calibration (cap the lens / close the shutter). DO THIS FIRST, before white balancing — then colour is accurate.")
                Button {
                    showBrefReminderPopover = true
                } label: {
                    Image(systemName: model.brefRemindEnabled ? "bell.badge.fill" : "bell")
                }
                .tint(model.brefRemindEnabled ? .orange : nil)
                .help("Black-reference reminder — older sensors like the Flex 2K's drift with temperature, so regular black refs keep blacks clean")
                .popover(isPresented: $showBrefReminderPopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Black Reference Reminder").font(.headline)
                        Toggle("Remind me to black-ref", isOn: $model.brefRemindEnabled)
                            .toggleStyle(.switch)
                        HStack(spacing: 6) {
                            Text("Every")
                            TextField("min", value: $model.brefRemindMinutes,
                                      format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 52)
                                .disabled(!model.brefRemindEnabled)
                            Text("minutes")
                        }
                        Text("The Flex 2K's sensor drifts with temperature — regular black references keep the blacks clean. The VEO and Flex 4K hold their calibration much longer, so leave this off for them. The timer restarts whenever a black ref runs; when it's due, the Black Ref button turns orange and a reminder pops up.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 300)
                }
                Button("Camera WB") { model.requestWhiteBalance { model.cameraWhiteBalance() } }
                    .help("White balance from a grey card in the centre of frame — sets the CAMERA, so the Ethernet feed and SDI match. Black Ref first.")
                if model.supportsDark {
                    Button(model.shutterClosed ? "OPEN Shutter" : "Close Shutter") {
                        model.toggleShutterClosed()
                    }
                    .tint(model.shutterClosed ? .red : nil)
                    .help("BlackShade internal shutter — close before black reference")
                }
            }
            if model.supportsQuiet {
                Toggle("Quiet fan mode", isOn: Binding(
                    get: { model.quietMode },
                    set: { _ in model.toggleQuiet() }))
                    .font(.caption)
                    .help("Slows the fan for sound-sensitive sets — watch the temperature readout")
            }

            Divider()

            settingsRow("Partitions") {
                Menu("\(model.partitionCount)") {
                    ForEach(1...32, id: \.self) { n in
                        Button("\(n)") {
                            pendingPartitions = n
                            confirmPartitions = true
                        }
                    }
                }
                .frame(width: 70)
                Text(String(format: "%.2fs each", model.recordSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Repartition camera RAM?",
                isPresented: $confirmPartitions
            ) {
                Button("Erase RAM & Set \(pendingPartitions) Partitions", role: .destructive) {
                    model.setPartitions(pendingPartitions)
                }
            } message: {
                Text("This erases ALL shots stored in camera RAM.")
            }

            // ── Sync / Genlock — collapsible (rarely used, tucked away) ──
            DisclosureGroup(isExpanded: $showGenlock) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Sync source", selection: Binding(
                        get: { model.syncMode },
                        set: { model.setSyncMode($0) }
                    )) {
                        ForEach(CameraModel.SyncMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    if model.syncMode != .internalClock {
                        HStack(spacing: 6) {
                            Circle().fill(model.genlockLocked ? .green : .orange)
                                .frame(width: 8, height: 8)
                            Text(model.genlockLocked ? "LOCKED to \(model.syncMode.short)"
                                                     : "no lock — check the \(model.syncMode.short) signal")
                                .font(.caption)
                                .foregroundStyle(model.genlockLocked ? .green : .orange)
                        }
                    } else {
                        Text("Free-running on the camera's internal clock.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(syncHint(model.syncMode))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)
                    Text("TIMECODE").font(.caption2.bold()).foregroundStyle(.secondary).tracking(0.5)
                    Picker("Format", selection: Binding(
                        get: { model.tcMode }, set: { model.setTCMode($0) }
                    )) {
                        Text("IRIG").tag(0)
                        Text("SMPTE").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Set to time-of-day on connect", isOn: $model.syncTCOnConnect)
                        .font(.caption)
                    Picker("Zone", selection: Binding(
                        get: { model.tcTimeZoneID },
                        set: { model.tcTimeZoneID = $0
                               if model.connected { model.syncTimecodeToTimeOfDay() } }
                    )) {
                        Text("Match this Mac").tag("")
                        Text("Los Angeles · PT").tag("America/Los_Angeles")
                        Text("Denver · MT").tag("America/Denver")
                        Text("Chicago · CT").tag("America/Chicago")
                        Text("New York · ET").tag("America/New_York")
                        Text("UTC").tag("UTC")
                        Text("London").tag("Europe/London")
                        Text("Paris · CET").tag("Europe/Paris")
                        Text("Tokyo · JST").tag("Asia/Tokyo")
                        Text("Sydney · AET").tag("Australia/Sydney")
                        Text("Honolulu · HT").tag("Pacific/Honolulu")
                    }
                    .pickerStyle(.menu).font(.caption)
                    Button { model.syncTimecodeToTimeOfDay() } label: {
                        Label("Set Timecode to Time of Day now", systemImage: "clock.arrow.2.circlepath")
                    }
                    .controlSize(.small)
                    Text("Jams the camera clock to this Mac's wall-clock time — a fresh Flex 4K boots at a year-2000 default until it's set.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    Label("Sync / Genlock", systemImage: "wave.3.right")
                    Button { showSyncHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How Phantom sync & genlock works")
                    .popover(isPresented: $showSyncHelp, arrowEdge: .trailing) { syncHelpView }
                    if model.syncMode != .internalClock && model.genlockLocked {
                        Text("LOCKED").font(.caption2.bold()).foregroundStyle(.green)
                    }
                }
            }
            .onChange(of: showGenlock) { _, open in if open { model.refreshGenlock() } }
        }
        .textFieldStyle(.roundedBorder)
    }

    /// PCC-style "Image Range and Trigger Position": one draggable bar,
    /// red = pre-trigger history, green = post-trigger, T marker at the split.
    private var triggerPositionPanel: some View {
        let cap = max(model.capacityFrames, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Image Range and Trigger Position").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let preFrac = CGFloat(model.preTriggerFrames) / CGFloat(cap)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(.red.opacity(0.85))
                            .frame(width: geo.size.width * preFrac)
                        Rectangle().fill(.green.opacity(0.85))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    // T marker
                    VStack(spacing: 0) {
                        Text("T").font(.system(size: 9, weight: .bold))
                        Rectangle().fill(.white).frame(width: 2)
                    }
                    .frame(height: geo.size.height)
                    .offset(x: max(0, min(geo.size.width - 2, geo.size.width * preFrac - 1)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard geo.size.width > 0 else { return }
                            let frac = min(max(v.location.x / geo.size.width, 0), 1)
                            guard frac.isFinite else { return }
                            model.postTriggerFrames = cap - Int(frac * CGFloat(cap))
                        }
                        .onEnded { _ in model.applySettings() }
                )
            }
            .frame(height: 26)
            let dur = model.recordSeconds
            let preS = model.frameRate > 0 ? Double(model.preTriggerFrames) / Double(model.frameRate) : 0
            Text(String(format: "Duration %.2fs (%dp) — pre %.2fs / post %.2fs",
                        dur, cap, preS, dur - preS))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            // PCC-style: set EITHER side — the other adjusts to fill capacity.
            HStack {
                Text("Pre-trigger")
                TextField("frames", value: Binding(
                    get: { model.preTriggerFrames },
                    set: { model.postTriggerFrames = max(model.capacityFrames - max($0, 0), 0) }
                ), format: .number.grouping(.never))
                    .frame(width: 76)
                    .onSubmit { model.applySettings() }
                Text("Post-trigger")
                TextField("frames", value: $model.postTriggerFrames, format: .number.grouping(.never))
                    .frame(width: 76)
                    .onSubmit { model.applySettings() }
                Text("frames").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var imageTuning: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.viewerSource == .sdi && model.sdi.isRunning {
                Text("These adjust the Ethernet viewer only — switch Viewer to Ethernet to see them. SDI color is set on the camera (Camera WB button).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button {
                model.requestWhiteBalance { model.autoWhiteBalance() }
            } label: {
                Label("Auto White Balance (viewer)", systemImage: "circle.lefthalf.filled")
                    .frame(maxWidth: .infinity)
            }
            .help("Grey-world estimate for the Ethernet display only. For accurate colour, do Black Ref then Camera WB off a grey card.")
            settingsRow("WB Red") {
                Slider(value: $model.wbRed, in: 0.5...3.0)
                    .onChange(of: model.wbRed) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.wbRed)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("WB Blue") {
                Slider(value: $model.wbBlue, in: 0.5...3.0)
                    .onChange(of: model.wbBlue) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.wbBlue)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("Gain") {
                Slider(value: $model.gain, in: 0.5...4.0)
                    .onChange(of: model.gain) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.gain)).font(.caption.monospaced()).frame(width: 36)
            }
            Divider()
            HStack {
                Text("Picture — Ethernet feed is raw; tune to taste (recordings unaffected).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Auto") { model.autoTunePreview() }
                    .font(.caption2)
                    .help("Re-measure the black/white points and grey balance from the current picture")
            }
            settingsRow("Black") {
                Slider(value: $model.previewBlack, in: 0.0...0.6)
                    .onChange(of: model.previewBlack) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.previewBlack)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("White") {
                Slider(value: $model.previewWhite, in: 0.4...1.0)
                    .onChange(of: model.previewWhite) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.previewWhite)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("Contrast") {
                Slider(value: $model.previewContrast, in: 1.0...2.5)
                    .onChange(of: model.previewContrast) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.previewContrast)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("Saturation") {
                Slider(value: $model.previewSaturation, in: 1.0...2.0)
                    .onChange(of: model.previewSaturation) { _, _ in model.rerenderLastFrame() }
                Text(String(format: "%.2f", model.previewSaturation)).font(.caption.monospaced()).frame(width: 36)
            }
        }
    }

    private var playInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let slot = model.cines.first(where: { $0.id == model.selectedCine }) {
                // ── Cine C<n> — one collapsible category (all info inside) ──
                DisclosureGroup(isExpanded: $showCineInfo) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(slot.frameCount) frames  (\(slot.firstFrame) … \(slot.lastFrame))")
                            .font(.caption.monospaced())
                        Text("State: \(slot.flags.joined(separator: " "))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Button("Re-read Frame Range") { model.refreshSelectedCineRange() }
                                .help("Asks the camera for this cine's current first/last frame numbers — use it if the range shown looks stale")
                        }
                        // Flicker scan hidden for the beta (Buddy, 2026-07-09):
                        // it doesn't work reliably yet. Model code kept —
                        // restore the button here when it's trustworthy.
                    }
                    .padding(.top, 4)
                } label: {
                    HStack {
                        Text("Cine C\(slot.id)").font(.headline)
                        Spacer()
                        Text(slot.flags.joined(separator: " "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // ── Save / Download — its own collapsible category ──
                DisclosureGroup(isExpanded: $showSaveDownload) {
                    downloadPanel(slot: slot).padding(.top, 4)
                } label: {
                    Text("Save / Download").font(.headline)
                }
            } else {
                Text("Select a stored cine below").foregroundStyle(.secondary)
            }
            Divider()
            magPanel
            Divider()
            cineStationPanel
            Divider()
            DisclosureGroup(isExpanded: $showViewerImage) {
                imageTuning.padding(.top, 4)
            } label: {
                Text("Viewer Image (Ethernet preview)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func downloadPanel(slot: CineSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Project").frame(width: 50, alignment: .leading).font(.callout)
                TextField("e.g. Dunkin Donuts", text: $model.projectName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Shot").frame(width: 50, alignment: .leading).font(.callout)
                TextField("e.g. coffee pour (blank = C\(model.selectedCine))", text: $model.shotName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Image(systemName: "folder")
                Text(URL(fileURLWithPath: model.saveFolderPath).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .help(model.saveFolderPath)
                Spacer()
                Button("Choose…") { model.chooseSaveFolder() }
                    .font(.caption)
            }
            let dlFrames = Int(model.outPoint - model.inPoint) + 1
            let estGB = Double(model.estimatedDownloadBytes(frames: dlFrames)) / 1e9
            HStack(spacing: 6) {
                Text("\(dlFrames) frames  (\(Int(model.inPoint)) … \(Int(model.outPoint)))")
                    .font(.caption.monospaced())
                Spacer()
                Image(systemName: "internaldrive")
                Text("≈\(String(format: "%.1f", estGB)) GB · \(model.freeSpaceString)")
                    .font(.caption2)
            }
            .foregroundStyle(model.downloadWontFit(frames: dlFrames) ? Color.red : Color.secondary)
            // Permanent progress bar sits between the frame/storage line and the
            // Download button, so the layout doesn't jump when a download starts.
            downloadProgressBar
                Button {
                    if model.downloadWontFit(frames: dlFrames) { confirmLowSpace = true }
                    else { model.downloadSelectedCine() }
                } label: {
                    Label("Download In→Out to Mac (.cine)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .disabled(slot.state != .stored || model.magSavingCine != nil || model.magBusy != nil)
                .help("Copy this clip over Ethernet to this computer")
                .confirmationDialog("Not enough free space", isPresented: $confirmLowSpace, titleVisibility: .visible) {
                    Button("Download anyway", role: .destructive) { model.downloadSelectedCine() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clip needs ≈\(String(format: "%.1f", estGB)) GB but the drive only has \(model.freeSpaceString). Free up space or pick another destination.")
                }
                Button {
                    model.saveToMag()
                } label: {
                    Label("Save In→Out to CineMag", systemImage: "externaldrive.fill.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(slot.state != .stored || model.downloadProgress != nil)
                .help("Camera-side copy onto the CineMag — faster than a Mac download. Can't run while a Mac download is in progress (the camera can't do both).")
                Button {
                    model.downloadAllStored()
                } label: {
                    Label(model.queuedDownloads > 0
                          ? "Dumping… \(model.queuedDownloads) in queue"
                          : "Download ALL stored shots to Mac",
                          systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.queuedDownloads > 0 || model.magSavingCine != nil || model.magBusy != nil)
                .help("End-of-day dump: queues every green partition for download to the project folder")
                Button { openWindow(id: "clips") } label: {
                    Label("Clips & DIT Report…", systemImage: "doc.text.image")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Browse downloaded clips and export the end-of-day DIT report (⌘B)")
                Toggle(isOn: $model.proxyOnDownload) {
                    Label("Record SDI proxy (.mov) while downloading", systemImage: "record.circle")
                }
                .toggleStyle(.switch)
                .font(.caption)
                .disabled(!model.sdi.isRunning)
                .help("Plays the clip out the SDI and records it — instant viewing copy beside the .cine")
                if let v = model.lastVerify {
                    HStack(spacing: 5) {
                        Image(systemName: v.ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(v.ok ? .green : .red)
                        Text(v.ok ? "Verified \(v.clip)" : "Last verify FAILED: \(v.clip)")
                            .font(.caption2)
                            .foregroundStyle(v.ok ? Color.secondary : Color.red)
                            .lineLimit(1)
                        Spacer()
                    }
                    .help(v.ok ? "Last download passed checksum verification"
                               : "Last download FAILED verification — \(v.message)")
                }
                HStack(spacing: 6) {
                    Text("Packing").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: $model.downloadPacking) {
                        ForEach(CameraModel.DownloadPacking.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 172)
                    Button { showPackingHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("What each packing format means")
                    .popover(isPresented: $showPackingHelp, arrowEdge: .bottom) { packingHelp }
                    Spacer()
                }

                // 10G readiness. Both preconditions for the raw-ethernet fast
                // path used to fail silently, so a tester on the ~7 MB/s TCP
                // fallback had no way to know. Say it out loud, before they
                // start a download and wait an hour.
                HStack(alignment: .top, spacing: 6) {
                    let st = model.tenGigStatus
                    Image(systemName: st?.fastPathReady == true
                          ? "bolt.horizontal.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(st?.fastPathReady == true ? .green
                                         : (st?.pathCanRun == true ? .yellow : .orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st?.summary ?? "10G status not checked yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let st, !st.bpfAvailable {
                            Text("Downloads are running on the slow path — about 10× slower than this card can do. Turning it on takes one click and your password; it works immediately, no restart.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Turn On Fast Downloads…") {
                                    if TenGigEnabler.enable() { model.refreshTenGigStatus() }
                                }
                                .font(.caption2).controlSize(.small)
                                Text("Asks for your Mac password once.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.top, 2)
                        }
                        if TenGigEnabler.isInstalled, let st, st.bpfAvailable {
                            Button("Turn Off Fast Downloads…") {
                                if TenGigEnabler.disable() { model.refreshTenGigStatus() }
                            }
                            .font(.caption2).controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    Spacer()
                    Button("Re-check") { model.refreshTenGigStatus() }
                        .font(.caption2).controlSize(.small)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .onAppear { model.refreshTenGigStatus() }

                Toggle(isOn: $model.verifyDownloads) {
                    Label("Verify downloads (MD5 checksum)", systemImage: "checkmark.shield")
                }
                .toggleStyle(.switch)
                .font(.caption)
                .help("After each download, re-open the .cine, confirm the frame count, and hash it. Writes a .md5 sidecar + a Checksums.md5 manifest (opens in ShotPut Pro / md5sum -c). A failed verify won't be marked saved and won't clear the partition.")

                DisclosureGroup(isExpanded: $showMetadata) {
                    VStack(spacing: 4) {
                        Toggle(isOn: $model.writeSidecars) {
                            Text(".xml + .mhl sidecars on download").font(.caption2)
                        }
                        .toggleStyle(.switch).padding(.bottom, 2)
                        Group {
                            metaField("Client", $model.meta.client)
                            metaField("Job", $model.meta.job)
                            metaField("Production", $model.meta.production)
                            metaField("Director", $model.meta.director)
                            metaField("DP", $model.meta.dp)
                            metaField("Operator", $model.meta.cameraOp)
                        }
                        Group {
                            metaField("Lens", $model.meta.lens)
                            metaField("Focal", $model.meta.focalLength, placeholder: "e.g. 50mm")
                            metaField("T-stop", $model.meta.aperture, placeholder: "e.g. T2.8")
                            metaField("ND / Filter", $model.meta.ndFilter)
                            metaField("Scene", $model.meta.scene)
                            metaField("Take", $model.meta.take)
                            metaField("Notes", $model.meta.notes)
                        }
                        Text("Frame rate, shutter, resolution & time are filled in from the camera automatically.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text("Metadata").font(.caption).foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showDownloadAdvanced) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("10G download limit").font(.caption)
                            Slider(value: $model.downloadThrottle, in: 5...100, step: 5)
                            Text(model.downloadThrottle >= 100 ? "Full" : "\(Int(model.downloadThrottle))%")
                                .font(.caption.monospaced())
                                .frame(width: 38, alignment: .trailing)
                        }
                        Text("How fast the camera sends .cine data over 10G Ethernet. Leave on Full; lower it only if a download reports packet loss / re-requests. (1G downloads aren't affected.)")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help("Camera-side pacing of the 10G raw download, in % of line rate (~6.4 MB/s per 1%). Lower = slower but more resilient on a busy Mac or slow disk.")
                } label: {
                    Text("Advanced").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
        }
    }

    /// A permanent download bar — always occupies the same space between the
    /// frame/storage line and the Download button, so nothing jumps when a
    /// download starts. Fills + shows %, speed and time remaining while active.
    private var downloadProgressBar: some View {
        VStack(spacing: 2) {
            ProgressView(value: model.downloadProgress ?? 0)
                .progressViewStyle(.linear)
                .tint(model.downloadProgress == nil ? Color.secondary.opacity(0.25) : .green)
            HStack(spacing: 6) {
                if let p = model.downloadProgress {
                    Text("\(Int(p * 100))%").font(.caption2.monospaced().bold())
                    Text(model.downloadStatus).font(.caption2.monospaced())
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { model.cancelDownload() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Cancel this download")
                } else {
                    Text(model.downloadStatus.isEmpty ? "No download running" : model.downloadStatus)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                }
            }
        }
        .frame(height: 30, alignment: .top)   // fixed height → layout never bounces
    }

    private func metaField(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
        }
    }

    /// The "?" popover next to the Save/Download packing picker — plain-English
    /// definitions of each pixel-packing format for downloaded .cine files.
    private var packingHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download packing").font(.headline)
            Text("How the RAW sensor data is stored in the .cine. None of these reduce quality below the camera's native bit depth — they trade file size and download speed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            packingDef("Auto (recommended)",
                       "Picks the fastest complete format for your connection — 10-bit packed over 10 GbE, full 12-bit over 1 GbE. Always the full data; you rarely need anything else.")
            packingDef("10-bit packed (P10)",
                       "The camera's native compact format (used by the CineMag and the 10G stream): a ≈2.2-gamma companded 10-bit. Visually lossless and the complete file for VEO / CineMag footage. Smallest files, fastest — needs a 10G link.")
            packingDef("12-bit (16-bit file)",
                       "Full 12-bit sensor data, uncompressed, in a 16-bit file. Largest files, most grading latitude on 12-bit bodies (e.g. Flex). Over the standard 1G path, so it's slower. On a 10-bit camera (VEO 4K) it just pads to 16-bit — no extra data.")
            Text("Tip: leave it on Auto unless you specifically need the uncompressed 12-bit file for heavy grading.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 340)
    }
    private func packingDef(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            Text(body).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var magPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CineMag").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshMag()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .help("Re-read the CineMag take list")
            }
            if !model.magInfo.isEmpty {
                Text(model.magInfo).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if !model.magTakes.isEmpty {
                Menu {
                    ForEach(model.magTakes) { take in
                        Button("\(take.label) — \(take.detail)") {
                            model.selectMagTake(take)
                        }
                    }
                } label: {
                    Label("Load mag take into deck…", systemImage: "play.rectangle")
                }
                Text("Takes labeled 1F, 2F… are on the CineMag. The deck timeline, scrub, in/out and loop all drive the mag take — picture shows on SDI.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // The doorway to the camera-side offload window — prominent on purpose,
            // matching the "Open CineStation" button so the two feel the same.
            Button {
                openWindow(id: "cinemag-manager")
            } label: {
                Label("Open CineMag", systemImage: "memorychip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.magSize > 0 ? .purple : .gray)
            .help("Open the CineMag offload window — thumbnails, download takes, verify, proxy, reports, delete/erase")
        }
    }

    /// Second-device (CineStation) status in the Save tab — shows whether it's
    /// connected and its IP, and opens the full browser. Makes the CineStation
    /// easy to find without digging through the File menu.
    private var cineStationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(cineStation.connected ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text("CineStation").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if cineStation.connected {
                Text("\(cineStation.deviceName)  ·  \(cineStation.host)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if !cineStation.magInfo.isEmpty {
                    Text(cineStation.magInfo).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                // Its own IP + connect — mirrors the camera header up top.
                HStack(spacing: 6) {
                    TextField("CineStation IP", text: $cineStation.host)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .disabled(cineStation.connecting)
                    Button(cineStation.connecting ? "…" : "Connect") { cineStation.connect() }
                        .font(.caption)
                        .disabled(cineStation.connecting)
                }
                if cineStation.needsNetworkSetup {
                    Button {
                        cineStation.setupNetwork()
                    } label: {
                        Label("Set Up Network for \(cineStation.host)",
                              systemImage: "network.badge.shield.half.filled")
                            .font(.caption)
                    }
                    .help("Adds an address on the CineStation's subnet to the free wired port (asks for your password once). Needed again after every Mac restart.")
                }
                if !cineStation.status.isEmpty && cineStation.status != "Not connected" {
                    Text(cineStation.status)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            // The doorway to the offload window — prominent on purpose.
            Button {
                openWindow(id: "cinestation")
            } label: {
                Label(cineStation.connected ? "Open CineStation" : "CineStation Window…",
                      systemImage: "externaldrive.connected.to.line.below")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(cineStation.connected ? .purple : .gray)
            .help("Open the CineStation offload window — browse the CineMag and download takes over 10G")
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .frame(width: 84, alignment: .leading)
                .font(.callout)
            content()
        }
    }

    private var captureButtons: some View {
        VStack(spacing: 8) {
            if let rec = model.activeRecordingCine {
                HStack {
                    Text("● RECORDING C\(rec)")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Stop & Save") { model.stopAndStore() }
                        .font(.caption.bold())
                        .tint(.green)
                        .buttonStyle(.borderedProminent)
                        .help("Stop now and keep what's recorded so far — no need to wait for the whole partition to roll out")
                    Button("Abort") { model.abortRecording() }
                        .font(.caption)
                        .help("Discard this recording and re-arm to change settings")
                }
            }
            HStack(spacing: 8) {
                Button {
                    if model.cineUnsaved(model.selectedCine) { confirmCapture = true }
                    else { model.capture() }
                } label: {
                    Label("CAPTURE", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                // Green = arm/roll; the RED button is TRIGGER, matching the
                // camera's own red trigger button (Buddy kept hitting the wrong one).
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected)
                .keyboardShortcut("c", modifiers: [])

                Button {
                    // Fires unconditionally, like the camera's own trigger button —
                    // Phantom operators know an unarmed trigger does nothing (the
                    // orange tint is the only hint needed).
                    model.trigger()
                } label: {
                    Label("TRIGGER", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(model.recordingCine != nil ? .red : .orange)
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected)
                .keyboardShortcut(.space, modifiers: [])
            }
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    if model.cineUnsaved(model.selectedCine) { confirmClear = true }
                    else { model.deleteSelectedCine() }
                } label: {
                    Label("Clear C\(model.selectedCine)", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.connected || model.selectedCine == 0)

                Button(role: .destructive) {
                    if model.unsavedCineCount() > 0 { confirmClearAll = true }
                    else { model.clearAllRam() }
                } label: {
                    Label("Clear All RAM", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.connected || model.cines.allSatisfy { $0.id == 0 || $0.state == .empty })
                .help("Erase every partition in RAM at once (keeps the partition layout)")
            }
        }
        .confirmationDialog("Overwrite C\(model.selectedCine)?",
                            isPresented: $confirmCapture, titleVisibility: .visible) {
            Button("Capture anyway (overwrites C\(model.selectedCine))", role: .destructive) { model.capture() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("C\(model.selectedCine) hasn't been downloaded to the laptop or saved to the CineMag yet. Capturing will overwrite it.")
        }
        .confirmationDialog("Clear C\(model.selectedCine)?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear anyway (erases C\(model.selectedCine))", role: .destructive) { model.deleteSelectedCine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("C\(model.selectedCine) hasn't been downloaded or saved to the CineMag yet. Clearing will erase it.")
        }
        // Clearing every partition at once.
        .confirmationDialog("Clear ALL RAM?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear all (\(model.unsavedCineCount()) un-saved)", role: .destructive) { model.clearAllRam() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases every partition in RAM." + unsavedRamNote)
        }
    }

    /// A trailing note warning about un-downloaded takes, for the clear dialogs.
    private var unsavedRamNote: String {
        let n = model.unsavedCineCount()
        return n > 0
            ? " ⚠️ \(n) partition\(n == 1 ? "" : "s") haven't been downloaded or saved to the CineMag — clearing erases them."
            : " All recorded partitions are already saved."
    }

    // MARK: Partition strip + status

    private var partitionStrip: some View {
        // Wrap into rows so a high partition count (e.g. 28) stays on-screen
        // instead of running off the right edge. Caps at ~3 rows, then scrolls.
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 6)], spacing: 6) {
                ForEach(model.cines) { slot in
                    Button {
                        // Stored clip → jump SDI to it; recording/empty → live.
                        model.selectCine(slot.id)
                    } label: {
                        VStack(spacing: 2) {
                            Text(slot.label).font(.caption.bold())
                            Text(slot.flags.joined(separator: " "))
                                .font(.system(size: 8, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(slot.color.opacity(slot.id == model.selectedCine ? 1.0 : 0.45))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(slot.id == model.selectedCine ? Color.white : .clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(slot.id >= 1 && slot.id <= 9
                          ? "Select C\(slot.id)  [⌘\(slot.id)]" : "Select \(slot.label)")
                    .contextMenu {
                        if slot.id > 0 {
                            Button("Apply current settings to C\(slot.id)") {
                                model.applySettings(toCine: slot.id)
                            }
                            .disabled(slot.state != .ready)
                            Button("Clear C\(slot.id)", role: .destructive) {
                                model.selectedCine = slot.id
                                model.deleteSelectedCine()
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chrome(0.14))
    }

    private var flickerMeter: some View {
        let r = model.flicker.reading
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(r.flickering ? .red : .green).frame(width: 8, height: 8)
                Text(r.flickering ? "FLICKER" : "Clean")
                    .font(.caption.bold())
                    .foregroundStyle(r.flickering ? .red : .green)
                Text(String(format: "±%.1f%%", r.amplitudePct))
                    .font(.caption.monospaced())
                if r.frequencyHz > 1 {
                    Text(String(format: "%.0f Hz", r.frequencyHz))
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            // Rolling-band readout — separate from the whole-frame swing above.
            if r.bandingPct > 0.2 {
                HStack(spacing: 6) {
                    Image(systemName: "barcode")
                        .font(.caption2)
                        .foregroundStyle(r.banding ? .red : .secondary)
                    Text("Banding")
                        .font(.caption.bold())
                        .foregroundStyle(r.banding ? .red : .secondary)
                    Text(String(format: "%.1f%%", r.bandingPct))
                        .font(.caption.monospaced())
                }
            }
            // Brightness-over-time sparkline.
            Canvas { ctx, size in
                guard r.trace.count > 1 else { return }
                var path = Path()
                let dx = size.width / CGFloat(r.trace.count - 1)
                for (i, v) in r.trace.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat(v)))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(r.flickering ? .red : .green), lineWidth: 1.2)
            }
            .frame(width: 170, height: 34)
            if r.flickering && !model.flickerAdvice.isEmpty {
                Text(model.flickerAdvice)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .frame(width: 170, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().frame(width: 170)
            // Deliberate 3-second capture → analyze → freeze a localized map.
            if let p = model.flickerSampleProgress {
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 110)
                    Text("\(Int(p * 100))%").font(.caption2.monospaced())
                }
                .frame(width: 170, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Button { model.sampleFlickerLive() } label: {
                        Label("Sample 3 s", systemImage: "record.circle")
                    }
                    .font(.caption)
                    .help("Capture ~3 s of the live SDI feed and mark exactly where it flickers or bands")
                    if model.monitor.frozenFlickerGrid != nil {
                        Button { model.clearFlickerSample() } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Clear the frozen map, back to live")
                    }
                }
                .frame(width: 170, alignment: .leading)
            }
            if !model.flickerSampleSummary.isEmpty {
                Text(model.flickerSampleSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .frame(width: 170, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Where the scope cluster sits on the picture (right-click a scope to change).
    private var scopeAlignment: Alignment {
        switch model.monitor.scopeCorner {
        case 0: return .topLeading
        case 1: return .topTrailing
        case 3: return .bottomTrailing
        default: return .bottomLeading
        }
    }

    @ViewBuilder
    private func waveformView(_ wf: CGImage, light: Bool) -> some View {
        // The trace is drawn bright-on-black; invert it for black-on-white.
        if light { Image(decorative: wf, scale: 1).resizable().colorInvert() }
        else     { Image(decorative: wf, scale: 1).resizable() }
    }

    private func scopeBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let light = model.monitor.scopeLightBG
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(light ? .black : Color.secondary)
            content()
                .background(light ? Color.white : Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(6)
        .background((light ? Color.white : Color.black).opacity(light ? 0.95 : 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.55), lineWidth: 1))
    }

    private var histogramView: some View {
        let light = model.monitor.scopeLightBG
        return Canvas { ctx, size in
            let bins = model.monitor.histogram
            guard !bins.isEmpty else { return }
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(light ? .white : .black.opacity(0.6)))
            let bw = size.width / CGFloat(bins.count)
            let bar: Color = light ? .black : .white
            for (i, v) in bins.enumerated() {
                let h = CGFloat(v) * (size.height - 4)
                let rect = CGRect(x: CGFloat(i) * bw, y: size.height - h, width: bw - 0.5, height: h)
                ctx.fill(Path(rect), with: .color(bar.opacity(0.9)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusLine).font(.caption)
            if model.connected && model.cameraTemp > 0 {
                Label("\(model.cameraTemp)°C", systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(model.cameraTemp >= 65 ? .red : .secondary)
                    .help("Camera body \(model.cameraTemp)°C — sensor \(model.sensorTemp)°C")
            }
            Spacer()
            Text(model.log.last ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.chrome(0.10))
    }
}
