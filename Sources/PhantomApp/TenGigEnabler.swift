import Foundation
import PhantomCore

/// One-click setup for the 10G raw-ethernet download path.
///
/// The camera's fast path (`ximg`) is not TCP — the camera fires raw layer-2
/// ethernet frames (EtherType 0x88B7) straight at our NIC's MAC. Reading those
/// on macOS requires a BPF device, and `/dev/bpf*` is `root:wheel 0600` on a
/// stock Mac. Without access the app silently falls back to the ~7 MB/s TCP
/// loop, which is how a tester ended up reporting "5 MB/s" on a 10G adapter.
///
/// This does the same job as Wireshark's ChmodBPF, using the same `access_bpf`
/// group so the two cooperate rather than fight, via the app's existing
/// one-password `osascript` admin pattern (see `FieldHotspot.runAdmin`).
///
/// Two halves, because they solve different problems:
///   · **Right now** — `chown` the existing bpf nodes to the logged-in user, so
///     the ALREADY-RUNNING app can open them without logging out. Group
///     membership can't help here: a process's group set is fixed at login.
///   · **Every boot after** — a LaunchDaemon re-applies `access_bpf` group
///     access, because /dev is rebuilt at boot and any chown is lost.
enum TenGigEnabler {

    static let daemonLabel = "com.bleckley.phantomcontrol.ChmodBPF"
    static let group = "access_bpf"
    private static let supportDir = "/Library/Application Support/Phantom Control/ChmodBPF"
    private static let plistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"

    /// The boot-time script, installed to `supportDir`.
    private static var bootScript: String {
        """
        #!/bin/sh
        # Installed by Phantom Control. Grants the access_bpf group read/write on
        # the BPF devices at every boot, so the 10G download path can run without
        # root. Remove with the Disable button in Phantom Control's Save panel.
        GROUP=\(group)
        dscl . -read "/Groups/$GROUP" >/dev/null 2>&1 || exit 1
        syslog -s -l notice "Phantom Control ChmodBPF: granting $GROUP access to /dev/bpf*"
        for i in $(seq 0 15); do
            [ -e "/dev/bpf$i" ] || continue
            chgrp "$GROUP" "/dev/bpf$i" 2>/dev/null
            chmod g+rw "/dev/bpf$i" 2>/dev/null
        done
        exit 0
        """
    }

    private static var plist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(supportDir)/ChmodBPF</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
    }

    /// Runs as root. Idempotent — safe to run repeatedly.
    static func enableScript() -> String {
        let user = NSUserName()
        // Heredocs are quoted ('EOF') so the shell does not expand anything
        // inside the payloads — they contain $GROUP, $i and XML.
        return """
        #!/bin/sh
        set -e

        # 1. The group. Reuse Wireshark's if it already exists.
        if ! dscl . -read /Groups/\(group) >/dev/null 2>&1; then
            dseditgroup -o create -r "Packet capture access (Phantom Control / Wireshark)" \(group)
        fi
        dseditgroup -o edit -a "\(user)" -t user \(group) 2>/dev/null || true

        # 2. The boot-time re-applier.
        mkdir -p "\(supportDir)"
        cat > "\(supportDir)/ChmodBPF" <<'PC_BOOT_EOF'
        \(bootScript)
        PC_BOOT_EOF
        chown -R root:wheel "/Library/Application Support/Phantom Control"
        chmod 755 "\(supportDir)/ChmodBPF"

        cat > "\(plistPath)" <<'PC_PLIST_EOF'
        \(plist)
        PC_PLIST_EOF
        chown root:wheel "\(plistPath)"
        chmod 644 "\(plistPath)"

        launchctl bootout system "\(plistPath)" 2>/dev/null || true
        launchctl bootstrap system "\(plistPath)" 2>/dev/null || true

        # 3. Apply group access now (covers future logins), AND hand the current
        #    user direct ownership so the app running RIGHT NOW can open them —
        #    a live process cannot pick up a new group without a fresh login.
        for i in $(seq 0 15); do
            [ -e "/dev/bpf$i" ] || continue
            chgrp \(group) "/dev/bpf$i" 2>/dev/null || true
            chmod g+rw "/dev/bpf$i" 2>/dev/null || true
            chown "\(user)" "/dev/bpf$i" 2>/dev/null || true
        done
        exit 0
        """
    }

    /// Removes everything `enableScript` installed and restores stock perms.
    static func disableScript() -> String {
        let user = NSUserName()
        return """
        #!/bin/sh
        launchctl bootout system "\(plistPath)" 2>/dev/null || true
        rm -f "\(plistPath)"
        rm -rf "/Library/Application Support/Phantom Control"
        # Leave the GROUP itself alone — deleting it would break Wireshark.
        dseditgroup -o edit -d "\(user)" -t user \(group) 2>/dev/null || true
        for i in $(seq 0 15); do
            [ -e "/dev/bpf$i" ] || continue
            chown root "/dev/bpf$i" 2>/dev/null || true
            chgrp wheel "/dev/bpf$i" 2>/dev/null || true
            chmod 600 "/dev/bpf$i" 2>/dev/null || true
        done
        exit 0
        """
    }

    /// True if our boot-time daemon is installed (so the UI can offer Disable).
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Prompts for admin rights once and runs `script`. Mirrors
    /// `FieldHotspot.runAdmin`, with its own temp file so the two can't collide.
    @discardableResult
    static func runAdmin(script: String, prompt: String) -> Bool {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("phantom_10g.sh")
        do { try script.write(toFile: path, atomically: true, encoding: .utf8) } catch { return false }
        let osa = "do shell script \"/bin/sh \\\"\(path)\\\"\" with administrator privileges with prompt \"\(prompt)\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", osa]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
        return p.terminationStatus == 0
    }

    static func enable() -> Bool {
        runAdmin(script: enableScript(),
                 prompt: "Phantom Control needs permission to turn on fast 10G downloads.")
    }

    static func disable() -> Bool {
        runAdmin(script: disableScript(),
                 prompt: "Phantom Control needs permission to turn off fast 10G downloads.")
    }
}
