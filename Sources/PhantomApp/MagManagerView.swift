import SwiftUI
import AppKit

/// CineMag media manager — the camera-side offload station. Same treatment as
/// the CineStation window: live take thumbnails, per-take + Download-All with
/// verify / proxy / clip-PDF / convert options, a combined DIT report, and
/// per-take delete / full erase (friction-heavy — every delete confirms, the
/// full erase requires typing ERASE).
struct MagManagerSheet: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete: CameraModel.MagTake?
    @State private var eraseField = ""
    @State private var showErase = false
    @State private var trimmingTake: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            saveBar
            optionsBar
            actionBar
            Divider()
            capacityBar
                .padding(.horizontal, 12).padding(.vertical, 6)

            if let res = model.magOpResult {
                Text(res)
                    .font(.caption)
                    .foregroundStyle(res.contains("FAILED") || res.contains("failed") || res.contains("⚠️") ? .orange : .green)
                    .lineLimit(2)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }

            if model.magTakes.isEmpty {
                empty(model.magInfo.isEmpty ? "No CineMag or empty" : model.magInfo)
            } else {
                List(model.magTakes) { take in
                    VStack(spacing: 0) {
                        takeRow(take)
                        if trimmingTake == take.id { trimmer(take) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            footer

            Divider()
            // The nuclear option — full flash format, everything gone.
            DisclosureGroup(isExpanded: $showErase) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Erases EVERY take on the CineMag — like formatting a card. This cannot be undone. Type ERASE to arm the button.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Type ERASE", text: $eraseField)
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                        Button("Erase entire CineMag", role: .destructive) {
                            eraseField = ""
                            model.eraseMag()
                        }
                        .disabled(eraseField != "ERASE" || model.magBusy != nil || model.downloadProgress != nil)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Erase / format…", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(theme.chrome(0.12))
        .themed()
        // Fill + scale with the window (min size, not a fixed one) so stretching
        // it taller shows more take rows and wider grows the list — matching the
        // CineStation window. (It was a fixed 620×620 back when it was a sheet.)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { model.magOpResult = nil; model.refreshMag() }
        .alert("Delete take \(confirmDelete?.label ?? "")?",
               isPresented: Binding(get: { confirmDelete != nil },
                                    set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.label ?? "") permanently", role: .destructive) {
                if let t = confirmDelete { model.deleteMagTake(t) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            if let t = confirmDelete {
                Text("\(t.detail)\n\nThis removes the take from the CineMag itself — if it hasn't been downloaded, the footage is gone for good.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("CineMag", systemImage: "memorychip").font(.headline)
            if model.connected {
                Text(model.host).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshMag() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(model.magBusy != nil)
                .help("Re-read the take list from the camera")
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.chrome(0.16))
    }

    // MARK: - Where clips land

    private var saveBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text("Saving to:").font(.callout).foregroundStyle(.secondary)
            Text(savePathDisplay)
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head)
                .help(model.currentProjectFolder().path)
            Spacer()
            Button("Choose…") { model.chooseSaveFolder() }.font(.callout)
            Button {
                let dir = model.currentProjectFolder()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            } label: { Image(systemName: "arrow.up.forward.app") }
            .help("Open the save folder in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var savePathDisplay: String {
        let folder = URL(fileURLWithPath: model.saveFolderPath).lastPathComponent
        let proj = model.projectName.trimmingCharacters(in: .whitespaces)
        return proj.isEmpty ? folder : "\(folder) / \(proj)"
    }

    // MARK: - Offload options

    private var optionsBar: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $model.verifyDownloads) { Label("Verify (MD5)", systemImage: "checkmark.shield") }
                .help("Re-open each .cine after download, confirm the frame count, and hash it. Writes a .md5 sidecar.")
            Toggle(isOn: $model.magMakeProxy) { Label("Proxy (.mov)", systemImage: "film.stack") }
                .help("GPU-encode a 1080p H.264 viewing copy beside each .cine")
            Toggle(isOn: $model.magClipPDF) { Label("Clip PDF", systemImage: "doc.richtext") }
                .help("Write a one-page DIT report beside each downloaded clip")
            Spacer()
            Picker("Convert:", selection: $model.magConvert) {
                ForEach(MagOffload.convertChoices, id: \.self) { Text($0) }
            }
            .frame(width: 210)
            .help("Also convert each download to an editing format (GPU, full resolution)")
        }
        .toggleStyle(.checkbox).font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Batch actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { model.downloadAllMagTakes() } label: {
                Label(downloadAllLabel, systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
            .disabled(!model.connected || model.downloadProgress != nil || model.magBusy != nil
                      || model.magTakes.allSatisfy { model.magDownloadedTakes.contains($0.id) })

            if let pdf = model.magLastReport {
                Button { NSWorkspace.shared.open(pdf) } label: {
                    Label("Report", systemImage: "doc.richtext.fill")
                }
                .controlSize(.large)
                .help("Open the combined DIT report from the last Download All")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var downloadAllLabel: String {
        let remaining = model.magTakes.filter { !model.magDownloadedTakes.contains($0.id) }.count
        if !model.magQueuedTakes.isEmpty || (model.magDownloadingTake != nil && model.magBatchTotal > 0) {
            let done = model.magBatchTotal - model.magQueuedTakes.count - (model.magDownloadingTake != nil ? 1 : 0)
            return "Downloading… \(min(done + 1, model.magBatchTotal)) of \(model.magBatchTotal)"
        }
        if remaining == 0 && !model.magTakes.isEmpty { return "All takes downloaded ✓" }
        return "Download All (\(remaining) take\(remaining == 1 ? "" : "s"))"
    }

    // MARK: - Take rows

    private func takeRow(_ take: CameraModel.MagTake) -> some View {
        HStack(spacing: 10) {
            Group {
                if let t = model.magThumbs[take.id] {
                    Image(t, scale: 1, label: Text(take.label))
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(theme.viewerBackdrop(0.2))
                        Image(systemName: "photo").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: model.magThumbHeight * 1.6, height: model.magThumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(take.label)
                .font(.caption.bold().monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.purple.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(take.detail).font(.callout).lineLimit(1)
                if !take.subline.isEmpty {
                    Text(take.subline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let pdf = model.magClipPDFs[take.id] {
                Button { NSWorkspace.shared.open(pdf) } label: { Image(systemName: "doc.richtext") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Open this clip's PDF report")
            }
            Button { model.selectMagTake(take) } label: { Image(systemName: "play.rectangle") }
                .buttonStyle(.plain)
                .help("Load this take into the deck (plays on SDI)")
            Button {
                trimmingTake = (trimmingTake == take.id) ? nil : take.id
            } label: { Image(systemName: "scissors") }
                .buttonStyle(.plain)
                .foregroundStyle(trimmingTake == take.id ? Color.accentColor : .secondary)
                .disabled(model.downloadProgress != nil || model.magBusy != nil)
                .help("Preview and trim this take before downloading")
            downloadControl(take)
            Button { confirmDelete = take } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red)
                .disabled(model.magBusy != nil || model.downloadProgress != nil)
                .help("Delete this take off the CineMag")
        }
        .padding(.vertical, 2)
    }

    /// Inline preview + trim panel — grabs frames over the camera's own GigE
    /// (TCP `img flash`), so no CineStation or 10G is needed.
    private func trimmer(_ take: CameraModel.MagTake) -> some View {
        TakeTrimmerView(
            take: take, host: model.host, iface: nil,
            grab: { conn, cine, frame, w, h in
                try conn.grabFramesFlash(cine: cine, start: frame, count: 1, width: w, height: h)
            },
            trimIn: Binding(get: { model.magTrimIn[take.id] ?? take.firstFrame },
                            set: { model.magTrimIn[take.id] = $0 }),
            trimOut: Binding(get: { model.magTrimOut[take.id] ?? take.lastFrame },
                             set: { model.magTrimOut[take.id] = $0 }),
            onDownloadTrimmed: { trimmingTake = nil; model.downloadMagTake(take) },
            onClose: { trimmingTake = nil })
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func downloadControl(_ take: CameraModel.MagTake) -> some View {
        if model.magDownloadingTake == take.id {
            HStack(spacing: 6) {
                ProgressView(value: model.downloadProgress ?? 0).frame(width: 70)
                Button { model.cancelDownload() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Cancel (also stops a running Download All)")
            }
        } else if model.magQueuedTakes.contains(take.id) {
            Image(systemName: "clock").foregroundStyle(.secondary).help("Queued — will download next")
        } else if model.magDownloadedTakes.contains(take.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("Downloaded and verified this session")
        } else {
            Button { model.downloadMagTake(take) } label: {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(model.downloadProgress != nil || model.magBusy != nil)
            .help("Download this take from the camera to \(savePathDisplay)")
        }
    }

    // MARK: - Footer (status + thumbnail slider)

    @ViewBuilder
    private var footer: some View {
        Divider()
        HStack(spacing: 8) {
            if model.downloadProgress != nil || model.magBusy != nil {
                ProgressView().controlSize(.small)
            }
            Text(model.magBusy ?? (model.downloadStatus.isEmpty ? model.magInfo : model.downloadStatus))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if !model.magTakes.isEmpty {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.tertiary)
                Slider(value: $model.magThumbHeight, in: 28...110).frame(width: 110).controlSize(.mini)
                    .help("Thumbnail size")
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.chrome(0.16))
    }

    private var capacityBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.chrome(0.25))
                    if model.magSize > 0 {
                        Capsule().fill(model.magUsed / model.magSize > 0.9 ? Color.red : Color.purple)
                            .frame(width: max(4, geo.size.width * model.magUsed / model.magSize))
                    }
                }
            }
            .frame(height: 8)
            Text(model.magInfo).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "memorychip").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
