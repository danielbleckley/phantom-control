import Foundation
import Darwin
import SystemConfiguration

/// What a remote request produced. Built on the main actor by CameraModel,
/// written back to the socket by the server thread.
struct RemoteResponse {
    var status: Int = 200
    var contentType: String = "text/plain; charset=utf-8"
    var body: String = "ok"
    /// Binary payload (e.g. a JPEG SDI frame). When set, it's sent instead of `body`.
    var bodyData: Data? = nil
    var extraHeaders: [String: String] = [:]
}

/// Tiny HTTP server on port 8989, bound to all interfaces, so both a Stream
/// Deck on this Mac and a phone on the same WiFi can drive the app.
///
/// Security model: requests from other machines must prefix the path with a
/// secret token — http://<mac-ip>:8989/<token>/trigger — which also serves a
/// mobile web remote at http://<mac-ip>:8989/<token>/. Connections from
/// localhost skip the token, so existing Stream Deck "Website" actions
/// pointing at http://127.0.0.1:8989/trigger keep working.
/// Endpoints: / /status /frame(JPEG) /stream(MJPEG video) /trigger /capture
/// /live /play /pause /proxy /download /seek/<frame> /markin /markout
/// /resetinout /selectcine/<n> /rate/<n> /shutter/<deg> /res/<w>/<h>
/// /preset/<name> /autosave[/on|/off] /partitions/<n> /clearram /blackref /wb
final class RemoteControl {
    let port: UInt16
    private var fd: Int32 = -1
    private let token: String
    private let responder: (String) -> RemoteResponse
    /// Supplies the latest viewer frame as JPEG for the live MJPEG stream.
    private let frameProvider: (() -> Data?)?

    init(port: UInt16 = 8989, token: String,
         responder: @escaping (String) -> RemoteResponse,
         frameProvider: (() -> Data?)? = nil) {
        self.port = port
        self.token = token
        self.responder = responder
        self.frameProvider = frameProvider
    }

    func start() {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); fd = -1; return }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while fd >= 0 {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &peerLen)
                }
            }
            guard client >= 0 else { continue }
            let isLoopback = peer.sin_addr.s_addr == in_addr_t(0x7F000001).bigEndian
            // One thread per connection: the live video stream holds its socket
            // open indefinitely, so it must not block status polls or commands.
            Thread.detachNewThread { [weak self] in self?.serve(client: client, isLoopback: isLoopback) }
        }
    }

    private func serve(client: Int32, isLoopback: Bool) {
        // A phone that drops mid-request must not wedge the thread or SIGPIPE
        // the app; a slow/gone client must not block a send forever.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var rtv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buf, buf.count, 0)
        if n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8),
           let line = req.split(separator: "\r\n").first {
            // "GET /trigger HTTP/1.1"
            let parts = line.split(separator: " ")
            if parts.count >= 2 {
                let raw = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                if frameProvider != nil, streamPath(raw, isLoopback: isLoopback) {
                    streamMJPEG(to: client)
                } else {
                    write(route(raw, isLoopback: isLoopback), to: client)
                }
            }
        }
        Darwin.close(client)
    }


    /// True if the (token-stripped) path is the MJPEG stream request.
    private func streamPath(_ rawPath: String, isLoopback: Bool) -> Bool {
        var path = rawPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let prefix = "/" + token
        if path.hasPrefix(prefix + "/") { path = String(path.dropFirst(prefix.count)) }
        else if !isLoopback { return false }
        return path == "/stream"
    }

    /// Holds the connection open and pushes JPEG frames as a multipart stream —
    /// `<img>`/fetch on the phone renders it as live video. Loops until the
    /// client disconnects (a send fails) or the server stops.
    private func streamMJPEG(to client: Int32) {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=phantomframe\r\n"
            + "Cache-Control: no-store\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        guard sendAll(client, Array(head.utf8)) else { return }
        while fd >= 0 {
            let jpeg = DispatchQueue.main.sync { self.frameProvider?() }
            guard let jpeg else { usleep(60_000); continue }
            let partHead = "--phantomframe\r\nContent-Type: image/jpeg\r\n"
                + "Content-Length: \(jpeg.count)\r\n\r\n"
            if !sendAll(client, Array(partHead.utf8)) { break }
            if !sendAll(client, [UInt8](jpeg)) { break }
            if !sendAll(client, [13, 10]) { break }
            usleep(50_000)   // ~20 fps ceiling
        }
    }

    @discardableResult
    private func sendAll(_ client: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(client, raw.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func route(_ rawPath: String, isLoopback: Bool) -> RemoteResponse {
        var path = rawPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let prefix = "/" + token
        if path.hasPrefix(prefix + "/") {
            path = String(path.dropFirst(prefix.count))
        } else if path == prefix {
            // Redirect so the page's relative fetches keep the token prefix.
            return RemoteResponse(status: 302, body: "", extraHeaders: ["Location": prefix + "/"])
        } else if !isLoopback {
            return RemoteResponse(status: 403, body: "forbidden")
        }
        if path == "/" || path.isEmpty {
            return RemoteResponse(contentType: "text/html; charset=utf-8", body: Self.remotePage)
        }
        if path == "/favicon.ico" { return RemoteResponse(status: 404, body: "") }
        // Camera state lives on the main actor; the model's handler runs there.
        return DispatchQueue.main.sync { responder(path) }
    }

    private func write(_ resp: RemoteResponse, to client: Int32) {
        let statusText: String
        switch resp.status {
        case 200: statusText = "OK"
        case 302: statusText = "Found"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Status"
        }
        let body: [UInt8] = resp.bodyData.map { Array($0) } ?? Array(resp.body.utf8)
        var head = "HTTP/1.1 \(resp.status) \(statusText)\r\n"
            + "Content-Type: \(resp.contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
        for (k, v) in resp.extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        sendAll(client, Array(head.utf8) + body)
    }

    func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// The Mac's Bonjour/mDNS name ("Daniels-MacBook.local") — resolves on any
    /// LAN regardless of what DHCP handed out, so phone bookmarks stay valid
    /// across networks and reboots.
    static func bonjourHostname() -> String? {
        guard let n = SCDynamicStoreCopyLocalHostName(nil) as String?, !n.isEmpty else { return nil }
        return "\(n).local"
    }

    /// The Mac's IPv4 on the local network — what to type on the phone.
    /// Prefers en0 (WiFi on laptops) so we don't hand out the camera-link IP.
    static func lanIPAddress() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var bestEn: String?
        var any: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            let name = String(cString: ifa.ifa_name)
            if name == "en0" { return ip }
            if bestEn == nil, name.hasPrefix("en") { bestEn = ip }
            if any == nil { any = ip }
        }
        return bestEn ?? any
    }

    /// Every usable IPv4 the Mac has (skips loopback, link-local, and the
    /// camera-link 10G/100.100/172.16 subnets). Used to offer fallback phone
    /// URLs when the Mac is on more than one network.
    static func lanIPCandidates() -> [String] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        var out: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254."),          // link-local
                  !ip.hasPrefix("100.100."),          // Flex camera link
                  !ip.hasPrefix("172.16.") else { continue }   // VEO camera link
            if !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    /// The phone remote: one self-contained page, no external resources.
    /// All fetches are relative so they inherit the /<token>/ prefix.
    private static let remotePage = #"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<link rel="apple-touch-icon" href="appicon">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Phantom">
<title>Phantom Remote</title>
<style>
:root{color-scheme:dark;--gold:#d8a526;--green:#1d7a3e;--blue:#0a84ff;--card:#1b1b20;--card2:#26262c}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none}
html,body{margin:0;background:#0a0a0c;color:#eee;font-family:-apple-system,system-ui,sans-serif}
/* top header — fixed */
.hdr{position:fixed;top:0;left:0;right:0;z-index:20;display:flex;align-items:center;gap:8px;
 padding:max(10px,env(safe-area-inset-top)) 14px 10px;background:rgba(12,12,15,.92);
 backdrop-filter:blur(12px);border-bottom:1px solid #1f1f25}
.dot{width:11px;height:11px;border-radius:50%;background:#555;flex:none}
.dot.on{background:#34c759}.dot.off{background:#ff3b30}
.title{font-weight:600;font-size:16px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.temps{font-size:12px;color:#999;font-variant-numeric:tabular-nums;white-space:nowrap}
/* scroll area between header and tab bar */
.scroll{padding:0 14px;padding-top:calc(52px + env(safe-area-inset-top));
 padding-bottom:calc(78px + env(safe-area-inset-bottom));max-width:520px;margin:0 auto}
.tab{display:none}.tab.show{display:block}
.hint{font-size:11px;color:#777;margin:12px 0 4px}
/* partition strip */
.strip{display:flex;gap:6px;margin:8px 0 4px;flex-wrap:wrap}
.slot{position:relative;flex:1 1 0;min-width:52px;height:50px;border-radius:9px;display:flex;
 flex-direction:column;align-items:center;justify-content:center;font-size:13px;font-weight:700;color:#fff;background:#333}
.slot small{font-weight:500;font-size:10px;opacity:.85;text-transform:uppercase;letter-spacing:.5px}
.slot.sel{outline:3px solid #fff;outline-offset:-1px}
.slot.dim{opacity:.45}
.savemark{position:absolute;top:3px;right:5px;font-size:11px;font-weight:900;line-height:1}
.savemark.ok{color:#bdf0bd}
.savemark.warn{color:#ffd24a}
/* buttons */
button{border:none;border-radius:14px;color:#fff;font-weight:800;font-family:inherit;cursor:pointer;
 touch-action:manipulation}
button:active{filter:brightness(1.4)}
button:disabled{opacity:.4}
/* live SDI preview */
.preview{position:relative;width:100%;aspect-ratio:16/9;background:#000;border-radius:12px;
 overflow:hidden;margin:4px 0 2px;border:1px solid #222}
.preview img{width:100%;height:100%;object-fit:contain;display:block;opacity:0;transition:opacity .15s}
.preview.live img{opacity:1}
.preview canvas{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:none}
.preview .ovlay{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:none;pointer-events:none;z-index:2}
body.h264 .preview img{display:none}
body.h264 .preview canvas{display:block}
.previewoff{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;
 justify-content:center;color:#666;font-size:13px;text-align:center;gap:5px;padding:0 20px}
.preview.live .previewoff{display:none}
.trigger{width:100%;height:150px;margin:10px 0;font-size:36px;letter-spacing:3px;
 background:#c1121f;box-shadow:0 6px 28px rgba(220,20,40,.35)}
.trigger.rec{animation:pulse 1s infinite}
@keyframes pulse{0%,100%{filter:brightness(1)}50%{filter:brightness(1.7)}}
.row{display:flex;gap:10px;margin:10px 0}
.row button{flex:1;height:62px;font-size:17px;background:var(--card2)}
.row button.active{background:var(--blue)}
.golive{background:#3a2a14!important;color:#f0c674}
/* settings rows */
h3{font-size:12px;text-transform:uppercase;letter-spacing:1px;color:#888;margin:20px 0 8px}
.setrow{display:flex;align-items:center;gap:10px;margin:8px 0}
.setrow label{width:96px;font-size:14px;color:#aaa}
.setrow select{flex:1;height:50px;border-radius:12px;background:var(--card2);color:#fff;
 border:none;font-size:17px;font-family:inherit;padding:0 12px;font-weight:600}
.mini{flex:none;height:50px;padding:0 14px;font-size:14px;font-weight:700;background:var(--card2)}
.presets{display:flex;flex-wrap:wrap;gap:8px}
.presets button{height:48px;padding:0 18px;font-size:15px;font-weight:600;background:var(--card2)}
.presets .none{color:#666;font-size:13px}
.wide{width:100%;height:46px;font-size:15px;font-weight:700;background:var(--card2)}
.wide.on{background:var(--green)}
.wide.danger{background:#3a1518;color:#ff6b6b;border:1px solid #5a2025}
.stopstore{background:#1d7a3e;color:#fff;animation:pulse 1.2s infinite}
/* trigger-position segmented control (LIVE tab) */
.trigpos{margin:10px 0}
.tphdr{font-size:12px;color:#8a8a92;margin:0 2px 6px}
.tprow{display:flex;gap:8px}
.tprow button{flex:1;height:54px;font-size:15px;font-weight:700;background:var(--card2);
 display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;line-height:1.1}
.tprow button small{font-size:11px;font-weight:500;color:#8a8a92}
.tprow button.on{background:var(--gold);color:#1a1400}
.tprow button.on small{color:#4a3a00}
.savebtn.mag{background:#4a2f7a}
/* MONITOR tab */
.mongrid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin:2px 0 4px}
.montog{height:56px;font-size:15px;background:var(--card2);border-radius:14px}
.montog.on{background:var(--blue)}
.gallery{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin:6px 0}
.gallery img{width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:8px;border:2px solid transparent;background:#000}
.gallery img.sel{border-color:var(--blue)}
.gallery .none{grid-column:1/-1;color:#666;font-size:12px;text-align:center;padding:10px}
.rv{min-width:44px;text-align:right;color:#9a9aa2;font-size:13px;font-variant-numeric:tabular-nums}
.setrow input[type=range]{flex:1}
.gdrow{display:flex;align-items:center;gap:8px;background:var(--card2);border-radius:12px;padding:6px 8px;margin:6px 0}
.gdrow .nm{width:62px;font-weight:700;font-size:14px}
.gdrow input[type=range]{flex:1}
.gdrow button{height:38px;padding:0 12px;font-size:14px;background:#2a2a30;border-radius:10px}
.gdrow .eye.on{background:var(--blue)}
.gdrow .rm{background:#3a1518;color:#ff6b6b}
/* collapsible sections */
details.sect{border-top:1px solid #1f1f25}
details.sect>summary{list-style:none;cursor:pointer;font-size:12px;text-transform:uppercase;letter-spacing:1px;
 color:#9a9aa2;margin:0;padding:14px 2px 10px;display:flex;align-items:center;gap:9px;font-weight:700}
details.sect>summary::-webkit-details-marker{display:none}
details.sect>summary::before{content:'▸';font-size:11px;color:#666;transition:transform .15s}
details.sect[open]>summary::before{transform:rotate(90deg)}
/* iPad / wide screens: use the room */
@media (min-width:680px){
 .scroll{max-width:900px}
 .mongrid{grid-template-columns:repeat(3,1fr)}
 .gallery{grid-template-columns:repeat(5,1fr)}
 /* iPad: keep the video pinned while the controls scroll under it */
 .preview{position:sticky;top:calc(54px + env(safe-area-inset-top));z-index:5}
}
/* landscape (phone landscape / iPad landscape): video locked on the left,
   controls scroll on the right — like a monitor with a side panel */
@media (orientation:landscape) and (min-width:640px){
 .hdr{padding:max(5px,env(safe-area-inset-top)) 14px 5px}
 .hdr .title{font-size:14px}.hdr .temps{font-size:11px}
 .scroll{max-width:none;margin:0;padding-right:14px;padding-bottom:14px;
  padding-left:calc(54vw + 22px);padding-top:calc(44px + env(safe-area-inset-top))}
 .tab.show>.preview{position:fixed;left:12px;z-index:6;width:52vw;max-width:none;margin:0;
  top:calc(46px + env(safe-area-inset-top));height:calc(52vw * 0.5625);bottom:auto;aspect-ratio:auto}
 .tab.show>.preview img{object-fit:contain}
 /* tab switcher tucked tight under the video */
 .tabbar{left:12px;right:auto;width:52vw;bottom:auto;border:1px solid #2a2a32;border-radius:12px;
  top:calc(46px + env(safe-area-inset-top) + 52vw * 0.5625 + 8px);height:auto;background:rgba(22,22,27,.92)}
 .tabbar button{height:40px;font-size:9px;gap:1px}
 .tabbar button .ic{font-size:15px}
 /* tighten the control column so more fits without scrolling */
 .transport,.markrow,.gotorow,.saverow,.row{margin:4px 0}
 .tl{margin:6px 0 2px}.markreadout{margin:1px 2px 4px}.playhdr{margin:5px 0 2px}
 h3,details.sect>summary{margin:0;padding:8px 2px 5px}
 .transport button{height:50px}.wide{height:42px}.strip{margin:5px 0 2px}
}
/* full-screen toggle button on each preview */
.fsbtn{position:absolute;top:8px;right:8px;z-index:6;width:42px;height:42px;border-radius:11px;
 background:rgba(16,16,20,.55);backdrop-filter:blur(6px);font-size:18px;color:#fff;border:1px solid rgba(255,255,255,.12)}
body.fs .fsbtn{display:none}
/* FULL-SCREEN VIDEO MODE */
body.fs .hdr,body.fs .tabbar{display:none}
body.fs .scroll{padding:0;max-width:none}
body.fs .tab.show>*{display:none}
body.fs .tab.show>.preview{display:block;position:fixed;inset:0;width:100vw;height:100vh;
 aspect-ratio:auto;margin:0;border:0;border-radius:0;z-index:30;background:#000}
body.fs .tab.show>.preview img{object-fit:contain}
/* floating side menus (visibility controlled by JS per current tab) */
.fsmenu{display:none;flex-direction:column;gap:8px;position:fixed;z-index:32;
 right:max(14px,env(safe-area-inset-right));top:calc(env(safe-area-inset-top) + 50px)}
.fsmenu button{width:82px;height:48px;border-radius:14px;background:rgba(28,28,34,.8);backdrop-filter:blur(10px);
 border:1px solid #3a3a42;color:#fff;font-size:11px;font-weight:700;display:flex;flex-direction:column;
 align-items:center;justify-content:center;gap:2px}
.fsmenu button .ic{font-size:19px;line-height:1}
.fsmenu .ov.on{background:var(--blue);border-color:var(--blue)}
.fsmenu .exit{background:rgba(58,21,24,.8);border-color:#5a2025}
.fsmenu .trig{height:92px;background:#c1121f;border-color:#c1121f;font-size:13px;letter-spacing:1px}
.fsmenu .trig .ic{font-size:26px}
.fsmenu .save{background:rgba(20,90,46,.85);border-color:#1d7a3e}
.fsmenu .fsop{width:82px;background:rgba(28,28,34,.8);backdrop-filter:blur(10px);border:1px solid #3a3a42;
 border-radius:14px;padding:8px 8px 6px;display:flex;flex-direction:column;align-items:center;gap:4px}
.fsmenu .fsop input{width:100%}
.fsmenu .fsop .rv{font-size:12px;color:#cfcfd6}
/* PLAY tab */
.playhdr{display:flex;align-items:baseline;justify-content:space-between;margin:14px 0 2px}
.playhdr .clip{font-size:18px;font-weight:800}
.playhdr .pos{font-size:13px;color:#9a9aa2;font-variant-numeric:tabular-nums}
.scrubwrap{margin:14px 0 6px}
input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:40px;background:transparent}
input[type=range]::-webkit-slider-runnable-track{height:10px;border-radius:5px;
 background:linear-gradient(#3a3a42,#2c2c33)}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:34px;height:34px;border-radius:50%;
 background:#fff;margin-top:-12px;box-shadow:0 2px 8px rgba(0,0,0,.6);border:2px solid #d8a526}
input[type=range]:disabled::-webkit-slider-thumb{border-color:#555;background:#888}
.markreadout{display:flex;justify-content:space-between;font-size:13px;color:#bfbfc6;
 font-variant-numeric:tabular-nums;margin:2px 2px 10px}
.markreadout b{color:var(--gold)}
/* in/out timeline (PLAY tab + full-screen top bar) */
.tl{position:relative;height:32px;margin:14px 0 4px;touch-action:none;cursor:pointer}
.tl::before{content:'';position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);height:8px;border-radius:4px;background:#2a2a30}
.tl-region{position:absolute;top:50%;transform:translateY(-50%);height:12px;border-radius:3px;background:rgba(45,200,110,.55);box-shadow:inset 0 0 0 1px rgba(110,240,165,.9);display:none}
.tl-in,.tl-out{position:absolute;top:50%;transform:translate(-50%,-50%);width:5px;height:30px;border-radius:3px;background:var(--gold);box-shadow:0 0 5px rgba(0,0,0,.65);display:none}
.tl-in::after{content:'⟤';position:absolute;top:-16px;left:50%;transform:translateX(-50%);font-size:14px;font-weight:900;color:var(--gold);text-shadow:0 0 3px #000}
.tl-out::after{content:'⟥';position:absolute;top:-16px;left:50%;transform:translateX(-50%);font-size:14px;font-weight:900;color:var(--gold);text-shadow:0 0 3px #000}
.tl-trig{position:absolute;top:50%;transform:translate(-50%,-50%);width:2px;height:26px;background:#0ad1e8;display:none}
.tl-trig::after{content:'T';position:absolute;top:-14px;left:50%;transform:translateX(-50%);font-size:10px;font-weight:800;color:#0ad1e8}
.tl-ph{position:absolute;left:0;top:50%;transform:translate(-50%,-50%);width:18px;height:18px;border-radius:50%;background:#fff;border:2px solid #000;box-shadow:0 0 0 1px rgba(255,255,255,.9)}
.fstlrow{display:none;position:fixed;top:calc(env(safe-area-inset-top) + 18px);left:14px;
 right:calc(82px + max(14px, env(safe-area-inset-right)) + 12px);z-index:33;height:34px;align-items:center;gap:8px}
.fstlrow.show{display:flex}
#fstl{flex:1;margin:0;height:32px;background:rgba(10,10,12,.5);backdrop-filter:blur(6px);border-radius:9px;padding:0 8px}
.fscine{flex:none;width:42px;height:34px;border-radius:10px;background:rgba(28,28,34,.85);backdrop-filter:blur(8px);
 border:1px solid #3a3a44;color:#fff;font-size:24px;font-weight:800;line-height:1;padding:0}
.fscine:disabled{opacity:.3}
.transport{display:flex;gap:8px;margin:6px 0}
.transport button{flex:1;height:50px;font-size:18px;background:var(--card2)}
.transport button.play{background:var(--green)}
.markrow{display:flex;gap:8px;margin:8px 0}
.markrow button{flex:1;height:44px;font-size:14px;background:#2a2415;color:var(--gold);
 border:1px solid #4a3c1a}
.gotorow{display:flex;gap:8px;margin:8px 0}
.gotorow input{flex:1;min-width:0;height:46px;border-radius:12px;background:var(--card2);color:#fff;
 border:none;font-size:16px;font-family:inherit;padding:0 14px;font-weight:600;
 -webkit-user-select:text;user-select:text}
.gotorow button{flex:none;height:46px;padding:0 18px;font-size:15px;font-weight:700;background:var(--card2)}
.gotorow .autoplay{background:#1d5a2e;color:#fff}
.aplay.on{background:#1d7a3e;color:#fff}
.saverow{display:flex;gap:8px;margin:8px 0 2px}
.savebtn{flex:1;height:50px;font-size:15px;font-weight:800;background:var(--blue)}
.savebtn.proxy{background:#3a2a14;color:#f0c674}
.savebtn.busy{background:#0a5fb8}
.prog{height:6px;border-radius:3px;background:#26262c;overflow:hidden;margin:2px 0 8px}
.prog>div{height:100%;width:0;background:var(--blue);transition:width .2s}
/* bottom tab bar — fixed (portrait); moves under the video in landscape */
.tabbar{position:fixed;left:0;right:0;bottom:0;z-index:30;display:flex;
 background:rgba(16,16,20,.97);backdrop-filter:blur(12px);border-top:1px solid #25252b;
 padding-bottom:env(safe-area-inset-bottom)}
.tabbar button{flex:1;background:none;border:none;color:#7a7a82;font-size:11px;font-weight:700;
 letter-spacing:1px;height:62px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px}
.tabbar button .ic{font-size:20px;line-height:1}
.tabbar button.sel{color:#fff}
.tabbar button.sel .ic{filter:drop-shadow(0 0 6px rgba(255,255,255,.4))}
.foot{margin-top:14px;font-size:12px;color:#888;min-height:30px;white-space:pre-line}
</style></head>
<body>
<div class="hdr"><div class="dot" id="dot"></div><div class="title" id="camtitle">Phantom</div><div class="temps" id="temps"></div></div>

<div class="scroll">
 <!-- ===== LIVE ===== -->
 <div class="tab show" id="tab-live">
  <div class="preview" id="preview">
   <img id="sdiimg" alt="">
   <canvas id="cv-live"></canvas>
   <img class="ovlay" id="ov-live" alt="">
   <div class="previewoff">SDI preview unavailable<br><small>switch the laptop's Viewer to SDI</small></div>
   <button class="fsbtn" onclick="toggleFS()">⛶</button>
  </div>
  <button class="trigger" id="trig" onclick="act('trigger')">TRIGGER</button>
  <button class="wide stopstore" id="stopstore" onclick="act('stopstore')" style="display:none">■ Stop &amp; Save Recording</button>
  <div class="row">
   <button onclick="capture()">Capture</button>
   <button id="livebtn" class="golive" onclick="act('live')">Go Live</button>
  </div>
  <div class="trigpos">
   <div class="tphdr">Trigger point — where the moment sits in the take</div>
   <div class="tprow">
    <button id="tp-end" onclick="act('trigpos/end')">End<small>keep before</small></button>
    <button id="tp-mid" onclick="act('trigpos/mid')">Middle<small>50 / 50</small></button>
    <button id="tp-start" onclick="act('trigpos/start')">Start<small>keep after</small></button>
   </div>
  </div>
  <div class="hint">Partitions — tap to select, long-press to clear · <b style="color:#bdf0bd">✓</b> saved · <b style="color:#ffd24a">!</b> not downloaded</div>
  <div class="strip" id="stripLive"></div>
 </div>

 <!-- ===== PLAY ===== -->
 <div class="tab" id="tab-play">
  <div class="preview" id="previewP">
   <img id="sdiimgP" alt="">
   <canvas id="cv-play"></canvas>
   <img class="ovlay" id="ov-play" alt="">
   <div class="previewoff">No preview<br><small>switch the laptop's Viewer to SDI or Ethernet</small></div>
   <button class="fsbtn" onclick="toggleFS()">⛶</button>
  </div>
  <div class="hint">Tap a saved (green) or ready clip to review</div>
  <div class="strip" id="stripPlay"></div>
  <div class="playhdr"><div class="clip" id="clipName">—</div><div class="pos" id="clipPos"></div></div>
  <div class="tl" id="tl"><div class="tl-region"></div><div class="tl-trig"></div><div class="tl-in"></div><div class="tl-out"></div><div class="tl-ph"></div></div>
  <div class="markreadout">
   <span>In <b id="inFr">–</b></span><span id="dur"></span><span>Out <b id="outFr">–</b></span>
  </div>
  <div class="transport">
   <button onclick="act('seek/'+stepFrame(-10))">⏪</button>
   <button onclick="act('seek/'+stepFrame(-1))">◀︎</button>
   <button id="playbtn" class="play" onclick="togglePlay()">► Play</button>
   <button onclick="act('seek/'+stepFrame(1))">▶︎</button>
   <button onclick="act('seek/'+stepFrame(10))">⏩</button>
  </div>
  <div class="markrow">
   <button onclick="markIn()">⟤ Mark In</button>
   <button onclick="markOut()">Mark Out ⟥</button>
  </div>
  <div class="saverow">
   <button class="savebtn" id="savebtn" onclick="act('savesmart')">Save to Laptop</button>
   <button class="savebtn proxy" onclick="act('proxy')">Save Proxy</button>
  </div>
  <div class="prog"><div id="progbar"></div></div>
  <div class="gotorow">
   <input type="number" id="gotoframe" inputmode="numeric" placeholder="frame #">
   <button onclick="gotoFrame()">Go</button>
   <button onclick="setOut()">⟥ Out</button>
   <button class="autoplay" onclick="autoPlay()">▶</button>
  </div>
  <button class="wide aplay" id="autoplaybtn" onclick="autoPlayToggle()">⟳ Auto-play after rec</button>
  <button class="wide" onclick="resetInOut()">↺ Reset In/Out — full clip</button>
  <button class="wide golive" onclick="act('live')">Go Live</button>
 </div>

 <!-- ===== MONITOR ===== -->
 <div class="tab" id="tab-monitor">
  <div class="preview" id="previewM"><img id="sdiimgM" alt=""><canvas id="cv-monitor"></canvas><img class="ovlay" id="ov-monitor" alt=""><div class="previewoff">SDI monitor off</div><button class="fsbtn" onclick="toggleFS()">⛶</button></div>

  <details class="sect" open><summary>Image Overlay</summary>
   <div class="mongrid">
    <button class="montog" onclick="act('overlay/grab')">📸 Grab Screenshot</button>
    <button class="montog" id="o-show" onclick="act('overlay/toggle')">Show Overlay</button>
   </div>
   <div class="setrow"><label>Opacity</label><input type="range" id="o-op" min="0" max="100" oninput="ovOp(this.value)"><span class="rv" id="o-opv">—</span></div>
   <div class="setrow"><label>Blink</label><input type="range" id="o-bl" min="0" max="10" oninput="ovBl(this.value)"><span class="rv" id="o-blv">off</span></div>
   <div class="gallery" id="o-gal"><div class="none">No screen grabs yet</div></div>
   <button class="wide danger" id="o-clear" onclick="act('overlay/clear')" style="display:none">Clear Overlay</button>
  </details>

  <details class="sect" open><summary>Exposure / Focus</summary>
   <div class="mongrid">
    <button class="montog" id="m-fc" onclick="act('mon/falsecolor')">False Color</button>
    <button class="montog" id="m-fcmode" onclick="act('mon/fcmode')">Scale</button>
    <button class="montog" id="m-peak" onclick="act('mon/peaking')">Peaking</button>
    <button class="montog" id="m-zebra" onclick="act('mon/zebra')">Zebra</button>
   </div>
  </details>

  <details class="sect" open><summary>Scopes</summary>
   <div class="mongrid">
    <button class="montog" id="m-hist" onclick="act('mon/histogram')">Histogram</button>
    <button class="montog" id="m-wave" onclick="act('mon/waveform')">Waveform</button>
    <button class="montog" id="m-vec" onclick="act('mon/vectorscope')">Vectorscope</button>
   </div>
  </details>

  <details class="sect" open><summary>Framing</summary>
   <div class="mongrid">
    <button class="montog" id="m-grid" onclick="act('mon/grid')">Grid</button>
    <button class="montog" id="m-guides" onclick="act('mon/guides')">Guides</button>
   </div>
  </details>

  <details class="sect"><summary>Orientation</summary>
   <div class="mongrid">
    <button class="montog" id="m-invert" onclick="act('mon/invert')">Invert</button>
    <button class="montog" id="m-fliph" onclick="act('mon/fliph')">Flip H</button>
    <button class="montog" id="m-flipv" onclick="act('mon/flipv')">Flip V</button>
    <button class="montog" id="m-rotate" onclick="act('mon/rotate')">Vertical</button>
   </div>
  </details>

  <details class="sect"><summary>Grid setup</summary>
   <div class="mongrid" id="g-divs">
    <button class="montog" onclick="act('grid/div/1')">None</button>
    <button class="montog" onclick="act('grid/div/2')">2×2</button>
    <button class="montog" onclick="act('grid/div/3')">Thirds</button>
    <button class="montog" onclick="act('grid/div/4')">4×4</button>
    <button class="montog" onclick="act('grid/div/6')">6×6</button>
    <button class="montog" id="g-cross" onclick="act('grid/crosshair')">＋ Crosshair</button>
   </div>
   <div class="setrow"><label>Opacity</label><input type="range" id="g-op" min="5" max="100" oninput="gridOp(this.value)"><span class="rv" id="g-opv">—</span></div>
  </details>

  <details class="sect"><summary>Frame Guides</summary>
   <div class="mongrid" id="gd-add"></div>
   <div id="gd-list"></div>
  </details>

  <div class="hint">These drive the desktop SDI monitor in real time.</div>
 </div>

 <!-- ===== SETUP ===== -->
 <div class="tab" id="tab-setup">
  <h3>Resolution</h3>
  <div class="setrow"><label>Resolution</label><select id="ressel" onchange="setRes(this.value)"></select></div>
  <div class="setrow"><label>Frame rate</label><select id="ratesel" onchange="act('rate/'+this.value)"></select><button class="mini" onclick="customRate()">Custom</button></div>
  <div class="setrow"><label>Shutter</label><select id="shutsel" onchange="act('shutter/'+this.value)"></select><button class="mini" onclick="customShutter()">Custom</button></div>
  <h3>Camera</h3>
  <div class="row">
   <button onclick="blackRef()">⬛ Black Ref</button>
   <button onclick="act('wb')">⚪ White Bal</button>
  </div>
  <div class="hint">Black Reference recalibrates the sensor — the image goes black for a moment. White Balance samples the centre of the frame.</div>
  <h3>Presets</h3>
  <div class="presets" id="presets"><span class="none">none saved yet</span></div>
  <h3>Auto-save</h3>
  <button class="wide" id="autosave" onclick="act('autosave')">Auto-save: …</button>
  <h3>Partitions</h3>
  <div class="setrow"><label>Count</label><select id="partsel" onchange="setParts(this.value)"></select></div>
  <button class="wide danger" onclick="clearRam()">🗑 Clear RAM — erase all clips</button>
  <div class="hint">Clear RAM wipes every recorded clip but keeps the current partition count. Changing the count also erases RAM.</div>
 </div>

 <div class="foot" id="foot">connecting…</div>
</div>

<!-- full-screen PLAY: ‹ prev cine · in/out timeline · next cine › -->
<div class="fstlrow" id="fstlrow">
 <button class="fscine" id="fs-prevc" onclick="cineStep(-1)">‹</button>
 <div class="tl" id="fstl"><div class="tl-region"></div><div class="tl-trig"></div><div class="tl-in"></div><div class="tl-out"></div><div class="tl-ph"></div></div>
 <button class="fscine" id="fs-nextc" onclick="cineStep(1)">›</button>
</div>

<!-- floating side menus for full-screen video mode (one per tab) -->
<div class="fsmenu" id="fsm-live">
 <button class="trig" onclick="act('trigger')"><span class="ic">⏺</span>TRIGGER</button>
 <button onclick="act('live')"><span class="ic">●</span>Live</button>
 <button class="exit" onclick="toggleFS()"><span class="ic">⤡</span>Exit</button>
</div>
<div class="fsmenu" id="fsm-play">
 <button id="fsm-pb" onclick="togglePlay()"><span class="ic">►</span>Play</button>
 <button onclick="act('markin')"><span class="ic">⟤</span>In</button>
 <button onclick="act('markout')"><span class="ic">⟥</span>Out</button>
 <button class="save" onclick="act('download')"><span class="ic">⤓</span>Save</button>
 <button class="exit" onclick="toggleFS()"><span class="ic">⤡</span>Exit</button>
</div>
<div class="fsmenu" id="fsm-mon">
 <button class="ov" id="fs-ov" onclick="act('overlay/toggle')"><span class="ic">🖼</span>Overlay</button>
 <button onclick="act('overlay/grabuse')"><span class="ic">📸</span>Grab&amp;Set</button>
 <div class="fsop"><input type="range" id="fs-op" min="0" max="100" oninput="ovOp(this.value)"><span class="rv" id="fs-opv">—</span></div>
 <button class="exit" onclick="toggleFS()"><span class="ic">⤡</span>Exit</button>
</div>

<div class="tabbar">
 <button id="tabbtn-live" class="sel" onclick="showTab('live')"><span class="ic">●</span>LIVE</button>
 <button id="tabbtn-play" onclick="showTab('play')"><span class="ic">▶</span>PLAYBACK</button>
 <button id="tabbtn-monitor" onclick="showTab('monitor')"><span class="ic">🎛</span>MON</button>
 <button id="tabbtn-setup" onclick="showTab('setup')"><span class="ic">⚙</span>SETUP</button>
</div>

<script>
const $=id=>document.getElementById(id);
const COLORS={live:'#0aa3b5',empty:'#3a3a40',ready:'#2862d6',waitTrigger:'#d62828',postTrigger:'#e07b00',stored:'#1d7a3e'};
const NAMES={live:'live',empty:'empty',ready:'ready',waitTrigger:'rec',postTrigger:'trig',stored:'saved'};
let curTab='live', presetKey='', last={};
function send(p){return fetch(p,{cache:'no-store'}).catch(()=>{});}
function act(p){return send(p).then(()=>poll());}
function setRes(v){act('res/'+v);}
function setParts(v){if(confirm('Re-partition to '+v+'? This ERASES all clips in RAM.'))act('partitions/'+v);}
function customRate(){const v=prompt('Frame rate in fps (e.g. 600):',last.rate||'');
 if(v&&+v>0)act('rate/'+Math.round(+v));}
function customShutter(){const v=prompt('Shutter angle in degrees (1–359):',last.shutter||'');
 if(v&&+v>0)act('shutter/'+Math.min(359,Math.max(1,+v)));}
function blackRef(){if(confirm('Run Black Reference? The image goes black for a moment — don\'t do this mid-take.'))act('blackref');}
function clearRam(){
 const un=(last.cines||[]).filter(c=>c.state==='stored'&&!c.saved).length;
 const msg=un?('⚠️ '+un+' clip(s) have NOT been downloaded yet. Erase ALL clips in RAM anyway?')
             :'Erase ALL recorded clips in RAM? This cannot be undone.';
 if(confirm(msg))act('clearram');}
let fs=false;
function toggleFS(){fs=!fs;document.body.classList.toggle('fs',fs);updateFSMenu();previewStart();}
function updateFSMenu(){
 const want=fs?('fsm-'+(curTab==='monitor'?'mon':curTab)):'';
 ['fsm-live','fsm-play','fsm-mon'].forEach(id=>{const m=$(id);if(m)m.style.display=(id===want)?'flex':'none';});
 $('fstlrow').classList.toggle('show',fs&&curTab==='play');
 const cs=(last.cines||[]).filter(c=>c.id>0&&c.state!=='empty');
 const i=cs.findIndex(c=>c.id===last.selected);
 $('fs-prevc').disabled=!(i>0);$('fs-nextc').disabled=!(i>=0&&i<cs.length-1);
}
function cineStep(dir){
 const cs=(last.cines||[]).filter(c=>c.id>0&&c.state!=='empty');if(!cs.length)return;
 let i=cs.findIndex(c=>c.id===last.selected);if(i<0)i=0;
 i=Math.min(Math.max(i+dir,0),cs.length-1);
 if(cs[i].id!==last.selected)act('selectcine/'+cs[i].id);
}
function ovOp(v){$('o-opv').textContent=v+'%';send('overlay/opacity/'+v);}
function ovBl(v){$('o-blv').textContent=v==0?'off':v;send('overlay/blink/'+v);}
let _ovBlinkOn=true,_ovBlinkT=0;
function updateOverlayLayer(o){
 const layers=['ov-live','ov-play','ov-monitor'].map($).filter(Boolean);
 const want=o.on&&o.has&&o.name;
 if(want){
  const src='screenshot/'+encodeURIComponent(o.name);
  // blink: o.blink in Hz (0=steady). Toggle visibility on a timer.
  if(o.blink>0){const now=Date.now();if(now-_ovBlinkT>1000/(2*o.blink)){_ovBlinkOn=!_ovBlinkOn;_ovBlinkT=now;}}
  else _ovBlinkOn=true;
  layers.forEach(im=>{
   if(im.dataset.src!==src){im.dataset.src=src;im.src=src;}
   im.style.opacity=(o.opacity/100);
   im.style.display=_ovBlinkOn?'block':'none';});
 }else{
  layers.forEach(im=>{im.style.display='none';im.dataset.src='';im.removeAttribute('src');});
 }
}
function gridOp(v){$('g-opv').textContent=v+'%';send('grid/opacity/'+v);}
function showTab(t){curTab=t;
 ['live','play','monitor','setup'].forEach(x=>{
  $('tab-'+x).classList.toggle('show',x===t);
  $('tabbtn-'+x).classList.toggle('sel',x===t);});
 if(t==='play')syncScrub(last);
 if(isVid(t))previewStart();else previewStop();
 updateFSMenu();
}
/* full-screen: swipe the video left/right to jump LIVE ⇆ PLAYBACK ⇆ MON.
   Fires mid-gesture once it's clearly horizontal (within ~40° of level), so it
   feels instant and tolerates curved / angled swipes. */
function fsSwitchTab(dir){const order=['live','play','monitor'];let i=order.indexOf(curTab);
 if(i<0)return;showTab(order[(i+dir+order.length)%order.length]);}
function attachSwipe(el){
 let sx=0,sy=0,on=false,done=false;
 el.addEventListener('pointerdown',e=>{if(!fs)return;sx=e.clientX;sy=e.clientY;on=true;done=false;});
 el.addEventListener('pointermove',e=>{if(!fs||!on||done)return;
  const dx=e.clientX-sx,dy=e.clientY-sy;
  if(Math.abs(dx)>38&&Math.atan2(Math.abs(dy),Math.abs(dx))<0.72){done=true;fsSwitchTab(dx<0?1:-1);}});
 const end=()=>{on=false;};
 el.addEventListener('pointerup',end);el.addEventListener('pointercancel',end);el.addEventListener('pointerleave',end);}
document.querySelectorAll('.preview').forEach(attachSwipe);

/* ---- SDI/viewer preview: live MJPEG stream (LIVE + PLAY), poll fallback ---- */
const previews={live:$('sdiimg'),play:$('sdiimgP'),monitor:$('sdiimgM')};
const isVid=t=>t==='live'||t==='play'||t==='monitor';
let streamCtl=null,lastBlob=null,gotFrame=false,pollTimer=null;
function applyFrame(url){
 const im=previews[curTab];
 if(im){im.src=url;im.closest('.preview').classList.add('live');}
 if(lastBlob)URL.revokeObjectURL(lastBlob);
 lastBlob=url;gotFrame=true;
}
function idxOf(a,seq,from){
 outer:for(let i=from;i<=a.length-seq.length;i++){
  for(let j=0;j<seq.length;j++)if(a[i+j]!==seq[j])continue outer;
  return i;}
 return -1;}
async function startStream(){
 stopStream();const ctl=new AbortController();streamCtl=ctl;
 try{
  const resp=await fetch('stream',{signal:ctl.signal,cache:'no-store'});
  if(!resp.ok||!resp.body)throw 0;
  const reader=resp.body.getReader(),td=new TextDecoder(),HDR=[13,10,13,10];
  let buf=new Uint8Array(0);
  while(true){
   const {done,value}=await reader.read();if(done)break;
   const nb=new Uint8Array(buf.length+value.length);nb.set(buf);nb.set(value,buf.length);buf=nb;
   while(true){
    const h=idxOf(buf,HDR,0);if(h<0)break;
    const m=td.decode(buf.subarray(0,h)).match(/Content-Length:\s*(\d+)/i);
    if(!m){buf=buf.subarray(h+4);continue;}
    const len=+m[1],start=h+4;
    if(buf.length<start+len)break;
    applyFrame(URL.createObjectURL(new Blob([buf.subarray(start,start+len)],{type:'image/jpeg'})));
    let next=start+len;if(buf[next]===13&&buf[next+1]===10)next+=2;buf=buf.subarray(next);
   }
   if(buf.length>3000000)buf=new Uint8Array(0);
  }
 }catch(e){}
 if(streamCtl===ctl){streamCtl=null;
  if(isVid(curTab)){
   if(gotFrame)setTimeout(()=>{if(isVid(curTab)&&!streamCtl)startStream();},800);
   else startPoll();}
 }
}
function stopStream(){if(streamCtl){const c=streamCtl;streamCtl=null;c.abort();}}
function startPoll(){stopPoll();pollTick();}
function stopPoll(){if(pollTimer){clearTimeout(pollTimer);pollTimer=null;}}
function pollTick(){
 const im=previews[curTab];if(!im){stopPoll();return;}
 im.onload=()=>{im.closest('.preview').classList.add('live');pollTimer=setTimeout(pollTick,200);};
 im.onerror=()=>{im.closest('.preview').classList.remove('live');pollTimer=setTimeout(pollTick,1200);};
 im.src='frame?t='+Date.now();
}
/* ---- low-latency H.264 feed (WebCodecs); falls back to MJPEG ---- */
const canvases={live:$('cv-live'),play:$('cv-play'),monitor:$('cv-monitor')};
const useH264=('VideoDecoder' in window)&&('EncodedVideoChunk' in window);
let vws=null,vdec=null,vcfg=false,vts=0,h264Failed=false,h264Frame=false,h264WD=null;
function drawVF(frame){
 h264Frame=true;const c=canvases[curTab];
 if(c){const ctx=c.getContext('2d');
  if(c.width!==frame.displayWidth){c.width=frame.displayWidth;c.height=frame.displayHeight;}
  ctx.drawImage(frame,0,0,c.width,c.height);
  c.closest('.preview').classList.add('live');}
 frame.close();
}
function startH264(){
 if(vws)return;
 try{vdec=new VideoDecoder({output:drawVF,error:()=>{}});}catch(e){h264Failed=true;mjpegStart();return;}
 document.body.classList.add('h264');vcfg=false;vts=0;h264Frame=false;
 /* the H.264 streamer runs on its own port (control port + 1 = 8990) */
 const url=(location.protocol==='https:'?'wss':'ws')+'://'+location.hostname+':8990'+location.pathname+'h264';
 let ws;try{ws=new WebSocket(url);}catch(e){h264Failed=true;mjpegStart();return;}
 ws.binaryType='arraybuffer';vws=ws;
 ws.onmessage=ev=>{
  const a=new Uint8Array(ev.data),type=a[0],body=a.subarray(1);
  if(type===0){
   try{const cfg=JSON.parse(new TextDecoder().decode(body));
    const desc=Uint8Array.from(atob(cfg.avcc),ch=>ch.charCodeAt(0));
    vdec.configure({codec:cfg.codec,description:desc,optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'});
    vcfg=true;}catch(e){}
  }else if(vcfg&&(type===1||type===2)){
   try{vdec.decode(new EncodedVideoChunk({type:type===1?'key':'delta',timestamp:vts++,data:body}));}catch(e){}
  }
 };
 ws.onclose=()=>{stopH264();if(isVid(curTab)&&!h264Failed)setTimeout(()=>{if(isVid(curTab))startH264();},800);};
 ws.onerror=()=>{try{ws.close();}catch(e){}};
 // No frames in 2.5 s (Mac not on SDI etc.) → fall back to MJPEG for this session.
 clearTimeout(h264WD);h264WD=setTimeout(()=>{if(!h264Frame){h264Failed=true;stopH264();mjpegStart();}},2500);
}
function stopH264(){clearTimeout(h264WD);
 if(vws){const w=vws;vws=null;try{w.close();}catch(e){}}
 if(vdec){try{vdec.close();}catch(e){}vdec=null;}vcfg=false;}
function mjpegStart(){document.body.classList.remove('h264');
 if(window.ReadableStream&&window.fetch){if(!streamCtl)startStream();}else startPoll();}
function previewStart(){stopPoll();
 if(useH264&&!h264Failed){startH264();return;}
 mjpegStart();}
function previewStop(){stopStream();stopPoll();stopH264();}

/* ---- in/out timeline (PLAY tab + full-screen top bar) ---- */
let scrubbing=false, lastSeek=0, seekTimer=null;
let tlMin=0,tlMax=0,tlVal=0,tlIn=null,tlOut=null,tlHas=false;
function sendSeek(v){const now=Date.now();
 if(now-lastSeek>100){lastSeek=now;send('seek/'+v);}
 else{clearTimeout(seekTimer);seekTimer=setTimeout(()=>{lastSeek=Date.now();send('seek/'+v);},100);}}
function paintTL(){const span=tlMax-tlMin,pct=v=>span>0?Math.max(0,Math.min(100,(v-tlMin)/span*100)):0;
 document.querySelectorAll('.tl').forEach(tl=>{
  const rg=tl.querySelector('.tl-region'),i=tl.querySelector('.tl-in'),o=tl.querySelector('.tl-out'),
        p=tl.querySelector('.tl-ph'),tr=tl.querySelector('.tl-trig');
  if(tlIn!=null&&tlOut!=null&&tlOut>tlIn){rg.style.display='block';rg.style.left=pct(tlIn)+'%';rg.style.width=(pct(tlOut)-pct(tlIn))+'%';
   i.style.display='block';i.style.left=pct(tlIn)+'%';o.style.display='block';o.style.left=pct(tlOut)+'%';}
  else{rg.style.display='none';i.style.display='none';o.style.display='none';}
  if(tr){if(tlHas&&tlMin<=0&&tlMax>=0){tr.style.display='block';tr.style.left=pct(0)+'%';}else tr.style.display='none';}
  p.style.left=pct(tlVal)+'%';p.style.opacity=tlHas?1:.25;});}
function tlSeekAt(tl,clientX){if(tlMax<=tlMin)return;const r=tl.getBoundingClientRect();
 let f=Math.round(tlMin+(clientX-r.left)/r.width*(tlMax-tlMin));
 f=Math.min(Math.max(f,tlMin),tlMax);tlVal=f;paintTL();$('clipPos').textContent=posLabel(f,last);sendSeek(f);}
function attachTL(tl){
 tl.addEventListener('pointerdown',e=>{if(!tlHas)return;scrubbing=true;try{tl.setPointerCapture(e.pointerId)}catch(_){}tlSeekAt(tl,e.clientX);});
 tl.addEventListener('pointermove',e=>{if(scrubbing)tlSeekAt(tl,e.clientX);});
 const up=()=>{if(scrubbing){clearTimeout(seekTimer);send('seek/'+tlVal).then(()=>setTimeout(()=>{scrubbing=false;poll();},180));}};
 tl.addEventListener('pointerup',up);tl.addEventListener('pointercancel',up);}
document.querySelectorAll('.tl').forEach(attachTL);
function stepFrame(d){tlVal=Math.min(Math.max(tlVal+d,tlMin),tlMax);paintTL();
 $('clipPos').textContent=posLabel(tlVal,last);return tlVal;}
/* In/out readout below the timeline (driven by tlIn/tlOut). */
function updateMarkReadout(){
 $('inFr').textContent=(tlIn!=null)?tlIn:'–';
 $('outFr').textContent=(tlOut!=null)?tlOut:'–';
 $('dur').textContent=(tlIn!=null&&tlOut!=null&&tlOut>tlIn)?('clip '+secs(tlOut-tlIn)):'';
}
/* Mark in/out — update the marker INSTANTLY, then confirm on the camera. */
function markIn(){if(!tlHas)return;tlIn=tlVal;if(tlOut!=null&&tlOut<=tlIn)tlOut=null;paintTL();updateMarkReadout();act('markin');}
function markOut(){if(!tlHas)return;tlOut=tlVal;if(tlIn!=null&&tlIn>=tlOut)tlIn=null;paintTL();updateMarkReadout();act('markout');}
function resetInOut(){tlIn=tlMin;tlOut=tlMax;paintTL();updateMarkReadout();act('resetinout');}
function togglePlay(){last.isPlaying?act('pause'):act('play');}
function gotoFrame(){const v=$('gotoframe').value;if(v!=='')act('seek/'+Math.round(+v));}
function autoPlay(){const v=$('gotoframe').value;if(v!=='')act('playfrom/'+Math.round(+v));}
function setOut(){const v=$('gotoframe').value;if(v!=='')act('setout/'+Math.round(+v));}
function autoPlayToggle(){const v=$('gotoframe').value;if(v!=='')send('autoplayframe/'+Math.round(+v));act('autoplay');}
function secs(fr){const r=last.rate||1;const t=fr/r;return t<60?t.toFixed(1)+'s':(Math.floor(t/60)+':'+('0'+Math.floor(t%60)).slice(-2));}
function posLabel(f,s){if(!s.lastFrame&&!s.firstFrame)return'';
 const rel=f-(s.firstFrame||0),tot=(s.lastFrame||0)-(s.firstFrame||0);
 return 'f'+f+'  ·  '+secs(rel)+' / '+secs(tot);}
function syncScrub(s){
 const sel=(s.cines||[]).find(c=>c.id===s.selected);
 const has=sel&&sel.state!=='empty'&&sel.lastFrame>sel.firstFrame;
 $('clipName').textContent=sel?sel.label+(sel.state==='stored'?' · saved':''):'—';
 tlHas=!!has;
 if(has){tlMin=sel.firstFrame;tlMax=sel.lastFrame;
  if(!scrubbing){tlVal=s.playFrame||sel.firstFrame;$('clipPos').textContent=posLabel(tlVal,s);}
 }else{tlMin=0;tlMax=0;tlVal=0;$('clipPos').textContent='';}
 // While the user is scrubbing/marking, keep the local (optimistic) marks;
 // otherwise take the camera's authoritative in/out.
 if(!scrubbing){tlIn=(s.inPoint!=null)?s.inPoint:null;tlOut=(s.outPoint!=null)?s.outPoint:null;}
 paintTL();
 updateMarkReadout();
 $('playbtn').textContent=s.isPlaying?'❚❚ Pause':'► Play';
 $('playbtn').classList.toggle('play',!s.isPlaying);
 {const fb=$('fsm-pb');if(fb)fb.querySelector('.ic').textContent=s.isPlaying?'❚❚':'►';}
 {const cs=(s.cines||[]).filter(c=>c.id>0&&c.state!=='empty'),i=cs.findIndex(c=>c.id===s.selected);
  const pb=$('fs-prevc'),nb=$('fs-nextc');
  if(pb)pb.disabled=!(i>0);if(nb)nb.disabled=!(i>=0&&i<cs.length-1);}
}

function capture(){
 const sel=(last.cines||[]).find(c=>c.id===last.selected);
 if(sel&&sel.state==='stored'&&!sel.saved&&
    !confirm(sel.label+' has NOT been downloaded yet — overwrite it with a new capture?'))return;
 act('capture');
}
function clearCine(c){
 const msg=(c.state==='stored'&&!c.saved)
  ? c.label+' has NOT been downloaded yet. Clear and lose it?'
  : 'Clear '+c.label+'?';
 if(confirm(msg))act('delcine/'+c.id);
}
function attachLongPress(el,fn){
 let t=null;
 const start=()=>{el._lp=false;t=setTimeout(()=>{el._lp=true;fn();},550);};
 const cancel=()=>{if(t){clearTimeout(t);t=null;}};
 el.addEventListener('touchstart',start,{passive:true});
 el.addEventListener('touchmove',cancel,{passive:true});
 el.addEventListener('touchend',cancel);
 el.addEventListener('pointerdown',e=>{if(e.pointerType==='mouse')start();});
 el.addEventListener('pointerup',e=>{if(e.pointerType==='mouse')cancel();});
}
function buildStrip(el,s,dimNonStored){
 el.replaceChildren(...s.cines.map(c=>{
  const d=document.createElement('div');
  const usable=c.id>0&&c.state!=='empty';
  d.className='slot'+(c.id===s.selected?' sel':'')+(dimNonStored&&!usable?' dim':'');
  d.style.background=COLORS[c.state]||'#333';
  const sm=document.createElement('small');sm.textContent=NAMES[c.state]||c.state;
  d.append(c.label,document.createElement('br'),sm);
  if(c.state==='stored'){
   const mk=document.createElement('span');
   mk.className='savemark '+(c.saved?'ok':'warn');
   mk.textContent=c.saved?'✓':'!';
   mk.title=c.saved?'saved':'not downloaded';
   d.appendChild(mk);
  }
  if(c.id>0){
   d.onclick=()=>{if(d._lp){d._lp=false;return;}act('selectcine/'+c.id);};
   attachLongPress(d,()=>clearCine(c));
  }
  return d;}));
}

async function poll(){
 try{
  const s=await(await fetch('status',{cache:'no-store'})).json();
  last=s;
  $('dot').className='dot '+(s.connected?'on':'off');
  $('camtitle').textContent=s.title||'Phantom — not connected';
  $('temps').textContent=s.camTemp?('cam '+s.camTemp+'°  sns '+s.snsTemp+'°'):'';
  // strips on both tabs
  buildStrip($('stripLive'),s,false);
  buildStrip($('stripPlay'),s,true);
  $('trig').className='trigger'+(s.recording!=null?' rec':'');
  $('livebtn').className='golive'+(s.mode==='Live'?' active':'');
  if($('stopstore')){const ss=$('stopstore');
   if(s.recordingActive!=null){ss.style.display='';ss.innerHTML='■ Stop &amp; Save Recording (C'+s.recordingActive+')';}
   else ss.style.display='none';}
  {const cap=s.capacity||0,pt=s.postTrigger||0,
    m=cap>0?(pt<=cap*0.1?'end':(pt>=cap*0.9?'start':'mid')):'';
   ['tp-end','tp-mid','tp-start'].forEach(id=>{const b=$(id);if(b)b.classList.toggle('on',id==='tp-'+m);});}
  if($('autoplaybtn')){const ab=$('autoplaybtn');
   ab.textContent='⟳ Auto-play after rec: '+(s.autoPlay?('ON @ '+s.autoPlayFrame):'off');
   ab.classList.toggle('on',!!s.autoPlay);}
  // MONITOR tab toggle states
  if(s.mon){const M=s.mon,setb=(id,on)=>{const b=$(id);if(b)b.classList.toggle('on',!!on);};
   setb('m-fc',M.fc);setb('m-peak',M.peak);setb('m-zebra',M.zebra);
   setb('m-hist',M.hist);setb('m-wave',M.wave);setb('m-vec',M.vec);
   setb('m-grid',M.grid);setb('m-guides',M.guides);
   setb('m-invert',M.invert);setb('m-fliph',M.fliph);setb('m-flipv',M.flipv);
   {const rb=$('m-rotate');if(rb){rb.classList.toggle('on',M.rotate!==0);rb.textContent=M.rotate===0?'Vertical':(M.rotate===90?'Vertical ↻':'Vertical ↺');}}
   const fm=$('m-fcmode');if(fm){fm.textContent=M.fc?('Scale: '+(M.fcMode||'arri')):'Scale';fm.classList.toggle('on',M.fc);}}
  // Image overlay
  if(s.overlay){const o=s.overlay;
   // Composite the reference frame over the iPad's live video previews (the
   // laptop bakes it into its own viewer; the streamed feed is raw, so we
   // layer it here in the browser to match — same opacity, same blink).
   updateOverlayLayer(o);
   $('o-show').classList.toggle('on',o.on);
   $('o-show').textContent=o.has?(o.on?'Overlay ON':'Show Overlay'):'(load one ↓)';
   {const fo=$('fs-ov');if(fo){fo.classList.toggle('on',o.on);fo.querySelector('.ic').textContent=o.on?'🖼':'▢';}}
   if(document.activeElement!==$('fs-op')){const fp=$('fs-op');if(fp){fp.value=o.opacity;$('fs-opv').textContent=o.opacity+'%';}}
   $('o-clear').style.display=o.has?'':'none';
   if(document.activeElement!==$('o-op')){$('o-op').value=o.opacity;$('o-opv').textContent=o.opacity+'%';}
   if(document.activeElement!==$('o-bl')){$('o-bl').value=o.blink;$('o-blv').textContent=o.blink==0?'off':o.blink;}
   const gk=JSON.stringify(o.shots);
   if(gk!==window._galkey){window._galkey=gk;const gal=$('o-gal');
    if(!o.shots.length)gal.innerHTML='<div class="none">No screen grabs yet — tap Grab Screenshot</div>';
    else gal.replaceChildren(...o.shots.map(nm=>{const im=document.createElement('img');
     im.src='screenshot/'+encodeURIComponent(nm);im.loading='lazy';
     im.onclick=()=>act('overlay/load/'+encodeURIComponent(nm));return im;}));}
   [...$('o-gal').querySelectorAll('img')].forEach(im=>
    im.classList.toggle('sel',decodeURIComponent(im.src.split('/').pop())===o.name));
  }
  // Grid divisions / crosshair / opacity
  if(s.grid){const g=s.grid,divs=[1,2,3,4,6];
   [...$('g-divs').children].forEach((b,i)=>{if(i<5)b.classList.toggle('on',g.on&&g.div===divs[i]);});
   $('g-cross').classList.toggle('on',g.crosshair);
   if(document.activeElement!==$('g-op')){$('g-op').value=g.opacity;$('g-opv').textContent=g.opacity+'%';}
  }
  // Guide add buttons + list
  if(s.guidePresets){const ak=JSON.stringify(s.guidePresets);
   if(ak!==window._gakey){window._gakey=ak;
    $('gd-add').replaceChildren(...s.guidePresets.map((nm,i)=>{const b=document.createElement('button');
     b.className='montog';b.textContent='+ '+nm;b.onclick=()=>act('guide/add/'+i);return b;}));}}
  if(s.guides){const lk=JSON.stringify(s.guides.map(g=>[g.id,g.ratio,g.on]));
   if(lk!==window._glkey){window._glkey=lk;const list=$('gd-list');
    if(!s.guides.length)list.innerHTML='<div class="hint">No guides yet — add one above.</div>';
    else list.replaceChildren(...s.guides.map(g=>{const row=document.createElement('div');row.className='gdrow';
     const nm=document.createElement('span');nm.className='nm';nm.textContent=g.ratio;
     const eye=document.createElement('button');eye.className='eye'+(g.on?' on':'');eye.textContent=g.on?'👁':'∅';
     eye.onclick=()=>act('guide/toggle/'+g.id);
     const sl=document.createElement('input');sl.type='range';sl.min=20;sl.max=100;sl.value=g.scale;sl.dataset.gid=g.id;
     sl.oninput=()=>send('guide/scale/'+g.id+'/'+sl.value);
     const rm=document.createElement('button');rm.className='rm';rm.textContent='✕';rm.onclick=()=>act('guide/remove/'+g.id);
     row.append(nm,eye,sl,rm);return row;}));}
   s.guides.forEach(g=>{const sl=document.querySelector('[data-gid="'+g.id+'"]');
    if(sl&&document.activeElement!==sl)sl.value=g.scale;});
  }
  // PLAY tab
  if(curTab==='play'||true)syncScrub(s);
  // Save button / progress — smart destination: CineMag if one's loaded, else laptop.
  const sv=$('savebtn'),pb=$('progbar');
  sv.classList.toggle('mag',!!s.magPresent);
  if(s.downloadProgress!=null){sv.classList.add('busy');sv.textContent='Saving… '+Math.round(s.downloadProgress*100)+'%';
   pb.style.width=(s.downloadProgress*100)+'%';}
  else if(s.queued){sv.classList.add('busy');sv.textContent=s.queued+' queued…';pb.style.width='0';}
  else{sv.classList.remove('busy');sv.textContent=s.magPresent?'Save to CineMag':'Save to Laptop';pb.style.width='0';}
  // SETUP — presets
  const key=JSON.stringify(s.presets);
  if(key!==presetKey){presetKey=key;
    if(s.presets.length)$('presets').replaceChildren(...s.presets.map(n=>{
      const b=document.createElement('button');b.textContent=n;
      b.onclick=()=>act('preset/'+encodeURIComponent(n));return b;}));}
  // resolution dropdown
  const reskey=JSON.stringify(s.resOptions||[]);
  if(reskey!==window._reskey){window._reskey=reskey;
    $('ressel').replaceChildren(...(s.resOptions||[]).map(o=>{
      const op=document.createElement('option');op.value=o.w+'/'+o.h;op.textContent=o.label;return op;}));}
  if(s.resW)$('ressel').value=s.resW+'/'+s.resH;
  // frame-rate dropdown
  const maxf=s.maxFps||2000;
  const allf=[24,25,30,48,50,60,96,100,120,150,200,240,300,360,500,750,1000,1500,2000,3000,5000].filter(r=>r<=maxf);
  if(!allf.includes(maxf))allf.push(maxf);
  const ratekey=allf.join(',');
  if(ratekey!==window._ratekey){window._ratekey=ratekey;
    $('ratesel').replaceChildren(...allf.map(r=>{
      const op=document.createElement('option');op.value=r;op.textContent=r+' fps'+(r===maxf?' (max)':'');return op;}));}
  $('ratesel').value=s.rate;
  // shutter dropdown
  if(!$('shutsel').dataset.built){$('shutsel').dataset.built='1';
    $('shutsel').replaceChildren(...[11.25,22.5,45,90,120,144,172.8,180,270,358].map(a=>{
      const op=document.createElement('option');op.value=a;op.textContent=a+'°';return op;}));}
  if(s.shutter)$('shutsel').value=[11.25,22.5,45,90,120,144,172.8,180,270,358].reduce((p,c)=>Math.abs(c-s.shutter)<Math.abs(p-s.shutter)?c:p);
  // partition dropdown
  if(!$('partsel').dataset.built){$('partsel').dataset.built='1';
    $('partsel').replaceChildren(...[1,2,4,8,16,32,64].map(n=>{
      const op=document.createElement('option');op.value=n;op.textContent=n;return op;}));}
  if(s.partitionCount)$('partsel').value=s.partitionCount;
  // auto-save
  $('autosave').textContent='Auto-save: '+(s.autosave?'ON':'off');
  $('autosave').className='wide'+(s.autosave?' on':'');
  // foot
  let f=s.status||'';
  if(s.queued)f+='\n'+s.queued+' download(s) queued';
  if(s.downloadStatus)f+='\n'+s.downloadStatus;
  $('foot').textContent=f;
 }catch(e){$('dot').className='dot off';$('foot').textContent='remote unreachable — is Phantom Control running?';}
}
setInterval(()=>{if(!scrubbing)poll();},600);poll();
previewStart();
</script>
</body></html>
"""#
}
