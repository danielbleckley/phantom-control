import Foundation
import Darwin

public enum PhantomError: Error, CustomStringConvertible {
    case connectFailed(String)
    case timeout(String)
    case socketError(String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .connectFailed(let s): return "connect failed: \(s)"
        case .timeout(let s): return "timeout: \(s)"
        case .socketError(let s): return "socket error: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        }
    }
}

public struct DiscoveredCamera {
    public let host: String
    public let reply: String        // e.g. "PH7 7115"
    public var controlPort: UInt16 {
        let parts = reply.split(separator: " ")
        return parts.count >= 2 ? UInt16(parts[1]) ?? 7115 : 7115
    }
    public var protocolVersion: String { String(reply.split(separator: " ").first ?? "PH7") }
}

/// One Phantom frame as raw sensor bytes (8 bits per pixel on Flex-class cameras).
public struct PhantomFrame {
    public let width: Int
    public let height: Int
    public let pixels: Data
}

/// Synchronous socket connection to a Phantom camera.
/// NOT thread safe — call all methods from a single serial queue/thread.
///
/// Data channel quirk: the camera does not listen on 7116. The client listens
/// locally and sends `startdata {port:N}`; the camera then connects back to us.
public final class CameraConnection {
    public let host: String
    public let port: UInt16
    /// Optional local interface (e.g. "en25") to pin this connection to, so a
    /// second device on a separate NIC — a CineStation on its own 10G port —
    /// runs alongside the camera without their traffic crossing. nil = let the
    /// OS routing table pick the egress NIC by destination IP (current default).
    public let boundInterface: String?
    private var ctrlFD: Int32 = -1
    private var dataFD: Int32 = -1

    public private(set) var lastResponse: String = ""

    public init(host: String, port: UInt16 = 7115, boundInterface: String? = nil) {
        self.host = host
        self.port = port
        self.boundInterface = boundInterface
    }

    deinit { close() }

    // MARK: - Discovery

    /// Probes specific IPs by opening control port 7115 and reading the model —
    /// finds cameras on subnets that UDP broadcast can't cross (e.g. a Flex on
    /// 100.100.x and a VEO on 172.16.x at the same time). Probes run in parallel.
    public static func probe(hosts: [String], timeout: Double = 1.2) -> [DiscoveredCamera] {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [DiscoveredCamera] = []
        for host in hosts {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let conn = CameraConnection(host: host)
                guard (try? conn.connect(timeout: timeout)) != nil else { return }
                defer { conn.close() }
                guard let resp = try? conn.command("get info.name", timeout: timeout),
                      resp.contains("name") else { return }
                // Reuse the discovery reply shape; the model name comes later.
                lock.lock(); found.append(DiscoveredCamera(host: host, reply: "PH 7115")); lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + timeout + 0.5)
        lock.lock(); defer { lock.unlock() }
        return found
    }

    /// Broadcasts `phantom?` on UDP 7380 and collects replies.
    public static func discover(timeout: Double = 1.5) -> [DiscoveredCamera] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = Array("phantom?".utf8)
        var targets: [String] = ["255.255.255.255"]
        // Also broadcast on each IPv4 interface's subnet broadcast address.
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                   let bcast = cur.pointee.ifa_dstaddr, (cur.pointee.ifa_flags & UInt32(IFF_BROADCAST)) != 0 {
                    var sin = sockaddr_in()
                    memcpy(&sin, bcast, MemoryLayout<sockaddr_in>.size)
                    if sin.sin_family == sa_family_t(AF_INET) {
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var a = sin.sin_addr
                        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
                        targets.append(String(cString: buf))
                    }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }

        for t in Set(targets) {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = UInt16(7380).bigEndian
            inet_pton(AF_INET, t, &dst.sin_addr)
            _ = withUnsafePointer(to: &dst) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: DiscoveredCamera] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 512)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            if n <= 0 { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = from.sin_addr
            inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            let reply = String(bytes: buf[0..<n], encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if reply.hasPrefix("PH") { found[ip] = DiscoveredCamera(host: ip, reply: reply) }
        }
        return Array(found.values)
    }

    // MARK: - Connection lifecycle

    public func connect(timeout: Double = 3.0) throws {
        ctrlFD = try Self.tcpConnect(host: host, port: port, timeout: timeout, boundInterface: boundInterface)
        setRecvTimeout(ctrlFD, seconds: 2.0)
        Self.disableSIGPIPE(ctrlFD)
    }

    /// A send() to a socket the camera has reset (power cycle, cable pull)
    /// raises SIGPIPE, which kills the process with no trace. Never again.
    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Pins a socket to a specific local interface so its traffic leaves/arrives
    /// on that NIC regardless of the routing table — the mechanism that lets a
    /// CineStation on a separate 10G port run alongside the camera. macOS uses
    /// IP_BOUND_IF (there is no SO_BINDTODEVICE on Darwin). No-op when the
    /// interface is nil, empty, or unknown, so the default path is unchanged.
    static func bindToInterface(_ fd: Int32, _ ifname: String?) {
        guard let ifname, !ifname.isEmpty else { return }
        var idx = if_nametoindex(ifname)
        guard idx != 0 else { return }
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
    }

    /// Opens the image data channel: listen locally, ask the camera to call back.
    public func startDataChannel(timeout: Double = 5.0) throws {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw PhantomError.socketError("listen socket") }
        defer { Darwin.close(listenFD) }
        Self.bindToInterface(listenFD, boundInterface)   // camera dials back on the pinned NIC
        var on: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = UInt16(7116).bigEndian
        var bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var boundPort: UInt16 = 7116
        if bound != 0 {
            // 7116 busy — let the kernel pick and tell the camera.
            addr.sin_port = 0
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw PhantomError.socketError("bind data port") }
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &actual) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = getsockname(listenFD, sa, &len)
                }
            }
            boundPort = UInt16(bigEndian: actual.sin_port)
        }
        guard listen(listenFD, 1) == 0 else { throw PhantomError.socketError("listen") }

        let resp = try command("startdata {port:\(boundPort)}")
        guard resp.contains("Ok") else { throw PhantomError.protocolError("startdata: \(resp)") }

        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else {
            throw PhantomError.timeout("camera did not connect back on data port")
        }
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { throw PhantomError.socketError("accept data") }
        // Large receive buffer for frame bursts.
        var bufSize: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setRecvTimeout(fd, seconds: 5.0)
        Self.disableSIGPIPE(fd)
        dataFD = fd
    }

    public var hasDataChannel: Bool { dataFD >= 0 }

    public func close() {
        if ctrlFD >= 0 { Darwin.close(ctrlFD); ctrlFD = -1 }
        if dataFD >= 0 { Darwin.close(dataFD); dataFD = -1 }
    }

    // MARK: - Commands

    /// Sends one LF-terminated command and reads the complete reply.
    @discardableResult
    public func command(_ cmd: String, timeout: Double = 2.5) throws -> String {
        guard ctrlFD >= 0 else { throw PhantomError.socketError("not connected") }
        let payload = Array((cmd + "\n").utf8)
        guard send(ctrlFD, payload, payload.count, 0) == payload.count else {
            throw PhantomError.socketError("send failed")
        }
        var buf = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let n = recv(ctrlFD, &chunk, chunk.count, 0)
            if n > 0 {
                buf.append(contentsOf: chunk[0..<n])
                if PhantomProtocol.isComplete(buf) { break }
            } else if n == 0 {
                throw PhantomError.socketError("control connection closed")
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if !buf.isEmpty && PhantomProtocol.isComplete(buf) { break }
                continue
            } else {
                throw PhantomError.socketError("recv errno \(errno)")
            }
        }
        guard !buf.isEmpty else { throw PhantomError.timeout("no reply to: \(cmd)") }
        let s = String(data: buf, encoding: .ascii) ?? ""
        lastResponse = s
        return s
    }

    public func get(_ variable: String) throws -> [String: PhValue] {
        PhantomProtocol.parse(try command("get \(variable)"))
    }

    // MARK: - Image transfer

    /// Grabs frames from a cine. cine -1 = live preview. Returns raw 8bpp sensor data.
    ///
    /// CRITICAL: once `img` is acknowledged the camera WILL push the full payload.
    /// Failing to drain it wedges the camera's Ethernet stack (verified — required
    /// a power cycle). On any error after the ack, drain the channel before throwing.
    /// `decimation` (1–16) asks the camera to send every Nth pixel in each
    /// axis — 1/N² the bytes, so the Ethernet preview runs much closer to a
    /// real video rate on the Flex's GigE link. The reply's `res` reports the
    /// reduced size and we read exactly that, so decode adapts automatically.
    public func grabFrame(cine: Int = -1, start: Int = 0, count: Int = 1,
                          decimation: Int = 1) throws -> PhantomFrame {
        guard dataFD >= 0 else { throw PhantomError.socketError("data channel not open") }
        let dec = max(1, min(decimation, 16))
        let decArg = dec > 1 ? ", decimation:\(dec)" : ""
        let resp = try command("img {cine:\(cine), start:\(start), cnt:\(count)\(decArg)}")
        let parsed = PhantomProtocol.parse(resp)
        guard resp.contains("Ok") else {
            throw PhantomError.protocolError("img refused: \(resp.prefix(120))")
        }
        guard let res = PhantomProtocol.find("res", in: parsed)?.sizeValue else {
            drainDataChannel()
            throw PhantomError.protocolError("img reply missing res: \(resp.prefix(120))")
        }
        let bytes = res.width * res.height * count
        do {
            let data = try readData(bytes)
            return PhantomFrame(width: res.width, height: res.height * count, pixels: data)
        } catch {
            drainDataChannel()
            throw error
        }
    }

    /// Live-safe single 16-bit (P16) grab: parses `res` from the reply (like
    /// grabFrame) so it self-sizes for the live preview, and returns the raw
    /// 16-bit bytes plus the dimensions. Same wedge rule — drain on error.
    public func grabFrame16(cine: Int = -1, start: Int = 0) throws -> (data: Data, width: Int, height: Int) {
        guard dataFD >= 0 else { throw PhantomError.socketError("data channel not open") }
        let resp = try command("img {cine:\(cine), start:\(start), cnt:1, fmt:P16}")
        let parsed = PhantomProtocol.parse(resp)
        guard resp.contains("Ok") else {
            throw PhantomError.protocolError("img refused: \(resp.prefix(120))")
        }
        guard let res = PhantomProtocol.find("res", in: parsed)?.sizeValue else {
            drainDataChannel()
            throw PhantomError.protocolError("img reply missing res: \(resp.prefix(120))")
        }
        do {
            let data = try readData(res.width * res.height * 2)
            return (data, res.width, res.height)
        } catch {
            drainDataChannel()
            throw error
        }
    }

    /// Grabs one or more 16-bit (P16) frames. Returns raw frame bytes (w*h*2 each).
    public func grabFramesP16(cine: Int, start: Int, count: Int,
                              width: Int, height: Int) throws -> Data {
        guard dataFD >= 0 else { throw PhantomError.socketError("data channel not open") }
        // Generous reply timeout: a camera serving live preview to the app
        // while downloading can lag several seconds on the control channel.
        let resp = try command("img {cine:\(cine), start:\(start), cnt:\(count), fmt:P16}", timeout: 12.0)
        guard resp.contains("Ok") else {
            throw PhantomError.protocolError("img refused: \(resp.prefix(120))")
        }
        let bytes = width * height * 2 * count
        do {
            // VEO-class cameras serve TCP images at only ~7 MB/s; budget the
            // timeout from byte count at a pessimistic 2 MB/s, not frame count.
            return try readData(bytes, timeout: 15.0 + Double(bytes) / 2_000_000.0)
        } catch {
            drainDataChannel()
            throw error
        }
    }

    /// Downloads a full cine from camera RAM into a .cine file.
    /// Calls `progress` with frames-done; returns the file URL on success.
    /// Set `cancelled` to true (from another thread) to stop cleanly.
    /// Reads CineMag-take frames from the CAMERA over the TCP data channel with
    /// `fmt:flash` (packed-10 pixels, fmt 266) — exactly how PCC reads a camera's
    /// mag (pcap-verified 2026-07-09). Mag takes are addressed as cine:0,1,…
    /// with the take's own (trigger-relative) frame numbers.
    /// WEDGE SAFETY: the data channel must already be open, and every error
    /// path drains — an unread flash push wedges the Flex's Ethernet stack.
    /// Cached flash-read command form once discovered, so a multi-frame download
    /// doesn't re-try both forms every frame. 0 = unknown · 1 = modern · 2 = legacy.
    private var flashForm = 0

    public func grabFramesFlash(cine: Int, start: Int, count: Int,
                                width: Int, height: Int) throws -> Data {
        guard dataFD >= 0 else { throw PhantomError.socketError("data channel not open") }
        let bytes = width * height * 10 / 8 * count
        // The command form differs by body. NEWER firmware (Flex 4K) REJECTS the
        // `fmt:flash` token ("ERR: missing }") and needs the numeric packed-10 code
        // `fmt:266` PLUS an explicit `from:mag` (else `cine:N` reads RAM cine N, not
        // the mag take). The Flex 2K served flash on bare `fmt:flash`. Verified live:
        // `img {cine:N, start:<neg frame>, cnt:1, fmt:266, from:mag}` reads the mag.
        // Try modern first, fall back to legacy; a refused img pushes no data so
        // switching forms is wedge-safe. Cache whichever wins.
        func cmd(_ form: Int) -> String {
            form == 2 ? "img {cine:\(cine), start:\(start), cnt:\(count), fmt:flash}"
                      : "img {cine:\(cine), start:\(start), cnt:\(count), fmt:266, from:mag}"
        }
        var lastResp = ""
        for form in (flashForm == 2 ? [2, 1] : [1, 2]) {
            let resp = try command(cmd(form), timeout: 12.0)
            if resp.contains("Ok") {
                flashForm = form
                do { return try readData(bytes, timeout: 20.0 + Double(bytes) / 2_000_000.0) }
                catch { drainDataChannel(); throw error }
            }
            lastResp = resp   // refused → no payload, safe to try the other form
        }
        throw PhantomError.protocolError("flash img refused: \(lastResp.prefix(120))")
    }

    /// TEST helper: send a raw `img {<body>}` and, if accepted, read up to
    /// `expectBytes` of payload (else drain). Returns bytes read, or throws the
    /// camera's error. Wedge-safe (a refused img pushes no data).
    public func probeImg(_ body: String, expectBytes: Int) throws -> Int {
        guard dataFD >= 0 else { throw PhantomError.socketError("data channel not open") }
        let resp = try command("img {\(body)}", timeout: 12.0)
        guard resp.contains("Ok") else {
            throw PhantomError.protocolError("refused: \(resp.prefix(140))")
        }
        do { return try readData(expectBytes, timeout: 20.0).count }
        catch { drainDataChannel(); throw error }
    }

    /// Downloads a CineMag take from the CAMERA to a .cine file over the TCP
    /// data channel (`img … fmt:flash` loop → packed-10 writer). The camera-side
    /// twin of the CineStation's ximg flash download, for rigs without a
    /// CineStation on hand. ~40 MB/s on the Flex's GigE port.
    public func downloadMagCine(cine: Int, to url: URL, meta: CineMetadata,
                                firstFrame: Int, lastFrame: Int,
                                batchSize: Int = 6,
                                cancelled: @escaping () -> Bool = { false },
                                progress: (Int, Int) -> Void) throws {
        let total = lastFrame - firstFrame + 1
        guard total > 0 else { throw PhantomError.protocolError("empty frame range") }
        let writer = try CineWriter(url: url, meta: meta, frameCount: total, layout: .packed10)
        defer { writer.finish() }
        let frameBytes = meta.width * meta.height * 10 / 8
        let effectiveBatch = max(1, min(batchSize, (24 << 20) / frameBytes))
        var done = 0
        while done < total {
            if cancelled() {
                try? FileManager.default.removeItem(at: url)
                throw PhantomError.protocolError("download cancelled")
            }
            let n = min(effectiveBatch, total - done)
            var blob: Data
            do {
                blob = try grabFramesFlash(cine: cine, start: firstFrame + done, count: n,
                                           width: meta.width, height: meta.height)
            } catch {
                // One retry per batch — a busy camera occasionally misses a beat.
                drainDataChannel()
                blob = try grabFramesFlash(cine: cine, start: firstFrame + done, count: n,
                                           width: meta.width, height: meta.height)
            }
            for i in 0..<n {
                try writer.appendPackedFrame(blob.subdata(in: i*frameBytes..<(i+1)*frameBytes))
            }
            done += n
            progress(done, total)
        }
    }

    /// Which transport the in-flight (or most recent) `downloadCine` is actually
    /// using — set the moment the decision is made, so a progress callback can
    /// read it live. Previously callers guessed from `XimgReceiver.autodetect`
    /// BEFORE the transfer, which is wrong twice over: autodetect matches 1G
    /// interfaces too, and it can't know whether /dev/bpf actually opened. A
    /// TCP transfer scored with the ximg bytes-per-pixel constant under-reports
    /// throughput by ~37%.
    public private(set) var lastDownloadUsedXimg = false

    /// Set when the ximg fast path was attempted and failed, so the UI can say
    /// why instead of silently running slow. Cleared on a successful fast path.
    public private(set) var ximgFallbackReason: String?

    public func downloadCine(cine: Int, to url: URL, meta: CineMetadata,
                             firstFrame: Int, lastFrame: Int,
                             batchSize: Int = 16,
                             useXimg: Bool? = nil,
                             throttlePercent: Int = 0,
                             cancelled: @escaping () -> Bool = { false },
                             progress: (Int, Int) -> Void) throws {
        let total = lastFrame - firstFrame + 1
        guard total > 0 else { throw PhantomError.protocolError("empty frame range") }

        // Fast path: if a 10G interface sits on the camera's subnet, blast the
        // cine over raw ethernet (ximg) instead of the ~7 MB/s TCP img loop.
        // `useXimg == nil` auto-selects; `true` requires it; `false` forces TCP.
        lastDownloadUsedXimg = false
        ximgFallbackReason = nil
        if useXimg != false, let nic = XimgReceiver.autodetect(cameraIP: host) {
            do {
                // Claim the fast path BEFORE transferring so the progress
                // callback scores bytes/pixel correctly while it runs.
                lastDownloadUsedXimg = true
                try downloadCineXimg(cine: cine, to: url, meta: meta,
                                     firstFrame: firstFrame, lastFrame: lastFrame,
                                     nic: nic, throttlePercent: throttlePercent,
                                     cancelled: cancelled, progress: progress)
                return
            } catch {
                lastDownloadUsedXimg = false
                if useXimg == true { throw error }
                // Auto mode: record the reason so the UI can show it, then fall
                // back to TCP. stderr alone is invisible in a Finder-launched app.
                ximgFallbackReason = "\(error)"
                FileHandle.standardError.write(Data("ximg fast path failed (\(error)); falling back to TCP\n".utf8))
            }
        } else if useXimg != false {
            ximgFallbackReason = "no interface on the camera's subnet"
        }

        let writer = try CineWriter(url: url, meta: meta, frameCount: total)
        defer { writer.finish() }
        let frameBytes = meta.width * meta.height * 2
        // Cap each request near 24MB — 4K frames are ~19MB each, so big
        // fixed frame-count batches blow past any sane timeout.
        let effectiveBatch = max(1, min(batchSize, (24 << 20) / frameBytes))
        var done = 0
        while done < total {
            if cancelled() {
                try? FileManager.default.removeItem(at: url)
                throw PhantomError.protocolError("download cancelled")
            }
            let n = min(effectiveBatch, total - done)
            var blob: Data
            do {
                blob = try grabFramesP16(cine: cine, start: firstFrame + done, count: n,
                                         width: meta.width, height: meta.height)
            } catch {
                // One retry per batch — a busy camera occasionally misses a beat.
                drainDataChannel()
                blob = try grabFramesP16(cine: cine, start: firstFrame + done, count: n,
                                         width: meta.width, height: meta.height)
            }
            for i in 0..<n {
                try writer.appendFrame(blob.subdata(in: i*frameBytes..<(i+1)*frameBytes))
            }
            done += n
            progress(done, total)
        }
    }

    // MARK: - ximg 10G fast path

    /// Result of sending one `ximg` command — the stream id and frame geometry.
    private struct XimgAck {
        let ssrc: UInt32
        let width: Int
        let height: Int
    }

    /// Issues an `ximg` command on the control channel and parses the reply.
    /// `ximg {cine:N, start:S, cnt:C, throttle:T, dest:<mac>}` →
    /// `Ok! { cine:1, res:4096 x 2304, fmt:266, ssrc:N }`.
    ///
    /// Deliberately NO `fmt:` field: that selects the cine's native 10-bit
    /// packed stream (fmt 266), which arrives complete and is the least data.
    /// Do NOT request `fmt:P16` — the camera then sends 12-bit packed pixels
    /// but truncates the burst at the 10-bit byte budget (f12=180 blocks),
    /// i.e. you get 5/6 of a scrambled frame (verified against the VEO4K).
    ///
    /// `throttle` is the camera's own pacing knob (verified live): percent of
    /// 10G line rate, ~11.5 MB/s per percent, saturating ~640 MB/s. 0/100 = full
    /// blast. Seance defaults to 25%. Use it when the receiver drops packets.
    private func ximgCommand(cine: Int, start: Int, cnt: Int, destMAC: String,
                             throttle: Int = 0, flash: Bool = false) throws -> XimgAck {
        let t = (1...99).contains(throttle) ? ", throttle:\(throttle)" : ""
        // CineMag takes (on a CineStation) read straight from flash with
        // `fmt:flash`; the live camera omits fmt (its native 10-bit packed,
        // fmt 266). Both arrive as the same packed-10 layout on the wire.
        let f = flash ? ", fmt:flash" : ""
        let resp = try command("ximg {cine:\(cine), start:\(start), cnt:\(cnt)\(t)\(f), dest:\(destMAC)}", timeout: 6.0)
        guard resp.contains("Ok") else {
            throw PhantomError.protocolError("ximg refused: \(resp.prefix(160))")
        }
        let parsed = PhantomProtocol.parse(resp)
        // The live camera reports an ssrc to filter its stream; the CineStation's
        // flash reply omits it (single stream) — fall back to 0 and let the
        // receiver lock onto the first packet's ssrc (autoSsrc) instead.
        let ssrc = PhantomProtocol.find("ssrc", in: parsed)?.intValue ?? 0
        let res = PhantomProtocol.find("res", in: parsed)?.sizeValue
        return XimgAck(ssrc: UInt32(truncatingIfNeeded: ssrc),
                       width: res?.width ?? 0, height: res?.height ?? 0)
    }

    /// Grabs ONE frame of a CineMag take over the ximg raw-ethernet path
    /// (`fmt:flash`) and returns the packed-10 pixel bytes — used for take
    /// thumbnails in the CineStation browser. One retry on packet loss.
    public func grabFlashFrame(cine: Int, frame: Int, width: Int, height: Int,
                               nic: XimgReceiver.NIC) throws -> Data {
        let frameBytes = width * height * 10 / 8
        let receiver = try XimgReceiver(nic: nic, frameBytes: frameBytes)
        defer { receiver.close() }
        var data = Data(count: frameBytes)
        for attempt in 0..<2 {
            receiver.flush()
            let ack = try ximgCommand(cine: cine, start: frame, cnt: 1,
                                      destMAC: nic.macHex, flash: true)
            let ok = data.withUnsafeMutableBytes { buf in
                receiver.receive(ssrc: ack.ssrc, cnt: 1, into: buf,
                                 idleTimeout: 1.5, autoSsrc: true).badFrames.isEmpty
            }
            if ok { return data }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw PhantomError.protocolError("thumbnail frame \(frame) of fc\(cine) lost packets")
    }

    /// Receives one ximg batch (`start..start+cnt`) into `buf` and retries any
    /// frames that lost packets, up to `maxRetries` times — each retry at a
    /// progressively lower camera throttle so recovery always converges.
    /// Throws if a frame still can't be recovered. `buf` must hold
    /// `cnt * receiver.frameBytes`.
    private func ximgFetchBatch(cine: Int, start: Int, cnt: Int, destMAC: String,
                                receiver: XimgReceiver,
                                buf: UnsafeMutableRawBufferPointer,
                                throttle: Int,
                                idleTimeout: Double, maxRetries: Int,
                                flash: Bool = false) throws -> (bytes: Int, dropped: Int) {
        let fb = receiver.frameBytes
        receiver.flush()
        let ack = try ximgCommand(cine: cine, start: start, cnt: cnt, destMAC: destMAC, throttle: throttle, flash: flash)
        var result = receiver.receive(ssrc: ack.ssrc, cnt: cnt, into: buf, idleTimeout: idleTimeout, autoSsrc: flash)
        var totalDropped = result.droppedPackets

        var retries = 0
        while !result.badFrames.isEmpty && retries < maxRetries {
            retries += 1
            // Drop to 25% (Seance's default), then halve again each round.
            let retryThrottle = max(5, (throttle > 0 ? throttle : 100) / (4 * retries))
            for idx in result.badFrames {
                let slice = UnsafeMutableRawBufferPointer(start: buf.baseAddress! + idx * fb, count: fb)
                receiver.flush()
                let a2 = try ximgCommand(cine: cine, start: start + idx, cnt: 1, destMAC: destMAC,
                                         throttle: retryThrottle, flash: flash)
                let r2 = receiver.receive(ssrc: a2.ssrc, cnt: 1, into: slice, idleTimeout: idleTimeout, autoSsrc: flash)
                totalDropped += r2.droppedPackets
                if r2.badFrames.isEmpty {
                    result.badFrames.removeAll { $0 == idx }
                }
            }
        }
        guard result.badFrames.isEmpty else {
            throw PhantomError.protocolError("ximg: frames \(result.badFrames.map { start + $0 }) lost packets after \(maxRetries) retries — lower the download throttle")
        }
        return (result.bytes, totalDropped)
    }

    /// Downloads a cine over the 10G raw-ethernet `ximg` path into a packed-10
    /// .cine file. Far faster than the TCP `img` loop (~778 MB/s vs ~7 MB/s).
    /// `nic` is the receiving interface (use `XimgReceiver.autodetect`).
    /// `throttlePercent` slows the camera's blast to curb packet loss (0 = off).
    public func downloadCineXimg(cine: Int, to url: URL, meta: CineMetadata,
                                 firstFrame: Int, lastFrame: Int,
                                 nic: XimgReceiver.NIC,
                                 batchSize: Int = 32,
                                 throttlePercent: Int = 0,
                                 maxRetries: Int = 3,
                                 flash: Bool = false,
                                 cancelled: @escaping () -> Bool = { false },
                                 progress: (Int, Int) -> Void) throws {
        let total = lastFrame - firstFrame + 1
        guard total > 0 else { throw PhantomError.protocolError("empty frame range") }

        let receiver = try XimgReceiver(nic: nic,
                                        frameBytes: CineWriter.PixelLayout.packed10
                                            .frameBytes(width: meta.width, height: meta.height))
        defer { receiver.close() }
        let fb = receiver.frameBytes
        let writer = try CineWriter(url: url, meta: meta, frameCount: total, layout: .packed10)
        defer { writer.finish() }

        let batch = max(1, batchSize)
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: batch * fb, alignment: 16)
        defer { buf.deallocate() }

        var done = 0
        while done < total {
            if cancelled() {
                writer.finish()
                try? FileManager.default.removeItem(at: url)
                throw PhantomError.protocolError("download cancelled")
            }
            let n = min(batch, total - done)
            let slice = UnsafeMutableRawBufferPointer(start: buf.baseAddress!, count: n * fb)
            _ = try ximgFetchBatch(cine: cine, start: firstFrame + done, cnt: n, destMAC: nic.macHex,
                                   receiver: receiver, buf: slice,
                                   throttle: throttlePercent,
                                   idleTimeout: 2.0, maxRetries: maxRetries, flash: flash)
            for i in 0..<n {
                let frameData = Data(bytes: buf.baseAddress! + i * fb, count: fb)
                try writer.appendPackedFrame(frameData)
            }
            done += n
            progress(done, total)
        }
    }

    /// Reads and discards whatever the camera is still sending on the data channel
    /// until it goes idle. Keeps an interrupted transfer from wedging the camera.
    public func drainDataChannel(idleTimeout: Double = 1.5) {
        guard dataFD >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        setRecvTimeout(dataFD, seconds: 0.25)
        var idle = 0.0
        while idle < idleTimeout {
            let n = recv(dataFD, &chunk, chunk.count, 0)
            if n > 0 { idle = 0 } else { idle += 0.25 }
            if n == 0 { break }
        }
        setRecvTimeout(dataFD, seconds: 5.0)
    }

    public func readData(_ n: Int, timeout: Double = 8.0) throws -> Data {
        var out = Data(capacity: n)
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < n {
            guard Date() < deadline else { throw PhantomError.timeout("data read \(out.count)/\(n)") }
            let want = min(chunk.count, n - out.count)
            let got = recv(dataFD, &chunk, want, 0)
            if got > 0 {
                out.append(contentsOf: chunk[0..<got])
            } else if got == 0 {
                throw PhantomError.socketError("data connection closed")
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw PhantomError.socketError("data recv errno \(errno)")
            }
        }
        return out
    }

    // MARK: - Helpers

    private func setRecvTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func tcpConnect(host: String, port: UInt16, timeout: Double,
                                   boundInterface: String? = nil) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PhantomError.socketError("socket()") }
        bindToInterface(fd, boundInterface)   // pin egress NIC before connect()
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw PhantomError.connectFailed("bad address \(host)")
        }
        // Non-blocking connect with poll so a powered-off camera fails fast.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS {
            let e = errno
            Darwin.close(fd)
            throw PhantomError.connectFailed("errno \(e) [immediate, host=\(host):\(port), iface=\(boundInterface ?? "none")]")
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else {
                Darwin.close(fd)
                throw PhantomError.timeout("connect \(host):\(port)")
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else {
                Darwin.close(fd)
                throw PhantomError.connectFailed("errno \(err) [after-poll, host=\(host):\(port), iface=\(boundInterface ?? "none")]")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}
