import SwiftUI
import UniformTypeIdentifiers

@main
struct PhantomControlApp: App {
    @StateObject private var model = CameraModel()
    @StateObject private var cineStation = CineStationModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Process-wide belt-and-suspenders: no socket write may kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("Phantom Control") {
            ContentView()
                .environmentObject(model)
                .environmentObject(cineStation)
                .onAppear {
                    model.loadFrameGuides()
                    model.loadShootMeta()
                    // SDI is the primary monitor when a capture box is present;
                    // fall back to the Ethernet feed otherwise.
                    model.sdi.refreshDevices()
                    if !model.sdi.devices.isEmpty {
                        model.viewerSource = .sdi
                        model.sdi.requestAccessAndStart()
                    }
                    // USB capture boxes can enumerate late after launch or a
                    // cable repatch — retry so the feed comes back on its own
                    // instead of needing a manual reconnect every relaunch.
                    for delay in [1.5, 4.0, 8.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard !model.sdi.isRunning else { return }
                            // Never override a source the user picked by hand —
                            // switching to Ethernet now RELEASES the capture
                            // card, and this retry would silently re-claim it.
                            guard !model.viewerSourceUserSet else { return }
                            model.sdi.refreshDevices()
                            if !model.sdi.devices.isEmpty {
                                model.viewerSource = .sdi
                                model.sdi.requestAccessAndStart()
                            }
                        }
                    }
                    // Find and connect to the camera automatically on launch. A
                    // wired interface (and its ARP for the camera) can take a
                    // moment to come up after launch or a cable repatch, so the
                    // first attempt often fails with errno 65 (host not ready).
                    // Retry a few times instead of giving up — same approach as
                    // the SDI-capture retry above.
                    if !model.connected {
                        model.discoverAndConnect()
                        for delay in [2.0, 5.0, 10.0] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                if !model.connected { model.discoverAndConnect() }
                            }
                        }
                    }
                    // Auto-connect a CineStation if one is on its own port (10G),
                    // so it shows as connected in the Save tab without opening the
                    // browser window. Fails silently if none is present.
                    cineStation.cam = model    // shared save folder / sidecars / reports
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if !cineStation.connected { cineStation.connect() }
                    }
                    // Local HTTP remote for Stream Deck buttons.
                    model.startRemote()
                }
        }
        .commands {
            // Custom About with author + contact.
            CommandGroup(replacing: .appInfo) {
                Button("About Phantom Control") { Self.showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button("Open .cine File…") {
                    CineFileOpener.openPanel(openWindow: openWindow)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Video Output Window") {
                    openWindow(id: "video-output")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Project Clips / DIT Report") {
                    openWindow(id: "clips")
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("CineStation…") {
                    openWindow(id: "cinestation")
                }
                Divider()
                Button("Camera Console…") {
                    openWindow(id: "camera-console")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Image Tools…") {
                    openWindow(id: "image-tools")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            // Appearance lives in the Window menu, next to the other
            // window-arrangement items — the same place Photoshop keeps
            // interface brightness.
            AppearanceCommands(theme: AppTheme.shared)
            CommandGroup(replacing: .help) {
                Button("Phantom Control Help") { Self.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Release Notes") { Self.openReleaseNotes() }
                Divider()
                Button("Reset Camera…") { model.showResetCamera = true }
                    .disabled(!model.connected)
            }
        }

        // External monitor mirror of the processed feed (HDMI / second display) —
        // flip / false color / peaking / guides; double-click for true full screen.
        Window("Video Output", id: "video-output") {
            SDIOutputView()
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)

        // Frame-guide editor (set-and-forget; close when done).
        Window("Frame Guides", id: "frame-guides") {
            FrameGuidesView()
                .environmentObject(model)
        }
        .defaultSize(width: 470, height: 420)

        // Project clip browser / DIT report (thumbnails + checksum + metadata).
        Window("Project Clips", id: "clips") {
            ClipBrowserView()
                .environmentObject(model)
        }
        .defaultSize(width: 820, height: 600)

        // Scrub / transport for a downloaded clip playing on the Video Out
        // monitor — a control surface for offline clips, separate from the RAM deck.
        Window("Clip Playback", id: "clip-playback") {
            ClipPlaybackView()
                .environmentObject(model)
        }
        .defaultSize(width: 680, height: 560)

        // Detached image-overlay panel (drag-and-drop reference images here).
        Window("Image Overlay", id: "overlay-panel") {
            OverlayPanel()
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .defaultSize(width: 320, height: 420)

        // Second device: the CineStation offload window on its own network port
        // (10G fiber). Runs alongside the live camera; browses + pulls the
        // CineMag's takes. Also gets the camera model: shared save folder /
        // project, sidecars, and DIT reports.
        Window("CineStation", id: "cinestation") {
            CineStationView()
                .environmentObject(cineStation)
                .environmentObject(model)
        }
        .defaultSize(width: 620, height: 540)

        // Camera-side CineMag offload station — a REAL window (so it gets the
        // standard red/yellow/green title-bar controls), matching the CineStation
        // window instead of a modal sheet.
        Window("Manage CineMag", id: "cinemag-manager") {
            MagManagerSheet()
                .environmentObject(model)
        }
        .defaultSize(width: 620, height: 640)

        // Raw Phantom-protocol console — the "netcat" surface for advanced users
        // (any get/set var, rec, trig, iload, cam.* controls). File ▸ Camera Console.
        Window("Camera Console", id: "camera-console") {
            CameraConsoleView()
                .environmentObject(model)
        }
        .defaultSize(width: 780, height: 540)

        // PCC-style Image Tools — the camera's develop pipeline (gamma, toe, saturation,
        // hue, chroma, pedestal, flare…) as live sliders. Shift ▸ Camera ▸ Image Tools.
        Window("Image Tools", id: "image-tools") {
            ImageToolsView()
                .environmentObject(model)
        }
        .defaultSize(width: 460, height: 620)

        // One player window per .cine file (drag-and-drop or File ▸ Open).
        WindowGroup("Cine Player", for: URL.self) { $url in
            if let url {
                CinePlayerView(url: url)
            }
        }
    }
}

extension PhantomControlApp {
    /// Opens the bundled HELP.md in the user's default Markdown/text app.
    static func openHelp() {
        if let url = Bundle.main.url(forResource: "HELP", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the bundled CHANGELOG.md (what changed in each version).
    static func openReleaseNotes() {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Native About panel with author + contact and the version.
    @MainActor
    static func showAbout() {
        let contact = "buddy@lacinemarobotics.com"
        let credits = NSMutableAttributedString(
            string: "Native macOS control for Vision Research Phantom cameras.\n\nBy Buddy Bleckley\n\(contact)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        // Make the email a mailto link.
        if let r = credits.string.range(of: contact) {
            credits.addAttribute(.link, value: "mailto:\(contact)",
                                 range: NSRange(r, in: credits.string))
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© Buddy Bleckley · LA Cinema Robotics",
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

enum CineFileOpener {
    @MainActor
    static func openPanel(openWindow: OpenWindowAction) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cine") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Phantom .cine files to play"
        panel.begin { resp in
            guard resp == .OK else { return }
            for url in panel.urls where url.pathExtension.lowercased() == "cine" {
                openWindow(value: url)
            }
        }
    }
}
