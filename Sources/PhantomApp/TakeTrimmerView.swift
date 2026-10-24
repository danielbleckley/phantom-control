import SwiftUI
import PhantomCore

/// In-window trim/preview panel for a single CineMag take — used by BOTH the
/// camera's Manage CineMag sheet and the CineStation window. Scrub the playhead
/// to preview any frame (fetched on demand), drag the IN/OUT handles to pick a
/// range, then download only that range. No SDI monitor needed.
struct TakeTrimmerView: View {
    let take: CameraModel.MagTake
    @StateObject private var session: MagScrubSession
    @Binding var trimIn: Int
    @Binding var trimOut: Int
    let onDownloadTrimmed: () -> Void
    let onClose: () -> Void

    @State private var playhead: Int
    @State private var playing = false
    @State private var playStride = 24
    @State private var playTimer: Timer?

    @ObservedObject private var theme = AppTheme.shared

    init(take: CameraModel.MagTake, host: String, iface: String?,
         grab: @escaping (CameraConnection, Int, Int, Int, Int) throws -> Data,
         trimIn: Binding<Int>, trimOut: Binding<Int>,
         onDownloadTrimmed: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.take = take
        _session = StateObject(wrappedValue: MagScrubSession(host: host, iface: iface, grab: grab))
        _trimIn = trimIn; _trimOut = trimOut
        self.onDownloadTrimmed = onDownloadTrimmed
        self.onClose = onClose
        _playhead = State(initialValue: trimIn.wrappedValue)
    }

    private var aspect: CGFloat {
        take.height > 0 ? CGFloat(take.width) / CGFloat(take.height) : 16.0 / 9.0
    }
    private var trimmedCount: Int { max(0, trimOut - trimIn + 1) }

    var body: some View {
        VStack(spacing: 8) {
            // Preview frame
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(theme.viewerBackdrop(0.0))
                if let img = session.frame {
                    Image(img, scale: 1, label: Text("preview"))
                        .resizable().aspectRatio(contentMode: .fit)
                }
                if session.loading {
                    ProgressView().controlSize(.small).tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
                if session.failed && session.frame == nil {
                    VStack(spacing: 4) {
                        Text("Couldn't fetch preview frame").font(.caption).foregroundStyle(.secondary)
                        if let e = session.lastError {
                            Text(e).font(.caption2).foregroundStyle(.orange)
                                .multilineTextAlignment(.center).padding(.horizontal, 10)
                        }
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 220)

            // Playhead readout
            HStack {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .help(playing ? "Pause" : "Play the trimmed range (best-effort preview)")
                Text("frame \(playhead)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("\(trimmedCount) frames  ·  \(String(format: "%.2fs", durationSeconds))")
                    .font(.caption.monospaced())
            }

            // The trim bar: track + selected region + playhead + IN/OUT handles.
            trimBar.frame(height: 30)

            // Actions
            HStack(spacing: 8) {
                Button("Mark In") { setIn(playhead) }
                    .help("Set the start of the range to the current frame")
                Button("Mark Out") { setOut(playhead) }
                    .help("Set the end of the range to the current frame")
                Button("Full clip") { setIn(take.firstFrame); setOut(take.lastFrame) }
                    .help("Reset the trim to the whole take")
                Spacer()
                Button("Close") { onClose() }
                Button {
                    stopPlay()
                    onDownloadTrimmed()
                } label: {
                    Label("Download \(trimmedCount) fr", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(trimmedCount < 1)
            }
            .font(.callout)
        }
        .padding(10)
        .background(theme.chrome(0.14), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { requestFrame(playhead) }
        .onDisappear { stopPlay(); session.close() }
    }

    // MARK: - Trim bar

    private var trimBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chrome(0.25)).frame(height: 6)
                // Selected region
                Capsule().fill(Color.purple.opacity(0.7))
                    .frame(width: max(2, x(trimOut, w) - x(trimIn, w)), height: 6)
                    .offset(x: x(trimIn, w))
                // Playhead
                Rectangle().fill(Color.white).frame(width: 2, height: 26)
                    .offset(x: x(playhead, w) - 1)
                // IN / OUT handles
                handle(color: .green).offset(x: x(trimIn, w) - 6)
                    .gesture(dragGesture(w) { setIn(frame($0, w)) })
                handle(color: .red).offset(x: x(trimOut, w) - 6)
                    .gesture(dragGesture(w) { setOut(frame($0, w)) })
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            // Tap/drag anywhere else scrubs the playhead.
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                scrubTo(frame(g.location.x, w))
            })
        }
    }

    private func handle(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: 12, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6), lineWidth: 1))
    }

    private func dragGesture(_ w: CGFloat, _ action: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in action(g.location.x) }
    }

    // MARK: - Frame math

    private func x(_ f: Int, _ w: CGFloat) -> CGFloat {
        let range = CGFloat(max(1, take.lastFrame - take.firstFrame))
        return (CGFloat(f - take.firstFrame) / range) * w
    }
    private func frame(_ px: CGFloat, _ w: CGFloat) -> Int {
        let range = CGFloat(max(1, take.lastFrame - take.firstFrame))
        let f = take.firstFrame + Int((max(0, min(px, w)) / w) * range)
        return min(max(f, take.firstFrame), take.lastFrame)
    }

    // MARK: - Actions

    private var durationSeconds: Double { take.fps > 0 ? Double(trimmedCount) / take.fps : 0 }

    private func scrubTo(_ f: Int) {
        playhead = f
        requestFrame(f)
    }
    private func setIn(_ f: Int) {
        trimIn = min(f, trimOut)
        scrubTo(trimIn)
    }
    private func setOut(_ f: Int) {
        trimOut = max(f, trimIn)
        scrubTo(trimOut)
    }
    private func requestFrame(_ f: Int) {
        session.request(cine: take.id, frame: f, width: take.width, height: take.height)
    }

    private func togglePlay() { playing ? stopPlay() : startPlay() }
    private func startPlay() {
        guard trimmedCount > 1 else { return }
        // Skip-play: advance the playhead by a chunk on a steady beat and let
        // the fetch engine render the latest position (it coalesces, so a slow
        // frame is skipped, never stalls). Chunk sized so the selection scans
        // through in ~30 s regardless of length.
        playStride = max(1, trimmedCount / 90)
        playing = true
        if playhead >= trimOut { playhead = trimIn }
        requestFrame(playhead)
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard playing else { return }
            var next = playhead + playStride
            if next > trimOut { next = trimIn }   // loop the selection
            playhead = next
            requestFrame(next)
        }
    }
    private func stopPlay() {
        playing = false
        playTimer?.invalidate(); playTimer = nil
    }
}
