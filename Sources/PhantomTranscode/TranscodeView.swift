import SwiftUI
import UniformTypeIdentifiers
import PhantomCore

struct TranscodeView: View {
    @EnvironmentObject var model: TranscodeQueueModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            Divider()
            HStack(spacing: 0) {
                queueColumn
                    .frame(minWidth: 380)
                Divider()
                detailRail
                    .frame(width: 360)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    // MARK: settings bar

    private var settingsBar: some View {
        HStack(spacing: 14) {
            Picker("Codec", selection: $model.codec) {
                ForEach(GPUTranscoder.Codec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 210)
            .onChange(of: model.codec) { model.refreshEncoderNote() }

            Picker("Size", selection: $model.resolution) {
                ForEach(GPUTranscoder.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 130)
            .help("Output resolution. Downscales from the source; never upscales.")

            Picker("Quality", selection: $model.quality) {
                ForEach(GPUTranscoder.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            .disabled(model.codec.isProRes)
            .help(model.codec.isProRes
                  ? "ProRes data rate is fixed by codec + resolution."
                  : "Compression quality for H.264 / HEVC.")

            Button { chooseOutputFolder() } label: {
                Label(model.outputFolder?.lastPathComponent ?? "Beside source", systemImage: "folder")
            }
            .help("Output folder. Default: next to each .cine file.")

            Spacer()

            Text(model.encoderNote)
                .font(.caption.monospaced())
                .foregroundStyle(model.encoderNote.contains("hardware") ? .green : .orange)

            if model.isRunning {
                Button(role: .destructive) { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { model.startSelected() } label: { Label("Export Selected", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!(model.selectedJob?.canRun ?? false))
                Button { model.startAll() } label: { Label("Export All", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.jobs.contains { $0.canRun })
            }
        }
        .padding(12)
        .background(Color(white: 0.15))
    }

    // MARK: queue

    private var queueColumn: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job, selected: job.id == model.selection)
                                .onTapGesture { model.selection = job.id }
                                .contextMenu {
                                    Button("Export This File") {
                                        model.selection = job.id; model.export(job)
                                    }
                                    .disabled(model.isRunning || !job.canRun)
                                    Button("Export All") { model.startAll() }
                                        .disabled(model.isRunning || !model.jobs.contains { $0.canRun })
                                    Divider()
                                    if let out = job.outputURL {
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([out])
                                        }
                                    }
                                    Button("Remove", role: .destructive) { model.remove(job) }
                                        .disabled(job.isActive)
                                }
                        }
                    }
                    .padding(8)
                }
                VStack(spacing: 6) {
                    if let status = model.stitchStatus {
                        HStack(spacing: 8) {
                            if model.isRunning { ProgressView(value: model.stitchProgress).frame(width: 120) }
                            Text(status).font(.caption.monospaced())
                                .foregroundStyle(status.hasPrefix("✓") ? .green : .secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    HStack {
                        Button("Add Files…") { addPanel() }
                        Menu {
                            Button("By File Name") { model.exportStitched(byDate: false) }
                            Button("By Date Shot") { model.exportStitched(byDate: true) }
                        } label: {
                            Label("Export Timeline", systemImage: "film.stack")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 150)
                        .disabled(model.isRunning || !model.canStitch)
                        .help("Stitch every clip into one back-to-back .mov (for Frame.io review). Uses the current codec & size.")
                        Button { model.exportReport() } label: { Label("Report…", systemImage: "doc.text") }
                            .disabled(!model.canReport)
                            .help("Save a PDF report (thumbnails + specs + totals) of the batch.")
                        Spacer()
                        Button("Clear Finished") { model.clearFinished() }
                            .disabled(!model.jobs.contains { $0.status == .done })
                    }
                }
                .padding(8)
                .background(Color(white: 0.14))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Drop Phantom .cine files here").font(.title3)
            Text("Vision Research .cine → ProRes / H.264 / HEVC\nGPU debayer + hardware encode")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Add Files…") { addPanel() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: detail rail

    @ViewBuilder
    private var detailRail: some View {
        if let job = model.selectedJob {
            JobDetail(job: job).environmentObject(model).id(job.id)
        } else {
            VStack { Text("No file selected").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: drop + panels

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.addFiles(urls) }
    }

    private func addPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cine") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Phantom .cine files to transcode"
        panel.begin { resp in
            guard resp == .OK else { return }
            model.addFiles(panel.urls)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose an output folder (or cancel to write beside each source)"
        panel.begin { resp in
            model.outputFolder = resp == .OK ? panel.url : model.outputFolder
        }
    }
}

// MARK: - job row

private struct JobRow: View {
    @ObservedObject var job: TranscodeJob
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black
                if let thumb = job.thumbnail {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 84, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent).lineLimit(1).font(.system(size: 13, weight: .medium))
                if let info = job.info {
                    Text("\(info.width)×\(info.height) · \(job.trimmedCount) fr · \(info.realBPP)-bit \(info.isColor ? "color" : "mono")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                statusLine
            }
            Spacer()
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.22) : Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var statusLine: some View {
        switch job.status {
        case .running:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: job.progress).frame(maxWidth: 220)
                Text(String(format: "%.0f%% · %.0f fps · %.0f MB/s", job.progress * 100, job.fps, job.mbPerSec))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        case .done:
            Text("✓ \(job.resultSummary ?? "Done")").font(.caption2.monospaced()).foregroundStyle(.green)
        case .failed(let m):
            Text("⚠︎ \(m)").font(.caption2).foregroundStyle(.orange).lineLimit(1)
        default:
            Text(job.status.label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - detail rail content

private struct JobDetail: View {
    @ObservedObject var job: TranscodeJob
    @EnvironmentObject var model: TranscodeQueueModel
    @State private var playhead = 0
    @State private var previewImage: CGImage?
    @State private var lastScrub = Date.distantPast
    @State private var isPlaying = false
    @State private var previewBusy = false
    @State private var playTimer: Timer?

    private var maxFrame: Int { max(job.frameCount - 1, 0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(job.url.lastPathComponent).font(.headline).lineLimit(2)

                ZStack {
                    Color.black
                    if let img = previewImage ?? job.thumbnail {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if job.info != nil {
                    timelineSection
                    Divider()
                    outputSummary
                    Divider()
                    metadataSection
                }

                if let out = job.outputURL, job.status == .done {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: {
                        Label("Reveal output", systemImage: "magnifyingglass")
                    }
                }
            }
            .padding(14)
        }
        .onAppear { playhead = job.inFrame; requestPreview(job.inFrame, force: true) }
        .onDisappear { stopPlay() }
    }

    // MARK: timeline (PVP-style: drag in/out handles, scrub playhead)

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineTrim(job: job, playhead: $playhead) { frame in scrub(to: frame) }
                .frame(height: 30)
                .disabled(job.isActive)

            HStack(spacing: 6) {
                Button { setIn() } label: { Text("⟦ In").font(.caption.bold()) }
                    .tint(.yellow).keyboardShortcut("i", modifiers: [])
                    .help("Set In point at the playhead")
                Spacer()
                Button { jump(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.plain).help("Go to start")
                Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(.plain).keyboardShortcut(.leftArrow, modifiers: [])
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(.plain).keyboardShortcut(.rightArrow, modifiers: [])
                Button { jump(to: maxFrame) } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.plain).help("Go to end")
                Spacer()
                Button { setOut() } label: { Text("Out ⟧").font(.caption.bold()) }
                    .tint(.yellow).keyboardShortcut("o", modifiers: [])
                    .help("Set Out point at the playhead")
            }
            .disabled(job.isActive)

            HStack {
                Text("frame \(playhead)").font(.caption.monospaced()).foregroundStyle(.white)
                Spacer()
                Text("in/out \(job.inFrame)–\(job.outFrame)").font(.caption.monospaced()).foregroundStyle(.yellow)
            }
            Text("\(job.trimmedCount) of \(job.frameCount) frames selected")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: output summary (resolution + estimated size)

    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let dims = model.outputDimensions(for: job) {
                row("Output", "\(dims.w) × \(dims.h)  ·  \(model.codec.rawValue)")
            }
            if let bytes = model.estimatedBytes(for: job) {
                HStack {
                    Text("Est. size").foregroundStyle(.secondary)
                    Spacer()
                    Text("≈ \(formatBytes(bytes))").foregroundStyle(.white)
                }
            }
        }
        .font(.caption.monospaced())
    }

    private var metadataSection: some View {
        let info = job.info!
        return VStack(alignment: .leading, spacing: 3) {
            row("Source", "\(info.width) × \(info.height)")
            row("Frames", "\(info.frameCount)")
            row("Recorded", "\(Int(info.frameRate)) fps")
            row("Output rate", "\(Int(info.playbackFPS)) fps")
            row("Format", "\(info.realBPP)-bit \(info.isColor ? "color (CFA \(info.cfa))" : "mono")")
            if !info.cameraModel.isEmpty { row("Camera", "\(info.cameraModel) #\(info.serial)") }
        }
        .font(.caption.monospaced())
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }

    // MARK: scrub + trim actions

    private func scrub(to frame: Int) {
        stopPlay()
        playhead = min(max(frame, 0), maxFrame)
        // Throttle live preview during drag; the reader is cached so each
        // render is cheap, but we don't need more than ~20 Hz.
        let now = Date()
        if now.timeIntervalSince(lastScrub) > 0.045 {
            lastScrub = now
            requestPreview(playhead, force: false)
        }
    }

    private func step(_ delta: Int) {
        stopPlay()
        playhead = min(max(playhead + delta, 0), maxFrame)
        requestPreview(playhead, force: true)
    }

    private func jump(to frame: Int) {
        stopPlay()
        playhead = min(max(frame, 0), maxFrame)
        requestPreview(playhead, force: true)
    }

    private func setIn() { job.inFrame = min(playhead, job.outFrame) }
    private func setOut() { job.outFrame = max(playhead, job.inFrame) }

    // MARK: playback (loops the whole clip at its native rate)

    private func togglePlay() { isPlaying ? stopPlay() : startPlay() }

    private func startPlay() {
        guard !job.isActive, maxFrame > 0 else { return }
        isPlaying = true
        let fps = max(job.info?.playbackFPS ?? 24, 1)
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
            tickPlayback()
        }
    }

    private func stopPlay() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }

    private func tickPlayback() {
        // Advance on the clock; drop the render if the previous one is still
        // in flight so playback keeps time instead of backing up.
        playhead = playhead >= maxFrame ? 0 : playhead + 1
        guard !previewBusy else { return }
        previewBusy = true
        model.preview.render(url: job.url, frame: playhead) { _, img in
            previewBusy = false
            if let img { previewImage = img }
        }
    }

    private func requestPreview(_ frame: Int, force: Bool) {
        model.preview.render(url: job.url, frame: frame) { rendered, img in
            if let img, (force || rendered == playhead) { previewImage = img }
        }
    }
}

// MARK: - timeline component

/// Single timeline with draggable gold In/Out handles, a green selected
/// region, and a white scrub playhead — the Phantom Video Player feel.
private struct TimelineTrim: View {
    @ObservedObject var job: TranscodeJob
    @Binding var playhead: Int
    let onScrub: (Int) -> Void

    var body: some View {
        let maxFrame = max(job.frameCount - 1, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let xOf: (Int) -> CGFloat = { v in
                guard w > 0 else { return 0 }
                let f = CGFloat(v) / CGFloat(maxFrame) * w
                return f.isFinite ? min(max(f, 0), w) : 0
            }
            let frameAt: (CGFloat) -> Int = { px in
                guard w > 0 else { return 0 }
                return Int((Double(min(max(px, 0), w) / w) * Double(maxFrame)).rounded())
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.25))
                    .frame(height: 12).offset(y: 9)
                Rectangle().fill(Color.green.opacity(0.35))
                    .frame(width: max(xOf(job.outFrame) - xOf(job.inFrame), 0), height: 12)
                    .offset(x: xOf(job.inFrame), y: 9)
                // In handle (gold)
                handle.offset(x: xOf(job.inFrame) - 9)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let f = min(frameAt(v.location.x), job.outFrame)
                        job.inFrame = f; playhead = f; onScrub(f)
                    })
                // Out handle (gold)
                handle.offset(x: xOf(job.outFrame) - 9)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let f = max(frameAt(v.location.x), job.inFrame)
                        job.outFrame = f; playhead = f; onScrub(f)
                    })
                // Playhead (white)
                Rectangle().fill(.white).frame(width: 2, height: 28)
                    .offset(x: xOf(playhead) - 1, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onScrub(frameAt(v.location.x))
            })
        }
    }

    private var handle: some View {
        Capsule().fill(.yellow)
            .frame(width: 6, height: 26)
            .frame(width: 18, height: 30)
            .contentShape(Rectangle())
    }
}
