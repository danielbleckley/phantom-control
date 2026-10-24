import Foundation
import PhantomCore
import ImageIO
import UniformTypeIdentifiers

// phantomctl — protocol test harness for Phantom cameras.
// Usage:
//   phantomctl discover
//   phantomctl [--host IP] info | cstats | getcam
//   phantomctl [--host IP] cmd "get defc.res"
//   phantomctl [--host IP] frame [/path/out.png]
//   phantomctl [--host IP] bench [frameCount]

var args = Array(CommandLine.arguments.dropFirst())
var host = "100.100.111.76"
if let i = args.firstIndex(of: "--host"), i + 1 < args.count {
    host = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// Bind the control socket to a specific NIC (IP_BOUND_IF) — needed to reach a device
// on a second adapter when two interfaces share the camera subnet (e.g. Flex on en7 +
// CineStation on the 10G en25, both on 100.100/16).
var boundIface: String? = nil
if let i = args.firstIndex(of: "--iface"), i + 1 < args.count {
    boundIface = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let verb = args.first ?? "info"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot create \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

switch verb {
case "discover":
    let cams = CameraConnection.discover()
    if cams.isEmpty { print("no cameras found") }
    for c in cams { print("\(c.host)  \(c.reply)  (\(c.protocolVersion), control port \(c.controlPort))") }

case "info", "cstats", "getcam":
    let cam = CameraConnection(host: host, boundInterface: boundIface)
    do {
        try cam.connect()
        let cmd = verb == "info" ? "get info" : (verb == "cstats" ? "cstats" : "get cam")
        print(try cam.command(cmd, timeout: 4.0))
    } catch { fail("\(error)") }

case "cmd":
    guard args.count >= 2 else { fail("usage: phantomctl cmd \"<command>\"") }
    let cam = CameraConnection(host: host, boundInterface: boundIface)
    do {
        try cam.connect()
        print(try cam.command(args[1], timeout: 4.0))
    } catch { fail("\(error)") }

case "cine-writetest":
    // cine-writetest <out.cine> [model] [hwver] — write a tiny 2-frame P10 cine with
    // KNOWN develop metadata so the SETUP patch offsets can be byte-verified without
    // a camera. model/hwver default to a Flex 4K so the run exercises the camera-
    // identity patch; passing the VEO4K donor's own string instead reproduces the
    // pre-fix bytes for an A/B diff.
    guard args.count >= 2 else { fail("usage: phantomctl cine-writetest <out.cine> [model] [hwver]") }
    do {
        let testModel = args.count >= 3 ? args[2] : "Phantom Flex4K"
        let testHwver = args.count >= 4 ? (Int(args[3]) ?? 0) : 135
        let meta = CineMetadata(
            width: 128, height: 32, frameRate: 1000, exposureNs: 990_000, serial: 28876,
            cfa: 3, firstImageNo: -2, totalFrames: 2, firstMovieImage: -2,
            triggerSecs: 1_784_156_888, triggerFrac: 0x77f1_0000,
            cameraModel: testModel, cameraVersion: testHwver, cineName: "writetest",
            wbRed: 1.3089, wbBlue: 1.6931,
            toneString: "EI800 0.037 0.100 0.082 0.200", toneKnown: true,
            calMatrix: [1.958, -0.516, 0.035, -0.129, 0.758, 0.578, -0.054, -0.553, 2.699])
        let w = try CineWriter(url: URL(fileURLWithPath: args[1]), meta: meta,
                               frameCount: 2, layout: .packed10)
        let fb = 128 * 32 * 10 / 8   // packed-10: 10 bits/px
        for _ in 0..<2 { try w.appendPackedFrame(Data(repeating: 0x40, count: fb)) }
        w.finish()
        print("wrote \(args[1])")
    } catch { fail("\(error)") }

case "cine-frame":
    // cine-frame <file.cine> <out.png> [frameIndex] — render a .cine frame through
    // OUR develop (Debayer16, same as the app/export) so we can diff vs a PCC proxy.
    guard args.count >= 3 else { fail("usage: phantomctl cine-frame <file.cine> <out.png> [frame]") }
    let cfIdx = args.count > 3 ? (Int(args[3]) ?? 0) : 0
    do {
        let reader = try CineReader(url: URL(fileURLWithPath: args[1]))
        let inf = reader.info
        let s = Debayer16.RenderSettings(info: inf)
        let frame = try reader.readFrame(cfIdx)
        guard let img = Debayer16.render(frame: frame, cfa: inf.cfa, settings: s) else { fail("render failed") }
        savePNG(img, to: args[2])
        print("rendered \(inf.width)x\(inf.height) frame \(cfIdx) → \(args[2])")
        print("  biComp=\(inf.biCompression) realBPP=\(inf.realBPP) blk16=\(inf.blackLevel16) wht16=\(inf.whiteLevel16) wbR=\(inf.wbGainRed) wbB=\(inf.wbGainBlue)")
    } catch { fail("\(error)") }

case "frame":
    // frame [out.png] [cine] [startFrame]
    let out = args.count >= 2 ? args[1] : "/tmp/phantomctl_frame.png"
    let cine = args.count >= 3 ? Int(args[2]) ?? -1 : -1
    let start = args.count >= 4 ? Int(args[3]) ?? 0 : 0
    let cam = CameraConnection(host: host)
    do {
        try cam.connect()
        try cam.startDataChannel()
        let t0 = Date()
        let frame = try cam.grabFrame(cine: cine, start: start)
        let dt = Date().timeIntervalSince(t0)
        let mbps = Double(frame.pixels.count) / dt / 1e6
        print("frame \(frame.width)x\(frame.height), \(frame.pixels.count) bytes in \(String(format: "%.3f", dt))s (\(String(format: "%.1f", mbps)) MB/s)")
        guard let img = Debayer.halfResBGRA(frame: frame, wb: .init(), gain: 1.3) else { fail("debayer failed") }
        savePNG(img, to: out)
        print("wrote \(out)")
    } catch { fail("\(error)") }

case "flashtest":
    // flashtest [takeIndex] — SAFELY probe how to read a CineMag flash frame.
    // Tries the current `fmt:flash` command and the `+ from:mag` variant, draining
    // properly either way (a refused img pushes no data, so it can't wedge).
    let idx = args.count >= 2 ? Int(args[1]) ?? 0 : 0
    let cam = CameraConnection(host: host)
    do {
        try cam.connect()
        try cam.startDataChannel()
        guard let r = PhantomProtocol.find("res", in: try cam.get("fc\(idx).res"))?.sizeValue else {
            fail("no fc\(idx).res — is a CineMag mounted with takes?")
        }
        let first = PhantomProtocol.find("firstfr", in: (try? cam.get("fc\(idx).firstfr")) ?? [:])?.intValue ?? 0
        let last = PhantomProtocol.find("lastfr", in: (try? cam.get("fc\(idx).lastfr")) ?? [:])?.intValue ?? 0
        let packed = r.width * r.height * 10 / 8
        print("fc\(idx): \(r.width)x\(r.height), frames \(first)…\(last), expect ~\(packed) B/frame")
        // Try every plausible syntax for reading ONE flash frame. First that
        // returns bytes is the winner. start:0 avoids the negative firstfr.
        let mid = first + (last - first) / 2
        let variants = [
            "cine:\(idx), start:\(first), cnt:1, fmt:266, from:mag",   // first frame of the take
            "cine:\(idx), start:\(mid), cnt:1, fmt:266, from:mag",     // mid frame (for the thumbnail)
            "cine:\(idx), start:\(first), cnt:1, fmt:flash, from:mag", // does fmt:flash + valid frame still break?
        ]
        for v in variants {
            do { let n = try cam.probeImg(v, expectBytes: packed)
                 print("  OK   {\(v)} → \(n) B") }
            catch { print("  FAIL {\(v)} → \(error)") }
        }
    } catch { fail("\(error)") }

case "bench":
    let n = args.count >= 2 ? Int(args[1]) ?? 20 : 20
    let cam = CameraConnection(host: host)
    do {
        try cam.connect()
        try cam.startDataChannel()
        _ = try cam.grabFrame() // warm up
        let t0 = Date()
        var bytes = 0
        for _ in 0..<n {
            let f = try cam.grabFrame()
            bytes += f.pixels.count
        }
        let dt = Date().timeIntervalSince(t0)
        print("\(n) frames, \(bytes) bytes in \(String(format: "%.2f", dt))s")
        print("\(String(format: "%.1f", Double(n) / dt)) fps, \(String(format: "%.1f", Double(bytes) / dt / 1e6)) MB/s")
    } catch { fail("\(error)") }

case "download":
    // download <cine#> <out.cine> [first last]
    guard args.count >= 3, let cineNo = Int(args[1]) else {
        fail("usage: phantomctl download <cine#> <out.cine> [first last]")
    }
    let out = URL(fileURLWithPath: args[2])
    let forceTCP = args.contains("--tcp")     // bypass the ximg fast path
    let cam = CameraConnection(host: host)
    do {
        try cam.connect()
        try cam.startDataChannel()
        let info = try cam.get("info")
        let c = try cam.get("c\(cineNo)")
        guard let res = PhantomProtocol.find("res", in: c)?.sizeValue else { fail("no res for c\(cineNo)") }
        let firstfr = PhantomProtocol.find("firstfr", in: c)?.intValue ?? 0
        let lastfr = PhantomProtocol.find("lastfr", in: c)?.intValue ?? 0
        let posArgs = args.filter { !$0.hasPrefix("--") }
        let first = posArgs.count >= 5 ? Int(posArgs[3]) ?? firstfr : firstfr
        let last = posArgs.count >= 5 ? Int(posArgs[4]) ?? lastfr : lastfr
        let meta = CineMetadata(
            width: res.width, height: res.height,
            frameRate: PhantomProtocol.find("rate", in: c)?.intValue ?? 24,
            exposureNs: PhantomProtocol.find("exp", in: c)?.intValue ?? 0,
            serial: PhantomProtocol.find("serial", in: info)?.intValue ?? 0,
            cfa: PhantomProtocol.find("cfa", in: info)?.intValue ?? 3,
            firstImageNo: first,
            totalFrames: PhantomProtocol.find("frcount", in: c)?.intValue ?? (last - first + 1),
            firstMovieImage: firstfr,
            triggerSecs: UInt32(PhantomProtocol.find("secs", in: c)?.intValue ?? 0),
            triggerFrac: UInt32(PhantomProtocol.find("frac", in: c)?.intValue ?? 0),
            postTrigger: 0,
            cameraModel: PhantomProtocol.find("model", in: info)?.stringValue ?? "Phantom",
            cameraVersion: PhantomProtocol.find("hwver", in: info)?.intValue ?? 0,
            cineName: out.deletingPathExtension().lastPathComponent)
        print("downloading c\(cineNo) frames \(first)...\(last) (\(last-first+1) frames, \(res.width)x\(res.height))")
        let t0 = Date()
        try cam.downloadCine(cine: cineNo, to: out, meta: meta, firstFrame: first, lastFrame: last,
                             useXimg: forceTCP ? false : nil) { done, total in
            if done % 64 == 0 || done == total {
                let mbps = Double(done * res.width * res.height * 2) / Date().timeIntervalSince(t0) / 1e6
                print("  \(done)/\(total)  (\(String(format: "%.1f", mbps)) MB/s)")
            }
        }
        let dt = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print("wrote \(out.path): \(size ?? 0) bytes in \(String(format: "%.1f", dt))s")
    } catch { fail("\(error)") }

case "cine-info":
    // cine-info <file.cine>
    guard args.count >= 2 else { fail("usage: phantomctl cine-info <file.cine>") }
    do {
        let reader = try CineReader(url: URL(fileURLWithPath: args[1]))
        let i = reader.info
        print("\(i.width)x\(i.height), \(i.frameCount) frames, version \(i.version)")
        let comp = i.biCompression == 0 ? "raw 16-bit" : (i.biCompression == 256 ? "10-bit packed" : "12-bit packed (12L)")
        print("pixel format: \(comp), \(i.realBPP)-bit, CFA \(i.cfa) (\(i.isColor ? "color" : "mono"))")
        print("recorded \(i.frameRate) fps, plays \(i.playbackFPS) fps (\(String(format: "%.2f", i.durationSeconds))s)")
        print("black/white \(i.blackLevel16 >> (16 - i.realBPP))/\(i.whiteLevel16 >> (16 - i.realBPP)), WB R \(i.wbGainRed) B \(i.wbGainBlue)")
        print("camera: \(i.cameraModel.isEmpty ? "?" : i.cameraModel) serial \(i.serial), first image \(i.firstImageNo)")
    } catch { fail("\(error)") }

case "cine-frame":
    // cine-frame <file.cine> [frameIndex] [out.png]
    guard args.count >= 2 else { fail("usage: phantomctl cine-frame <file.cine> [frame] [out.png]") }
    let idx = args.count >= 3 ? Int(args[2]) ?? 0 : 0
    let out = args.count >= 4 ? args[3] : "/tmp/cine_frame.png"
    do {
        let reader = try CineReader(url: URL(fileURLWithPath: args[1]))
        let t0 = Date()
        let frame = try reader.readFrame(idx)
        let tRead = Date().timeIntervalSince(t0)
        var settings = Debayer16.RenderSettings(info: reader.info)
        if let wb = Debayer16.autoWhiteBalance(frame: frame, cfa: reader.info.cfa,
                                               blackLevel16: reader.info.blackLevel16) {
            settings.wbRed = wb.red; settings.wbBlue = wb.blue
        }
        let t1 = Date()
        guard let img = Debayer16.render(frame: frame, cfa: reader.info.cfa, settings: settings) else {
            fail("debayer failed")
        }
        let tRender = Date().timeIntervalSince(t1)
        savePNG(img, to: out)
        print("frame \(idx): read \(String(format: "%.1f", tRead*1000))ms, render \(String(format: "%.1f", tRender*1000))ms")
        print("wrote \(out)")
    } catch { fail("\(error)") }

case "cine-dump":
    // cine-dump <file.cine> <frameIndex> <out.raw> — decoded u16 LE, top-down,
    // left-justified 16-bit; for cross-checking against pycine.
    guard args.count >= 4, let idx = Int(args[2]) else {
        fail("usage: phantomctl cine-dump <file.cine> <frame> <out.raw>")
    }
    do {
        let reader = try CineReader(url: URL(fileURLWithPath: args[1]))
        let frame = try reader.readFrame(idx)
        var data = Data(capacity: frame.pixels.count * 2)
        frame.pixels.withUnsafeBufferPointer { buf in
            for v in buf { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        }
        try data.write(to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3]): \(data.count) bytes (\(frame.width)x\(frame.height) u16)")
    } catch { fail("\(error)") }

case "cine-transcode":
    // cine-transcode <file.cine> [out.mov] [--codec proreshq|prores|proreslt|h264] [--fps N] [--frames a-b]
    guard args.count >= 2 else {
        fail("usage: phantomctl cine-transcode <file.cine> [out.mov] [--codec proreshq|prores|proreslt|h264] [--fps N] [--frames a-b]")
    }
    let inURL = URL(fileURLWithPath: args[1])
    var rest = Array(args.dropFirst(2))
    var codec = CineTranscoder.Codec.proRes422HQ
    var fps = 0.0
    var firstFrame = 0, lastFrame = Int.max
    if let i = rest.firstIndex(of: "--codec"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "proreshq", "hq": codec = .proRes422HQ
        case "prores", "422": codec = .proRes422
        case "proreslt", "lt": codec = .proRes422LT
        case "h264", "h.264": codec = .h264
        default: fail("unknown codec \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--fps"), i + 1 < rest.count {
        fps = Double(rest[i + 1]) ?? 0
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--frames"), i + 1 < rest.count {
        let parts = rest[i + 1].split(separator: "-")
        if parts.count == 2 { firstFrame = Int(parts[0]) ?? 0; lastFrame = Int(parts[1]) ?? .max }
        rest.removeSubrange(i...(i + 1))
    }
    let outURL = rest.first.map { URL(fileURLWithPath: $0) }
        ?? inURL.deletingPathExtension().appendingPathExtension("mov")
    do {
        let reader = try CineReader(url: inURL)
        let frame0 = try reader.readFrame(max(firstFrame, 0))
        var settings = Debayer16.RenderSettings(info: reader.info)
        if let wb = Debayer16.autoWhiteBalance(frame: frame0, cfa: reader.info.cfa,
                                               blackLevel16: reader.info.blackLevel16) {
            settings.wbRed = wb.red; settings.wbBlue = wb.blue
        }
        let options = CineTranscoder.Options(codec: codec, fps: fps,
                                             firstFrame: firstFrame, lastFrame: lastFrame,
                                             settings: settings, info: reader.info)
        print("transcoding \(reader.info.width)x\(reader.info.height) frames \(options.firstFrame)...\(options.lastFrame) → \(codec.rawValue) @ \(options.fps) fps")
        let t0 = Date()
        var lastPct = -1
        try CineTranscoder(reader: reader).transcode(to: outURL, options: options) { p in
            let pct = Int(p * 100)
            if pct / 5 != lastPct / 5 {
                lastPct = pct
                print("  \(pct)%  (\(String(format: "%.1f", Double(p) * Double(options.lastFrame - options.firstFrame + 1) / max(Date().timeIntervalSince(t0), 0.001))) fps)")
            }
            return true
        }
        let dt = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
        print("wrote \(outURL.path): \(size) bytes in \(String(format: "%.1f", dt))s")
    } catch { fail("\(error)") }

case "ximg-nic":
    // ximg-nic — show the 10G interface auto-detected for the camera subnet.
    if let nic = XimgReceiver.autodetect(cameraIP: host) {
        let speed = nic.baudrate >= 1_000_000_000
            ? String(format: "%.0f Gbit/s", Double(nic.baudrate) / 1e9)
            : "\(nic.baudrate) bit/s"
        print("interface \(nic.name)  MAC \(nic.macHex)  link \(speed)  \(nic.isTenGig ? "(10G)" : "")")
    } else {
        print("no en* interface on the camera's subnet (\(host))")
    }

case "ximg-download":
    // ximg-download <cine#> <out.cine> <first> <last> [--throttle N] [--batch N] [--iface enX]
    guard args.count >= 5, let cineNo = Int(args[1]),
          let first = Int(args[3]), let last = Int(args[4]) else {
        fail("usage: phantomctl ximg-download <cine#> <out.cine> <first> <last> [--throttle N] [--batch N] [--iface enX]")
    }
    let out = URL(fileURLWithPath: args[2])
    var rest = Array(args.dropFirst(5))
    var throttle = 0, batch = 32
    var iface: String? = nil
    var flash = false     // --flash = CineMag take (fcN, fmt:flash) instead of RAM cine cN
    if let i = rest.firstIndex(of: "--throttle"), i + 1 < rest.count { throttle = Int(rest[i+1]) ?? 0; rest.removeSubrange(i...(i+1)) }
    if let i = rest.firstIndex(of: "--batch"), i + 1 < rest.count { batch = Int(rest[i+1]) ?? 32; rest.removeSubrange(i...(i+1)) }
    if let i = rest.firstIndex(of: "--iface"), i + 1 < rest.count { iface = rest[i+1]; rest.removeSubrange(i...(i+1)) }
    if let i = rest.firstIndex(of: "--flash") { flash = true; rest.remove(at: i) }

    guard let nic = iface.flatMap({ XimgReceiver.nic(named: $0) }) ?? XimgReceiver.autodetect(cameraIP: host) else {
        fail("no 10G interface found on the camera's subnet (\(host)); pass --iface enX")
    }
    let cam = CameraConnection(host: host, boundInterface: iface)
    do {
        try cam.connect()
        let info = try cam.get("info")
        let structName = flash ? "fc\(cineNo)" : "c\(cineNo)"
        let c = try cam.get(structName)
        guard let res = PhantomProtocol.find("res", in: c)?.sizeValue else { fail("no res for \(structName)") }
        let firstfr = PhantomProtocol.find("firstfr", in: c)?.intValue ?? 0
        let lastfr = PhantomProtocol.find("lastfr", in: c)?.intValue ?? 0
        if flash {
            // CineStation mag take: pin the in/out window and open the data
            // channel exactly like PCC before streaming fmt:flash.
            _ = try cam.command("set fc\(cineNo).in:\(firstfr)")
            _ = try cam.command("set fc\(cineNo).out:\(lastfr)")
            try cam.startDataChannel()
        }
        // ximg does NOT range-check on the camera — it streams garbage for
        // frames outside the cine. Refuse here instead.
        guard first >= firstfr, last <= lastfr, first <= last else {
            fail("range \(first)...\(last) outside cine c\(cineNo) (\(firstfr)...\(lastfr))")
        }
        // For a CineMag take the camera identity + develop (serial, cfa, model)
        // live in the fcN struct itself (the shooting camera), not in the
        // CineStation's own `info` (which has cfa:0 — it has no sensor).
        let devSrc = flash ? c : info
        let meta = CineMetadata(
            width: res.width, height: res.height,
            frameRate: PhantomProtocol.find("rate", in: c)?.intValue ?? 24,
            exposureNs: PhantomProtocol.find("exp", in: c)?.intValue ?? 0,
            serial: PhantomProtocol.find("serial", in: devSrc)?.intValue ?? 0,
            cfa: PhantomProtocol.find("cfa", in: devSrc)?.intValue ?? 3,
            firstImageNo: first,
            totalFrames: PhantomProtocol.find("frcount", in: c)?.intValue ?? (last - first + 1),
            firstMovieImage: firstfr,
            triggerSecs: UInt32(PhantomProtocol.find("secs", in: c)?.intValue ?? 0),
            triggerFrac: UInt32(PhantomProtocol.find("frac", in: c)?.intValue ?? 0),
            postTrigger: 0,
            cameraModel: PhantomProtocol.find("model", in: devSrc)?.stringValue ?? "Phantom",
            // devSrc, matching serial/cfa/model — the SHOOTING camera on a flash take,
            // never the CineStation (which has no sensor).
            cameraVersion: PhantomProtocol.find("hwver", in: devSrc)?.intValue ?? 0,
            cineName: out.deletingPathExtension().lastPathComponent)
        let count = last - first + 1
        let frameMB = Double(res.width * res.height * 10 / 8) / 1e6
        print("ximg c\(cineNo) frames \(first)...\(last) (\(count) frames, \(res.width)x\(res.height), \(String(format: "%.1f", frameMB)) MB/frame)")
        print("  via \(nic.name) MAC \(nic.macHex) (link \(String(format: "%.0f", Double(nic.baudrate)/1e9)) Gbit/s), throttle \(throttle)%, batch \(batch)")
        let t0 = Date()
        try cam.downloadCineXimg(cine: cineNo, to: out, meta: meta,
                                 firstFrame: first, lastFrame: last,
                                 nic: nic, batchSize: batch, throttlePercent: throttle, flash: flash) { done, total in
            if done % batch == 0 || done == total {
                let mbps = Double(done) * frameMB / Date().timeIntervalSince(t0)
                print("  \(done)/\(total)  (\(String(format: "%.1f", mbps)) MB/s)")
            }
        }
        let dt = Date().timeIntervalSince(t0)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int).flatMap { $0 } ?? 0
        let mbps = Double(size) / dt / 1e6
        print("wrote \(out.path): \(size) bytes in \(String(format: "%.1f", dt))s (\(String(format: "%.0f", mbps)) MB/s to disk)")
    } catch { fail("\(error)") }

case "mag-download":
    // mag-download <fcN> <out.cine> [first last] — CAMERA CineMag take over TCP
    // img fmt:flash (no CineStation / 10G needed).
    guard args.count >= 3, let take = Int(args[1]) else {
        fail("usage: phantomctl [--host IP] mag-download <fcN> <out.cine> [first last]")
    }
    let out = URL(fileURLWithPath: args[2])
    let cam = CameraConnection(host: host)
    do {
        try cam.connect()
        try cam.startDataChannel()
        let fc = try cam.get("fc\(take)")
        guard let res = PhantomProtocol.find("res", in: fc)?.sizeValue else { fail("no res for fc\(take)") }
        let firstfr = PhantomProtocol.find("firstfr", in: fc)?.intValue ?? 0
        let lastfr = PhantomProtocol.find("lastfr", in: fc)?.intValue ?? 0
        let first = args.count >= 5 ? (Int(args[3]) ?? firstfr) : firstfr
        let last = args.count >= 5 ? (Int(args[4]) ?? lastfr) : lastfr
        let meta = CineMetadata(
            width: res.width, height: res.height,
            frameRate: PhantomProtocol.find("rate", in: fc)?.intValue ?? 24,
            exposureNs: PhantomProtocol.find("exp", in: fc)?.intValue ?? 0,
            serial: PhantomProtocol.find("serial", in: fc)?.intValue ?? 0,
            cfa: PhantomProtocol.find("cfa", in: fc)?.intValue ?? 3,
            firstImageNo: first, totalFrames: last - first + 1, firstMovieImage: first,
            cameraModel: PhantomProtocol.find("model", in: fc)?.stringValue ?? "Phantom",
            // From the take struct — the camera that shot it, not the connected body.
            cameraVersion: PhantomProtocol.find("hwver", in: fc)?.intValue ?? 0,
            cineName: out.deletingPathExtension().lastPathComponent)
        print("mag take fc\(take): \(res.width)x\(res.height) frames \(first)…\(last) (\(last-first+1))")
        let t0 = Date()
        try cam.downloadMagCine(cine: take, to: out, meta: meta, firstFrame: first, lastFrame: last) { done, total in
            if done % 12 == 0 || done == total {
                let mb = Double(done * res.width * res.height) * 1.25 / Date().timeIntervalSince(t0) / 1e6
                print("  \(done)/\(total)  (\(String(format: "%.0f", mb)) MB/s)")
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int).flatMap { $0 } ?? 0
        print("wrote \(out.path): \(size) bytes")
    } catch { fail("\(error)") }

case "writetest":
    // writetest <out.cine> [w h frames] — writes packed10 cine via CineWriter
    // (gray frames) to validate the header/template independent of a camera.
    let out = args.count >= 2 ? args[1] : "/tmp/writetest.cine"
    let w = args.count >= 5 ? Int(args[2]) ?? 4096 : 4096
    let h = args.count >= 5 ? Int(args[3]) ?? 2304 : 2304
    let n = args.count >= 5 ? Int(args[4]) ?? 3 : 3
    let meta = CineMetadata(width: w, height: h, frameRate: 938, exposureNs: 500000,
                            serial: 25593, cfa: 3, firstImageNo: 0, totalFrames: n,
                            firstMovieImage: 0, cameraModel: "Phantom VEO4K PL RLS", cineName: "writetest")
    do {
        let writer = try CineWriter(url: URL(fileURLWithPath: out), meta: meta, frameCount: n, layout: .packed10)
        let frameBytes = (w * h * 10 + 7) / 8
        let gray = Data(repeating: 0x80, count: frameBytes)
        for _ in 0..<n { try writer.appendPackedFrame(gray) }
        writer.finish()
        print("wrote \(out)")
    } catch { fail("\(error)") }

case "gpu-transcode":
    // gpu-transcode <file.cine> [out.mov] [--codec proreshq|prores|proreslt|proxy|h264|hevc] [--fps N] [--frames a-b]
    // GPU debayer + hardware ProRes encode — validation harness for GPUTranscoder.
    guard args.count >= 2 else {
        fail("usage: phantomctl gpu-transcode <file.cine> [out.mov] [--codec ...] [--fps N] [--frames a-b]")
    }
    let inURL = URL(fileURLWithPath: args[1])
    var rest = Array(args.dropFirst(2))
    var codec = GPUTranscoder.Codec.proRes422HQ
    var fps = 0.0
    var firstFrame = 0, lastFrame = Int.max
    if let i = rest.firstIndex(of: "--codec"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "proreshq", "hq": codec = .proRes422HQ
        case "prores", "422": codec = .proRes422
        case "proreslt", "lt": codec = .proRes422LT
        case "proxy": codec = .proResProxy
        case "h264", "h.264": codec = .h264
        case "hevc": codec = .hevc
        default: fail("unknown codec \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--fps"), i + 1 < rest.count {
        fps = Double(rest[i + 1]) ?? 0
        rest.removeSubrange(i...(i + 1))
    }
    var resolution = GPUTranscoder.Resolution.full
    var quality = GPUTranscoder.Quality.balanced
    if let i = rest.firstIndex(of: "--res"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "full": resolution = .full
        case "2160", "2160p", "4k": resolution = .uhd2160
        case "1080", "1080p", "hd": resolution = .hd1080
        case "720", "720p": resolution = .hd720
        default: fail("unknown res \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--quality"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "small": quality = .small
        case "balanced": quality = .balanced
        case "high": quality = .high
        default: fail("unknown quality \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--frames"), i + 1 < rest.count {
        let parts = rest[i + 1].split(separator: "-")
        if parts.count == 2 { firstFrame = Int(parts[0]) ?? 0; lastFrame = Int(parts[1]) ?? .max }
        rest.removeSubrange(i...(i + 1))
    }
    let outURL = rest.first.map { URL(fileURLWithPath: $0) }
        ?? inURL.deletingPathExtension().appendingPathExtension("mov")
    do {
        let reader = try CineReader(url: inURL)
        let frame0 = try reader.readFrame(max(firstFrame, 0))
        // --neutral = the DaVinci-like gradeable Rec.709 delivery look.
        var settings = args.contains("--neutral")
            ? Debayer16.RenderSettings.neutralRec709(info: reader.info)
            : Debayer16.RenderSettings(info: reader.info)
        if !args.contains("--neutral"),
           let wb = Debayer16.autoWhiteBalance(frame: frame0, cfa: reader.info.cfa,
                                               blackLevel16: reader.info.blackLevel16) {
            settings.wbRed = wb.red; settings.wbBlue = wb.blue
        }
        if let i = rest.firstIndex(of: "--rotate"), i + 1 < rest.count {
            ExportRotation.current = Int(rest[i + 1]) ?? 0   // vertical-mode bake test
        }
        let options = GPUTranscoder.Options(codec: codec, fps: fps,
                                            firstFrame: firstFrame, lastFrame: lastFrame,
                                            settings: settings, resolution: resolution,
                                            quality: quality, info: reader.info)
        print("output \(options.outputWidth)x\(options.outputHeight), quality \(quality.rawValue)")
        let hw = GPUTranscoder.hardwareEncoder(for: codec)
        print("GPU transcode \(reader.info.width)x\(reader.info.height) frames \(options.firstFrame)...\(options.lastFrame) → \(codec.rawValue) @ \(options.fps) fps")
        print("encoder: \(hw.name) (\(hw.available ? "HARDWARE" : "software"))")
        var lastPct = -1
        let result = try GPUTranscoder(reader: reader).transcode(to: outURL, options: options) { p in
            let pct = Int(p.fraction * 100)
            if pct / 5 != lastPct / 5 {
                lastPct = pct
                print("  \(pct)%  \(String(format: "%.1f", p.fps)) fps  \(String(format: "%.0f", p.mbPerSec)) MB/s")
            }
            return true
        }
        print("done: \(result.frames) frames in \(String(format: "%.1f", result.seconds))s = \(String(format: "%.1f", result.fps)) fps, \(String(format: "%.0f", result.mbPerSec)) MB/s read")
        print("wrote \(outURL.path): \(result.outputBytes) bytes, encoder \(result.encoderName) (\(result.hardwareEncoder ? "HARDWARE" : "software"))")
    } catch { fail("\(error)") }

case "gpu-stitch":
    // gpu-stitch <out.mov> <a.cine> <b.cine> ... [--codec ...] [--res ...] [--quality ...]
    // Concatenates many cines into one back-to-back timeline (review string).
    guard args.count >= 3 else {
        fail("usage: phantomctl gpu-stitch <out.mov> <a.cine> <b.cine> ... [--codec ...] [--res ...] [--quality ...]")
    }
    var rest = Array(args.dropFirst(1))
    var codec = GPUTranscoder.Codec.h264
    var resolution = GPUTranscoder.Resolution.hd1080
    var quality = GPUTranscoder.Quality.balanced
    if let i = rest.firstIndex(of: "--codec"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "proreshq", "hq": codec = .proRes422HQ
        case "prores", "422": codec = .proRes422
        case "proreslt", "lt": codec = .proRes422LT
        case "proxy": codec = .proResProxy
        case "h264", "h.264": codec = .h264
        case "hevc": codec = .hevc
        default: fail("unknown codec \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--res"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "full": resolution = .full
        case "2160", "2160p", "4k": resolution = .uhd2160
        case "1080", "1080p", "hd": resolution = .hd1080
        case "720", "720p": resolution = .hd720
        default: fail("unknown res \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    if let i = rest.firstIndex(of: "--quality"), i + 1 < rest.count {
        switch rest[i + 1].lowercased() {
        case "small": quality = .small
        case "balanced": quality = .balanced
        case "high": quality = .high
        default: fail("unknown quality \(rest[i + 1])")
        }
        rest.removeSubrange(i...(i + 1))
    }
    let outURL = URL(fileURLWithPath: rest[0])
    let inputs = rest.dropFirst().map { path -> GPUTranscoder.StitchInput in
        let url = URL(fileURLWithPath: path)
        let n = (try? CineReader(url: url).info.frameCount) ?? 1
        return GPUTranscoder.StitchInput(url: url, firstFrame: 0, lastFrame: n - 1)
    }
    guard !inputs.isEmpty else { fail("no input cines") }
    do {
        print("stitching \(inputs.count) clips → \(codec.rawValue) \(resolution.rawValue)")
        var lastPct = -1
        let result = try GPUTranscoder.transcodeStitched(inputs: inputs, to: outURL,
                                                          codec: codec, fps: 0,
                                                          quality: quality, resolution: resolution) { p in
            let pct = Int(p.fraction * 100)
            if pct / 10 != lastPct / 10 { lastPct = pct; print("  \(pct)%  \(String(format: "%.1f", p.fps)) fps") }
            return true
        }
        print("wrote \(outURL.path): \(result.frames) frames in \(String(format: "%.1f", result.seconds))s, \(result.outputBytes) bytes, \(result.hardwareEncoder ? "HARDWARE" : "software")")
    } catch { fail("\(error)") }

default:
    fail("unknown verb \(verb)")
}
