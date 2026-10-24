import Foundation
import AppKit
import PhantomCore

/// On-demand single-frame scrubber for a CineMag take — powers the in-window
/// trim preview in BOTH mag browsers. Holds its own camera connection for the
/// life of the trimmer, and fetches one frame at a time, coalescing rapid scrub
/// requests to the newest position (so dragging the playhead never queues a
/// backlog). Frame transport is a closure so the camera (TCP `img flash`) and
/// the CineStation (10G `ximg flash`) share this one engine.
@MainActor
final class MagScrubSession: ObservableObject {
    @Published var frame: CGImage?
    @Published var frameNumber = 0
    @Published var loading = false
    @Published var failed = false
    /// The last fetch error, surfaced in the trimmer so a failed preview says WHY.
    @Published var lastError: String?

    private let host: String
    private let iface: String?
    /// (connection, cine, frame, width, height) -> packed-10 pixel bytes.
    private let grab: (CameraConnection, Int, Int, Int, Int) throws -> Data
    private let q = DispatchQueue(label: "phantom.magscrub")
    // Touched only on `q` (serial) — safe.
    nonisolated(unsafe) private var conn: CameraConnection?
    private var pending: (cine: Int, frame: Int, w: Int, h: Int)?
    private var running = false

    init(host: String, iface: String?,
         grab: @escaping (CameraConnection, Int, Int, Int, Int) throws -> Data) {
        self.host = host; self.iface = iface; self.grab = grab
    }

    /// Show the frame at `frame` of take `cine`. Latest request wins.
    func request(cine: Int, frame: Int, width: Int, height: Int) {
        frameNumber = frame
        pending = (cine, frame, width, height)
        loading = true
        pump()
    }

    private func pump() {
        guard !running, let job = pending else { return }
        pending = nil
        running = true
        let host = self.host, iface = self.iface, grab = self.grab
        q.async { [weak self] in
            guard let self else { return }
            var img: CGImage?
            var ok = false
            var err: String?
            do {
                if self.conn == nil {
                    let c = CameraConnection(host: host, boundInterface: iface)
                    try c.connect(); try c.startDataChannel()
                    self.conn = c
                }
                if let c = self.conn {
                    let packed = try grab(c, job.cine, job.frame, job.w, job.h)
                    img = MagOffload.developThumbnail(packed10: packed, width: job.w, height: job.h, maxWidth: 760)
                    ok = img != nil
                    if !ok { err = "developed no image from \(packed.count) bytes at \(job.w)×\(job.h)" }
                }
            } catch {
                self.conn?.close(); self.conn = nil
                err = "\(error)"
            }
            Task { @MainActor in
                self.running = false
                if let img { self.frame = img; self.lastError = nil }
                self.failed = !ok && self.frame == nil
                if !ok, let err { self.lastError = err }
                if self.pending != nil { self.pump() }   // a newer scrub arrived
                else { self.loading = false }
            }
        }
    }

    func close() {
        let c = conn
        q.async { c?.close() }
        conn = nil
        frame = nil; pending = nil; loading = false; running = false
    }
}
