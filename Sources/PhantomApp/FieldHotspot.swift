import SwiftUI
import Darwin

/// "No Wi-Fi on set" helper: turn the Mac into a Wi-Fi hotspot so the phone/iPad
/// remote can connect with no network around. The camera link is Ethernet and is
/// untouched by any of this.
///
/// macOS reality: Apple removed the old ad-hoc "Create Network," and the only
/// Mac-as-access-point path left is **Internet Sharing** (System Settings ▸
/// General ▸ Sharing). It's a settings toggle, not a clean command — so we make a
/// best-effort attempt to flip it on via one admin prompt, VERIFY that the
/// hotspot bridge actually came up, and fall straight back to opening the
/// settings pane (with steps) if it didn't. Either way you're one step from a
/// hotspot. Reversible: "Turn off" disables it again.
@MainActor
final class FieldHotspot: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var active = false      // an Internet-Sharing bridge is up

    /// Refresh the on/off state from the system (call when the panel appears).
    func refreshActive() { active = Self.isHotspotUp() }

    /// Best-effort: turn Internet Sharing on (shared to Wi-Fi). Verifies the
    /// hotspot bridge came up; if not, opens the settings pane so it can be
    /// finished by hand. Calls `onUp` on success so the caller can refresh the QR.
    func start(onUp: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        status = "Turning on Internet Sharing — enter your Mac password when macOS asks…"
        DispatchQueue.global().async {
            let ran = Self.runAdmin(
                script: Self.enableScript(),
                prompt: "Phantom Control wants to turn on Internet Sharing so your phone or iPad can connect when there is no Wi-Fi around. Your camera link is not affected.")
            if ran { Thread.sleep(forTimeInterval: 4.5) }   // let the AP spin up
            let up = Self.isHotspotUp()
            DispatchQueue.main.async {
                self.busy = false
                self.active = up
                if up {
                    self.status = "Internet Sharing is on. Look for the “Phantom Control” Wi‑Fi network on your phone (open, no password), join it, then tap Refresh above for the QR. If it doesn't appear, toggle the phone's Wi‑Fi off/on."
                    onUp()
                } else {
                    self.status = ran
                        ? "Started, but no hotspot showed up yet — opening Internet Sharing settings so you can confirm it's on and set to Wi-Fi."
                        : "Couldn't turn it on automatically (newer macOS locks this down) — opening Internet Sharing settings. Switch it on and share to Wi-Fi."
                    self.openSettings()
                }
            }
        }
    }

    /// Turn Internet Sharing back off.
    func stop() {
        guard !busy else { return }
        busy = true
        status = "Turning the hotspot off…"
        DispatchQueue.global().async {
            _ = Self.runAdmin(script: Self.disableScript(),
                              prompt: "Phantom Control wants to turn Internet Sharing off.")
            Thread.sleep(forTimeInterval: 2.0)
            let up = Self.isHotspotUp()
            DispatchQueue.main.async {
                self.busy = false
                self.active = up
                self.status = up ? "Still on — you can switch it off in System Settings ▸ Sharing." : "Hotspot off."
            }
        }
    }

    /// Jump straight to the Sharing settings pane (Internet Sharing lives there).
    func openSettings() {
        for u in ["x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                  "x-apple.systempreferences:com.apple.preferences.sharing"] {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - System plumbing

    /// True when the Wi-Fi hotspot is configured on. Reads the Internet Sharing
    /// config's `NAT ▸ AirPort ▸ Enabled` flag directly — that's specifically the
    /// **Wi-Fi** AP state (the top-level `NAT.Enabled` can read 1 for an unrelated
    /// wired-sharing config, and the 192.168.2.1 gateway can belong to a
    /// Thunderbolt/VM bridge — both would false-positive). The .nat.plist is
    /// world-readable, so no admin is needed to check.
    static func isHotspotUp() -> Bool {
        let p = Process()
        p.launchPath = "/usr/libexec/PlistBuddy"
        p.arguments = ["-c", "Print :NAT:AirPort:Enabled",
                       "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return false }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true"
    }

    /// Writes the shell to a temp file (keeps quoting sane) and runs it once with
    /// admin rights via osascript — same one-password pattern as the CineStation
    /// network setup. Returns true if the user authenticated and it ran.
    static func runAdmin(script: String, prompt: String) -> Bool {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("phantom_hotspot.sh")
        do { try script.write(toFile: path, atomically: true, encoding: .utf8) } catch { return false }
        let osa = "do shell script \"/bin/sh \\\"\(path)\\\"\" with administrator privileges with prompt \"\(prompt)\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", osa]
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Configure Internet Sharing to broadcast a Wi-Fi network named
    /// "Phantom Control" and (re)start its daemon. Runs as root. Sharing TO Wi-Fi
    /// is `AirPort.Enabled = 1` + a NetworkName (NOT a SharingDevices entry — that
    /// key is for wired share-to devices). No password → an open network; the
    /// phone remote is token-gated regardless, so only someone with the QR link
    /// can control anything. `exit 0` so a noisy launchctl line doesn't read as
    /// failure — success is judged by the AirPort flag, not this exit code.
    static func enableScript() -> String {
        """
        #!/bin/sh
        defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict Enabled -int 1 NatPortMapDisabled -bool false PrimaryInterface '{Device=""; Enabled=0;}' SharingDevices '()' AirPort '{Enabled=1; NetworkName="Phantom Control"; "40BitEncrypt"=1; Channel=0;}'
        launchctl kickstart -k system/com.apple.InternetSharing 2>/dev/null || launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.InternetSharing.plist 2>/dev/null || launchctl load -w /System/Library/LaunchDaemons/com.apple.InternetSharing.plist 2>/dev/null
        exit 0
        """
    }

    static func disableScript() -> String {
        """
        #!/bin/sh
        defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict Enabled -int 0 NatPortMapDisabled -bool false PrimaryInterface '{Device=""; Enabled=0;}' SharingDevices '()' AirPort '{Enabled=0; NetworkName="Phantom Control"; "40BitEncrypt"=1; Channel=0;}'
        launchctl kickstart -k system/com.apple.InternetSharing 2>/dev/null
        exit 0
        """
    }
}

/// The "No Wi-Fi on set?" block shown in the App Connect panel.
struct FieldHotspotSection: View {
    @ObservedObject var hotspot: FieldHotspot
    var onNetworkUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Wi-Fi on set?").font(.caption.bold())
            Text("Most reliable: an **iPhone Personal Hotspot** — join it on both the Mac and the phone. Or make this Mac the hotspot:")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if hotspot.active {
                    Label("Hotspot on", systemImage: "wifi").font(.caption2).foregroundStyle(.green)
                    Button { hotspot.stop() } label: { Label("Turn off", systemImage: "wifi.slash") }
                        .disabled(hotspot.busy)
                } else {
                    Button { hotspot.start(onUp: onNetworkUp) } label: { Label("Create hotspot", systemImage: "wifi.router") }
                        .disabled(hotspot.busy)
                    Button { hotspot.openSettings() } label: { Label("Do it manually", systemImage: "gearshape") }
                        .help("Open Internet Sharing settings and switch it on (share to Wi-Fi)")
                }
                if hotspot.busy { ProgressView().controlSize(.small) }
            }
            .font(.caption)
            if !hotspot.status.isEmpty {
                Text(hotspot.status).font(.caption2)
                    .foregroundStyle(hotspot.busy ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The hotspot takes your Mac's name — rename the Mac to “Phantom Control” in System Settings ▸ General ▸ About to name the network. After it's up, hit Refresh above for the new QR.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
