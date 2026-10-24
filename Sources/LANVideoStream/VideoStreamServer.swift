import Foundation
import Darwin
import CryptoKit
import CoreMedia
import CoreVideo

/// A self-contained, **app-agnostic** low-latency video streamer: feed it camera
/// / SDI pixel buffers and it serves a hardware **H.264** feed over a **WebSocket**
/// to any iPad/iPhone/desktop browser on the LAN (decoded with WebCodecs). It runs
/// its own listener + encode threads on its own port — nothing here knows about
/// Phantom. Drop it into any app:
///
/// ```swift
/// let stream = VideoStreamServer(port: 8990, token: "abc123")
/// stream.start()
/// // in your AVCaptureVideoDataOutput delegate:
/// stream.submit(pixelBuffer, pts: presentationTime)
/// ```
///
/// Wire protocol (binary WS messages): byte 0 = type — `0x00` config (JSON
/// `{codec,width,height,avcc(base64)}`), `0x01` keyframe, `0x02` delta — rest is
/// AVCC NAL data. A minimal viewer page is served at `/` (and `/<token>/`).
public final class VideoStreamServer {
    public let port: UInt16
    private let token: String?
    private var fd: Int32 = -1

    private var clients = Set<Int32>()
    private let lock = NSLock()
    private let encoder = H264Encoder()
    private let encodeQueue = DispatchQueue(label: "lanvideostream.encode", qos: .userInteractive)
    private var pending = 0
    private let pendingLock = NSLock()

    /// - Parameters:
    ///   - port: TCP port to listen on (binds all interfaces).
    ///   - token: optional path-prefix secret (`/<token>/h264`). Loopback skips it.
    public init(port: UInt16, token: String? = nil) {
        self.port = port
        self.token = token
        encoder.onFrame = { [weak self] payload, key, cfg in self?.emit(payload, key, cfg) }
    }

    /// Encoded only while ≥1 client is connected.
    public var clientCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    /// Target H.264 bitrate (bits/sec). Applies live to the running encoder.
    public func setBitrate(_ bitsPerSecond: Int) { encoder.setBitrate(bitsPerSecond) }

    /// Feed one frame. No-op when no client is watching. Encoding hops to a
    /// dedicated thread so it never blocks the capture thread; if the encoder is
    /// already busy the frame is dropped (keeps latency low).
    public func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard clientCount > 0 else { return }
        pendingLock.lock()
        if pending > 1 { pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        encodeQueue.async { [weak self] in
            self?.encoder.encode(pixelBuffer, pts: pts)
            self?.pendingLock.lock(); self?.pending -= 1; self?.pendingLock.unlock()
        }
    }

    public func start() {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); fd = -1; return }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        lock.lock(); let cs = clients; clients.removeAll(); lock.unlock()
        for c in cs { Darwin.close(c) }
    }

    // MARK: - Server

    private func acceptLoop() {
        while fd >= 0 {
            var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard c >= 0 else { continue }
            let loopback = peer.sin_addr.s_addr == in_addr_t(0x7F000001).bigEndian
            Thread.detachNewThread { [weak self] in self?.serve(c, loopback: loopback) }
        }
    }

    private func serve(_ client: Int32, loopback: Bool) {
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var rtv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buf, buf.count, 0)
        defer { /* fall through closes below if not a WS */ }
        if n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8),
           let line = req.split(separator: "\r\n").first {
            let parts = line.split(separator: " ")
            if parts.count >= 2 {
                let raw = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                let path = stripToken(raw, loopback: loopback)
                if let key = webSocketKey(req), path == "/h264" {
                    handleWebSocket(client, key: key)   // owns its lifecycle
                    return
                }
                if path == "/" || path.isEmpty {
                    writeHTTP(client, status: "200 OK", type: "text/html; charset=utf-8", body: Array(Self.viewerPage.utf8))
                    Darwin.close(client); return
                }
                writeHTTP(client, status: "404 Not Found", type: "text/plain", body: Array("not found".utf8))
            }
        }
        Darwin.close(client)
    }

    /// Strips the optional token prefix; returns the bare path, or "" if a token
    /// is required but missing (non-loopback).
    private func stripToken(_ rawPath: String, loopback: Bool) -> String {
        var path = rawPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard let token else { return path }
        let prefix = "/" + token
        if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count)) }
        if path == prefix { return "/" }
        return loopback ? path : ""   // missing/bad token from the network → no match
    }

    private func webSocketKey(_ req: String) -> String? {
        guard req.lowercased().contains("upgrade: websocket") else { return nil }
        for line in req.split(separator: "\r\n") where line.lowercased().hasPrefix("sec-websocket-key:") {
            return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func handleWebSocket(_ client: Int32, key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard sendAll(client, Array(resp.utf8)) else { Darwin.close(client); return }

        lock.lock(); clients.insert(client); lock.unlock()
        encoder.requestKeyframe()   // so this client can start decoding immediately

        var rbuf = [UInt8](repeating: 0, count: 1024)
        while fd >= 0 {
            let n = recv(client, &rbuf, rbuf.count, 0)
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    lock.lock(); let alive = clients.contains(client); lock.unlock()
                    if !alive { break }
                    continue
                }
                break
            }
        }
        lock.lock(); clients.remove(client); lock.unlock()
        Darwin.close(client)
    }

    // MARK: - Encoder output → fan-out

    private func emit(_ payload: [UInt8], _ keyframe: Bool, _ cfg: H264Encoder.Config?) {
        if keyframe, let cfg {
            let json = "{\"codec\":\"\(cfg.codec)\",\"width\":\(cfg.width),\"height\":\(cfg.height),"
                + "\"avcc\":\"\(Data(cfg.avcc).base64EncodedString())\"}"
            broadcast([0x00] + Array(json.utf8))
        }
        broadcast([keyframe ? 0x01 : 0x02] + payload)
    }

    private func broadcast(_ payload: [UInt8]) {
        lock.lock(); let fds = Array(clients); lock.unlock()
        guard !fds.isEmpty else { return }
        let frame = wsFrame(payload)
        for c in fds where !sendAll(c, frame) {
            lock.lock(); clients.remove(c); lock.unlock()
        }
    }

    private func wsFrame(_ payload: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0x82]   // FIN + binary
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n <= 0xFFFF { f.append(126); f.append(UInt8(n >> 8)); f.append(UInt8(n & 0xFF)) }
        else { f.append(127); for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((UInt64(n) >> s) & 0xFF)) } }
        f += payload
        return f
    }

    @discardableResult
    private func sendAll(_ client: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(client, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func writeHTTP(_ client: Int32, status: String, type: String, body: [UInt8]) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        sendAll(client, Array(head.utf8) + body)
    }

    /// Minimal turnkey viewer (so a host app gets a working page for free). Apps
    /// with their own UI (like Phantom) point their own `<canvas>` at `/h264`.
    static let viewerPage = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;background:#000;height:100%}canvas{width:100%;height:100%;object-fit:contain}</style>
    <canvas id=c></canvas><script>
    const c=document.getElementById('c');if(!('VideoDecoder'in window)){document.body.innerHTML='WebCodecs not supported (needs iOS 17+/modern Chrome)';}
    let dec=new VideoDecoder({output:f=>{if(c.width!==f.displayWidth){c.width=f.displayWidth;c.height=f.displayHeight;}c.getContext('2d').drawImage(f,0,0);f.close();},error:()=>{}}),cfg=false,ts=0;
    const ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+location.pathname.replace(/[^/]*$/,'')+'h264');ws.binaryType='arraybuffer';
    ws.onmessage=e=>{const a=new Uint8Array(e.data),t=a[0],b=a.subarray(1);
     if(t===0){const j=JSON.parse(new TextDecoder().decode(b));dec.configure({codec:j.codec,description:Uint8Array.from(atob(j.avcc),x=>x.charCodeAt(0)),optimizeForLatency:true});cfg=true;}
     else if(cfg){try{dec.decode(new EncodedVideoChunk({type:t===1?'key':'delta',timestamp:ts++,data:b}));}catch(_){}}};
    </script>
    """
}
