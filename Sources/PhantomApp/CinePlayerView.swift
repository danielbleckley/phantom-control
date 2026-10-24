import SwiftUI
import AVFoundation
import PhantomCore

/// Standalone window that plays a .cine file from disk and exports it to
/// ProRes/H.264 .mov — the "view Phantom recordings without PCC" window.
struct CinePlayerView: View {
    @StateObject private var model: CinePlayerModel
    @ObservedObject private var theme = AppTheme.shared

    init(url: URL) {
        _model = StateObject(wrappedValue: CinePlayerModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                viewer
                Divider()
                rightRail
                    .frame(width: 280)
            }
            Divider()
            transportBar
        }
        .frame(minWidth: 980, minHeight: 600)
        // Window CHROME, not an image surround — this sits under the 280pt right
        // rail and the transport bar. The picture has its own viewerBackdrop.
        .background(theme.chrome(0.12))
        .themed()
        .navigationTitle(model.url.lastPathComponent)
        .onDisappear { model.shutdown() }
    }

    private var viewer: some View {
        ZStack {
            theme.viewerBackdrop(0.0)
            if let img = model.image {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let err = model.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text(err)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
            } else {
                ProgressView("Opening…")
            }
        }
    }

    // MARK: transport

    private var transportBar: some View {
        let frameCount = max((model.info?.frameCount ?? 1), 1)
        return VStack(spacing: 8) {
            // timeline: white playhead over a simple track
            GeometryReader { geo in
                let w = geo.size.width
                let frac = CGFloat(model.frameIndex) / CGFloat(max(frameCount - 1, 1))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(theme.chrome(0.25))
                        .frame(height: 12).offset(y: 7)
                    Rectangle().fill(.white)
                        .frame(width: 2, height: 26)
                        .offset(x: frac * w - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.stop()
                    let f = Double(min(max(v.location.x / w, 0), 1)) * Double(frameCount - 1)
                    model.showFrame(Int(f))
                })
            }
            .frame(height: 28)

            HStack(spacing: 10) {
                Spacer()
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(.plain)
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(.plain)
                Button { model.loopPlayback.toggle() } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(model.loopPlayback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Loop playback")
                Spacer()
                Text("\(model.frameIndex + 1) / \(frameCount)")
                    .font(.caption.monospaced())
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(10)
        .background(theme.chrome(0.15))
    }

    // MARK: right rail

    private var rightRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let info = model.info {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.url.lastPathComponent).font(.headline).lineLimit(1)
                        Text("\(info.width) × \(info.height) — \(info.frameCount) frames")
                            .font(.caption.monospaced())
                        Text("recorded \(Int(info.frameRate)) fps · \(info.realBPP)-bit \(info.isColor ? "color" : "mono")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !info.cameraModel.isEmpty {
                            Text("\(info.cameraModel)  #\(info.serial)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    settingsRow("Play fps") {
                        TextField("fps", value: $model.playbackFPS, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if model.isPlaying { model.play() } }
                        Text(String(format: "%.1fs", Double(info.frameCount) / max(model.playbackFPS, 1)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                    lookPanel
                    Divider()
                    exportPanel
                }
            }
            .padding(12)
        }
        .background(theme.chrome(0.16))
    }

    private var lookPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image").font(.caption).foregroundStyle(.secondary)
            Button {
                model.autoWhiteBalance()
            } label: {
                Label("Auto White Balance", systemImage: "circle.lefthalf.filled")
                    .frame(maxWidth: .infinity)
            }
            settingsRow("WB Red") {
                Slider(value: $model.wbRed, in: 0.5...3.0)
                    .onChange(of: model.wbRed) { _, _ in model.rerender() }
                Text(String(format: "%.2f", model.wbRed)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("WB Blue") {
                Slider(value: $model.wbBlue, in: 0.5...3.0)
                    .onChange(of: model.wbBlue) { _, _ in model.rerender() }
                Text(String(format: "%.2f", model.wbBlue)).font(.caption.monospaced()).frame(width: 36)
            }
            settingsRow("Gain") {
                Slider(value: $model.gain, in: 0.5...4.0)
                    .onChange(of: model.gain) { _, _ in model.rerender() }
                Text(String(format: "%.2f", model.gain)).font(.caption.monospaced()).frame(width: 36)
            }
            Text("These bake into the exported .mov too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export .mov").font(.caption).foregroundStyle(.secondary)
            if let p = model.exportProgress {
                ProgressView(value: p)
                HStack {
                    Text(model.exportStatus).font(.caption2.monospaced()).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancelExport() }.font(.caption)
                }
            } else {
                Picker("Codec", selection: $model.exportCodec) {
                    ForEach(CineTranscoder.Codec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                settingsRow("Out fps") {
                    TextField("fps", value: $model.exportFPS, format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("24 = slow motion").font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    runExport()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                if !model.exportStatus.isEmpty {
                    Text(model.exportStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = model.url.deletingLastPathComponent()
        panel.nameFieldStringValue = model.url.deletingPathExtension().lastPathComponent + ".mov"
        panel.begin { resp in
            guard resp == .OK, let out = panel.url else { return }
            model.export(to: out)
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .frame(width: 64, alignment: .leading)
                .font(.callout)
            content()
        }
    }
}
