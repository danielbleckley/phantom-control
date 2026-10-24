import Foundation
import Darwin

/// Raw-ethernet (`ximg`) 10-gigabit download receiver.
///
/// The camera, after an `ximg {...}` control command, blasts the requested
/// frames as raw L2 ethernet frames (EtherType `0x88B7`) straight at our NIC's
/// MAC — no TCP, no IP. This receiver pulls them off the wire through BPF
/// (`/dev/bpf*`), strips the 16-byte ximg header, and reassembles whole frames
/// in `seq` order using the `0x4080` start flag. Measured ~778 MB/s.
///
/// BPF works WITHOUT root on this Mac because Wireshark's ChmodBPF made
/// `/dev/bpf*` group `staff`/rw.
///
/// The hot path is allocation-free: one reusable kernel-sized read buffer, and
/// frame payload is `memcpy`'d straight into a caller-provided, pre-sized output
/// buffer (`cnt * frameBytes`). At 6 Gbit/s a slow consumer drops packets.
public final class XimgReceiver {

    // MARK: BPF ioctl request codes
    //
    // The `BIOC*` macros are `_IOW/_IOR/_IOWR` expansions that Swift's Darwin
    // overlay marks "unavailable: structure not supported", so we recompute them.
    // Verified at runtime against /dev/bpf on macOS 14 (en11, 10Gbase-T).

    private static let IOC_VOID: UInt = 0x2000_0000
    private static let IOC_OUT:  UInt = 0x4000_0000
    private static let IOC_IN:   UInt = 0x8000_0000
    private static func ioc(_ io: UInt, _ num: UInt, _ len: UInt) -> UInt {
        io | ((len & 0x1fff) << 16) | (UInt(UInt8(ascii: "B")) << 8) | num
    }
    private static let BIOCSBLEN     = ioc(IOC_IN | IOC_OUT, 102, 4)                              // _IOWR('B',102,u_int)
    private static let BIOCSETIF     = ioc(IOC_IN, 108, UInt(MemoryLayout<ifreq>.size))           // _IOW('B',108,struct ifreq)
    private static let BIOCIMMEDIATE = ioc(IOC_IN, 112, 4)                                        // _IOW('B',112,u_int)
    private static let BIOCSETF      = ioc(IOC_IN, 103, UInt(MemoryLayout<bpf_program>.size))     // _IOW('B',103,struct bpf_program)
    private static let BIOCSHDRCMPLT = ioc(IOC_IN, 117, 4)                                        // _IOW('B',117,u_int)
    private static let BIOCFLUSH     = ioc(IOC_VOID, 104, 0)                                      // _IO('B',104)
    private static let BIOCGBLEN     = ioc(IOC_OUT, 102, 4)                                       // _IOR('B',102,u_int)

    // MARK: Public types

    /// A network interface and its hardware (MAC) address.
    public struct NIC: Sendable {
        public let name: String
        public let mac: [UInt8]      // 6 bytes
        public let baudrate: UInt64  // link speed in bit/s (0 if unknown)
        /// Lowercase hex MAC with no separators — the `dest` form ximg wants.
        public var macHex: String { mac.map { String(format: "%02x", $0) }.joined() }
        public var isTenGig: Bool { baudrate >= 10_000_000_000 }
    }

    /// Outcome of receiving one ximg batch.
    public struct ReceiveResult {
        /// Number of distinct frame-starts (`0x4080`) observed.
        public var framesStarted: Int
        /// Batch-relative indices (0-based) of frames that lost packets or
        /// never completed — the caller should re-request these.
        public var badFrames: [Int]
        /// Total payload bytes copied into the output buffer.
        public var bytes: Int
        /// Count of packets the camera sent that we never saw (seq gaps).
        public var droppedPackets: Int
    }

    // MARK: State

    private let fd: Int32
    public let nic: NIC
    public let frameBytes: Int
    private let readBufLen: Int
    private let readBuf: UnsafeMutableRawPointer

    // MARK: Lifecycle

    /// Opens a free `/dev/bpf*`, binds it to `nic`, and installs the
    /// EtherType 0x88B7 + destination-MAC filter. `frameBytes` is the exact
    /// reassembled size of one frame (packed-10 bytes).
    public init(nic: NIC, frameBytes: Int, bufLen: Int = 4 << 20) throws {
        self.nic = nic
        self.frameBytes = frameBytes

        var opened: Int32 = -1
        for i in 0..<256 {
            let f = open("/dev/bpf\(i)", O_RDWR)
            if f >= 0 { opened = f; break }
            if errno == EBUSY { continue }       // device in use — try the next
        }
        guard opened >= 0 else {
            throw PhantomError.socketError("no free /dev/bpf* (errno \(errno)) — is ChmodBPF installed?")
        }
        self.fd = opened

        func fail(_ what: String) -> PhantomError {
            Darwin.close(opened)
            return PhantomError.socketError("\(what) errno \(errno)")
        }

        // Buffer length must be set before binding the interface.
        var blen = UInt32(bufLen)
        guard ioctl(opened, Self.BIOCSBLEN, &blen) >= 0 else { throw fail("BIOCSBLEN") }
        // Re-read the length the kernel actually granted — reads must use it.
        var granted: UInt32 = 0
        _ = ioctl(opened, Self.BIOCGBLEN, &granted)
        self.readBufLen = Int(granted > 0 ? granted : blen)

        var ifr = ifreq()
        withUnsafeMutableBytes(of: &ifr.ifr_name) { raw in
            for (i, c) in nic.name.utf8.enumerated() where i < raw.count { raw[i] = c }
        }
        guard ioctl(opened, Self.BIOCSETIF, &ifr) >= 0 else { throw fail("BIOCSETIF \(nic.name)") }

        var on: UInt32 = 1
        guard ioctl(opened, Self.BIOCIMMEDIATE, &on) >= 0 else { throw fail("BIOCIMMEDIATE") }
        // We never transmit on this fd; header-complete is irrelevant but harmless.
        _ = ioctl(opened, Self.BIOCSHDRCMPLT, &on)

        self.readBuf = UnsafeMutableRawPointer.allocate(byteCount: self.readBufLen, alignment: 16)

        do { try installFilter() }
        catch { Darwin.close(opened); self.readBuf.deallocate(); throw error }
    }

    deinit {
        Darwin.close(fd)
        readBuf.deallocate()
    }

    public func close() { Darwin.close(fd) }

    /// Installs a BPF program: accept iff EtherType == 0x88B7 AND dst MAC == ours.
    private func installFilter() throws {
        let m = nic.mac
        let macHi = (UInt32(m[0]) << 24) | (UInt32(m[1]) << 16) | (UInt32(m[2]) << 8) | UInt32(m[3])
        let macLo = (UInt32(m[4]) << 8) | UInt32(m[5])
        // Classic BPF opcodes: LD|H|ABS=0x28, LD|W|ABS=0x20, JMP|JEQ|K=0x15, RET|K=0x06
        var insns: [bpf_insn] = [
            bpf_insn(code: 0x28, jt: 0, jf: 0, k: 12),        // A = ethertype  [12]
            bpf_insn(code: 0x15, jt: 0, jf: 5, k: 0x88B7),    // if A != 0x88B7 -> reject
            bpf_insn(code: 0x20, jt: 0, jf: 0, k: 0),         // A = dst[0..3]  [0]
            bpf_insn(code: 0x15, jt: 0, jf: 3, k: macHi),     // if A != macHi  -> reject
            bpf_insn(code: 0x28, jt: 0, jf: 0, k: 4),         // A = dst[4..5]  [4]
            bpf_insn(code: 0x15, jt: 0, jf: 1, k: macLo),     // if A != macLo  -> reject
            bpf_insn(code: 0x06, jt: 0, jf: 0, k: 0x4_0000),  // accept (snap 256 KB)
            bpf_insn(code: 0x06, jt: 0, jf: 0, k: 0),         // reject
        ]
        try insns.withUnsafeMutableBufferPointer { buf in
            var prog = bpf_program(bf_len: UInt32(buf.count), bf_insns: buf.baseAddress)
            guard ioctl(fd, Self.BIOCSETF, &prog) >= 0 else {
                throw PhantomError.socketError("BIOCSETF errno \(errno)")
            }
        }
    }

    /// Discards any packets buffered in the kernel — call between batches so a
    /// previous stream's stragglers don't leak into the next read.
    public func flush() {
        var dummy: Int32 = 0
        _ = ioctl(fd, Self.BIOCFLUSH, &dummy)
    }

    // MARK: Receive

    /// Receives `cnt` frames belonging to `ssrc` into `out` (which must be at
    /// least `cnt * frameBytes`). Returns which frames are incomplete/corrupt.
    /// `idleTimeout` bounds how long we wait for the next packet before giving up.
    public func receive(ssrc: UInt32, cnt: Int,
                        into out: UnsafeMutableRawBufferPointer,
                        idleTimeout: Double = 2.0,
                        autoSsrc: Bool = false) -> ReceiveResult {
        precondition(out.count >= cnt * frameBytes, "output buffer too small")
        let dst = out.baseAddress!
        let fb = frameBytes
        // With autoSsrc (the CineStation's flash reads report no ssrc), latch
        // onto the ssrc of the first packet seen after flush; otherwise filter by
        // the given `ssrc`.
        var wantSsrc = ssrc
        var ssrcLocked = !autoSsrc

        var frameIndex = -1          // -1 until the first 0x4080 start flag
        var frameOffset = 0
        var framesStarted = 0
        var expectedSeq: UInt16 = 0
        var haveSeq = false
        var bad = Set<Int>()
        var totalBytes = 0
        var dropped = 0

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollMs = Int32(idleTimeout * 1000)

        readLoop: while true {
            // Done: every requested frame started and the last one is full.
            if framesStarted >= cnt && frameIndex == cnt - 1 && frameOffset >= fb { break }

            let pr = poll(&pfd, 1, pollMs)
            if pr <= 0 { break }     // idle timeout or poll error — stop

            let n = read(fd, readBuf, readBufLen)
            if n <= 0 {
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                break
            }

            var p = 0
            while p + 20 <= n {       // need a full bpf_hdr (20 bytes) to proceed
                let caplen = Int(readBuf.loadUnaligned(fromByteOffset: p + 8,  as: UInt32.self))
                let hdrlen = Int(readBuf.loadUnaligned(fromByteOffset: p + 16, as: UInt16.self))
                let pktStart = p + hdrlen
                let next = p + ((hdrlen + caplen + 3) & ~3)   // BPF_WORDALIGN
                // 14B ethernet + 16B ximg header + 2 zero pad bytes before pixel
                // data (the pad is constant 0x0000 on the wire — verified live).
                guard caplen >= 32, pktStart + 32 <= n else { p = next; continue }

                let h = pktStart + 14                          // ximg header start
                let flags   = beU16(h + 0)
                let seq     = beU16(h + 2)
                let pktSsrc = beU32(h + 8)
                if !ssrcLocked { wantSsrc = pktSsrc; ssrcLocked = true }   // lock onto first stream (autoSsrc)
                if pktSsrc != wantSsrc { p = next; continue }   // straggler from another stream

                let dataLen = caplen - 32
                let dataPtr = pktStart + 32

                // Packet-loss detection: seq increments +1 per packet across the
                // whole stream. A jump means the kernel/driver dropped frames.
                if haveSeq && seq != expectedSeq {
                    dropped += Int(seq &- expectedSeq)
                    if frameIndex >= 0 { bad.insert(frameIndex) }
                }
                expectedSeq = seq &+ 1
                haveSeq = true

                // 0x4080 = first packet of a frame; 0x4000 = continuation.
                if (flags & 0x0080) != 0 {
                    // The frame we were filling must have reached full size.
                    if frameIndex >= 0 && frameOffset < fb { bad.insert(frameIndex) }
                    frameIndex += 1
                    frameOffset = 0
                    framesStarted += 1
                    if frameIndex >= cnt { break readLoop }      // camera sent an extra start
                }

                if frameIndex >= 0 && dataLen > 0 {
                    let room = fb - frameOffset
                    let copy = min(dataLen, room)               // cap trailing padding
                    if copy > 0 {
                        memcpy(dst + frameIndex * fb + frameOffset, readBuf + dataPtr, copy)
                        frameOffset += copy
                        totalBytes += copy
                    }
                }
                p = next
            }
        }

        // Final frame completeness + any frames that never arrived.
        if frameIndex == cnt - 1 && frameOffset < fb { bad.insert(frameIndex) }
        for i in framesStarted..<cnt { bad.insert(i) }

        return ReceiveResult(framesStarted: framesStarted,
                             badFrames: bad.sorted(),
                             bytes: totalBytes,
                             droppedPackets: dropped)
    }

    // MARK: big-endian readers (1-byte aligned, no allocation)

    @inline(__always) private func beU16(_ off: Int) -> UInt16 {
        let b0 = readBuf.load(fromByteOffset: off,     as: UInt8.self)
        let b1 = readBuf.load(fromByteOffset: off + 1, as: UInt8.self)
        return (UInt16(b0) << 8) | UInt16(b1)
    }
    @inline(__always) private func beU32(_ off: Int) -> UInt32 {
        let b0 = readBuf.load(fromByteOffset: off,     as: UInt8.self)
        let b1 = readBuf.load(fromByteOffset: off + 1, as: UInt8.self)
        let b2 = readBuf.load(fromByteOffset: off + 2, as: UInt8.self)
        let b3 = readBuf.load(fromByteOffset: off + 3, as: UInt8.self)
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    // MARK: NIC discovery

    /// Finds the `en*` interface whose IPv4 subnet contains `cameraIP` — that is
    /// the link the camera blasts ximg frames down. Returns its name + MAC +
    /// link speed, or nil if no interface is on the camera's subnet.
    public static func autodetect(cameraIP: String) -> NIC? {
        var camAddr = in_addr()
        guard inet_pton(AF_INET, cameraIP, &camAddr) == 1 else { return nil }
        let cam = camAddr.s_addr

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        // Pass 1: the interface name whose IPv4 subnet contains the camera.
        var matchName: String?
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = cur.pointee.ifa_netmask else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var sin = sockaddr_in();  memcpy(&sin,  addr, MemoryLayout<sockaddr_in>.size)
            var smk = sockaddr_in();  memcpy(&smk,  mask, MemoryLayout<sockaddr_in>.size)
            if (sin.sin_addr.s_addr & smk.sin_addr.s_addr) == (cam & smk.sin_addr.s_addr) {
                matchName = name
                break
            }
        }
        guard let ifname = matchName else { return nil }
        return nic(named: ifname)
    }

    /// Looks up the MAC and link speed for a named interface via getifaddrs.
    public static func nic(named ifname: String) -> NIC? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var mac: [UInt8]?
        var baud: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == ifname,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_LINK) else { continue }
            addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                let nlen = Int(dl.pointee.sdl_nlen)
                let alen = Int(dl.pointee.sdl_alen)
                if alen == 6 {
                    withUnsafePointer(to: &dl.pointee.sdl_data) { tup in
                        tup.withMemoryRebound(to: CChar.self, capacity: nlen + alen) { base in
                            var bytes = [UInt8](repeating: 0, count: 6)
                            for i in 0..<6 { bytes[i] = UInt8(bitPattern: base[nlen + i]) }
                            mac = bytes
                        }
                    }
                }
            }
            if let data = cur.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self)
                baud = UInt64(d.pointee.ifi_baudrate)
            }
        }
        guard let m = mac else { return nil }
        return NIC(name: ifname, mac: m, baudrate: baud)
    }

    // MARK: - 10G readiness preflight

    /// Why the raw-ethernet (`ximg`) fast path is or isn't available right now.
    ///
    /// TWO independent things must both be true, and until now BOTH failed
    /// silently:
    ///   1. an `en*` interface on the camera's subnet, negotiated at 10G, and
    ///   2. read access to `/dev/bpf*`.
    /// On a stock Mac the bpf nodes are `root:wheel 0600`, so without
    /// Wireshark's ChmodBPF (or an equivalent LaunchDaemon) the receiver can
    /// never open and `downloadCine` quietly falls back to the ~7 MB/s TCP
    /// loop — announcing it only on stderr, invisible in a Finder-launched app.
    /// This lets the UI say so out loud instead.
    public struct TenGigStatus: Sendable {
        /// The interface sharing the camera's subnet, if any.
        public let nic: NIC?
        /// True if a `/dev/bpf*` node could be opened (or exists and is merely busy).
        public let bpfAvailable: Bool
        /// Human-readable reason when `bpfAvailable` is false.
        public let bpfError: String?

        /// The raw-ethernet path can physically run: an interface on the
        /// camera's subnet AND bpf access. Deliberately does NOT require a 10G
        /// link — ximg works on a 2.5/5G link too, just slower. This is the
        /// flag that should gate transport choice.
        public var pathCanRun: Bool { nic != nil && bpfAvailable }

        /// Everything is ideal: the path can run AND the link really is 10G.
        /// Use for display, not for gating.
        public var fastPathReady: Bool { pathCanRun && (nic?.isTenGig ?? false) }
        /// A real 10G link — not merely *some* interface on the camera's subnet.
        /// (`autodetect` alone returns 1G interfaces too, which is why the old
        /// `tenGigAvail` flag was wrong.)
        public var isTenGigLink: Bool { nic?.isTenGig ?? false }

        /// Negotiated link speed, formatted. "—" when there's no interface.
        public var linkSpeed: String {
            guard let nic, nic.baudrate > 0 else { return "—" }
            return nic.baudrate >= 1_000_000_000
                ? String(format: "%.0f Gbit/s", Double(nic.baudrate) / 1e9)
                : "\(nic.baudrate / 1_000_000) Mbit/s"
        }

        /// One-line, user-facing summary. Deliberately blunt about the reason.
        public var summary: String {
            guard let nic else {
                return "No network interface on the camera's subnet — check the cable and IP address."
            }
            if !bpfAvailable {
                return "\(nic.name) · \(linkSpeed) — 10G fast path unavailable (\(bpfError ?? "cannot open /dev/bpf")). Downloads fall back to the slower TCP path."
            }
            if !nic.isTenGig {
                return "\(nic.name) · \(linkSpeed) — not a 10G link. Downloads use the slower TCP path."
            }
            return "\(nic.name) · \(linkSpeed) — 10G fast path ready."
        }
    }

    /// Checks both preconditions for the `ximg` fast path without transferring
    /// anything. Cheap and side-effect-free: opens one bpf node read-only and
    /// closes it immediately. Safe to call on a timer or before a download.
    public static func preflight(cameraIP: String) -> TenGigStatus {
        let found = autodetect(cameraIP: cameraIP)

        var ok = false
        var sawBusy = false
        var err: String?
        for i in 0..<8 {
            let f = open("/dev/bpf\(i)", O_RDONLY)
            if f >= 0 { Darwin.close(f); ok = true; break }
            if errno == EBUSY { sawBusy = true; continue }   // exists + permitted, just in use
            err = String(cString: strerror(errno))
            break
        }
        // Every node busy still proves the nodes exist AND we're permitted to
        // open them — that's a pass, not a permission failure.
        if !ok && sawBusy && err == nil { ok = true }
        if !ok && err == nil { err = "no /dev/bpf* nodes found" }

        return TenGigStatus(nic: found, bpfAvailable: ok, bpfError: ok ? nil : err)
    }
}
