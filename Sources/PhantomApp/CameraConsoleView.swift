import SwiftUI

/// Raw Phantom-protocol console — the "netcat" surface for advanced users.
/// Type any SDK command (get/set of any variable, rec, trig, iload, the cam.*
/// advanced controls…) and see the camera's reply. Sends over the app's existing
/// camera connection. The camera has no built-in `help`, so the reference list on
/// the left is the discoverability map (all verified live on real bodies).
struct CameraConsoleView: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject private var theme = AppTheme.shared
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private struct Ref: Identifiable { let id = UUID(); let cmd: String; let note: String }
    private let reference: [(title: String, items: [Ref])] = [
        ("Read state", [
            Ref(cmd: "get info",  note: "model, sensor, sw/fw, limits"),
            Ref(cmd: "get defc",  note: "res / rate / exp / ptframes"),
            Ref(cmd: "get cam",   note: "trigger · aux · timecode · fan"),
            Ref(cmd: "get video", note: "SDI out + colour / WB / gamma"),
            Ref(cmd: "get mag",   note: "CineMag state / takes"),
            Ref(cmd: "get c1",    note: "partition 1 state / range"),
        ]),
        ("Settings", [
            Ref(cmd: "set defc.rate 500",       note: "frame rate (fps)"),
            Ref(cmd: "set defc.res 2048 x 1152", note: "resolution (snaps to grid)"),
            Ref(cmd: "set defc.exp 1000000",    note: "exposure — NANOseconds"),
            Ref(cmd: "set defc.ptframes 100",   note: "post-trigger frames"),
        ]),
        ("Recording", [
            Ref(cmd: "trig",         note: "software trigger"),
            Ref(cmd: "rec {cine:1}", note: "arm / record partition 1"),
        ]),
        ("Image / WB", [
            Ref(cmd: "wbal",                      note: "auto WB (Flex: lens cap)"),
            Ref(cmd: "bref",                      note: "black reference (lens cap)"),
            Ref(cmd: "set video.adj.wbtemp 5600", note: "white balance Kelvin"),
            Ref(cmd: "set video.adj.gain 1024",   note: "gain 1024 = 1× (base EI)"),
        ]),
        ("Advanced (cam)", [
            Ref(cmd: "set cam.quiet 1",   note: "quiet fan mode"),
            Ref(cmd: "set cam.trigpol 1", note: "trigger polarity"),
            Ref(cmd: "set cam.aux1mode 0", note: "AUX 1 port function"),
            Ref(cmd: "set cam.tcmode 0",  note: "timecode mode"),
            Ref(cmd: "iload",             note: "instant-load (Ok on Flex 4K)"),
        ]),
    ]

    var body: some View {
        HStack(spacing: 0) {
            referenceSidebar
            Divider()
            consolePane
        }
        .frame(minWidth: 660, minHeight: 440)
        // Its own Window with no injection point above it — without this the
        // chrome would follow the theme while the text stayed dark-scheme,
        // giving light-grey-on-light at the brighter settings.
        .themed()
        .onAppear { inputFocused = true }
    }

    // MARK: Reference sidebar (click to insert)

    private var referenceSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Click to insert · edit · Send")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(reference, id: \.title) { section in
                    sectionView(section.title, section.items)
                }
            }
            .padding(12)
        }
        .frame(width: 236)
        .background(theme.chrome(0.11))
    }

    private func sectionView(_ title: String, _ items: [Ref]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.bold()).foregroundStyle(.secondary).tracking(0.5)
            ForEach(items) { refButton($0) }
        }
    }

    private func refButton(_ ref: Ref) -> some View {
        Button {
            input = ref.cmd
            inputFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.cmd).font(.system(size: 11, design: .monospaced))
                Text(ref.note).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Console pane

    private var consolePane: some View {
        VStack(spacing: 0) {
            consoleHeader
            Divider()
            transcript
            Divider()
            inputBar
        }
    }

    private var consoleHeader: some View {
        HStack(spacing: 8) {
            Text("Camera Console").font(.headline)
            Text("raw protocol").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(model.connected ? "● \(model.host)" : "○ not connected")
                .font(.caption.monospaced())
                .foregroundStyle(model.connected ? Color.green : Color.secondary)
            Button("Clear") { model.clearConsole() }.controlSize(.small)
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.consoleLog.isEmpty { emptyHint }
                    ForEach(model.consoleLog) { entryView($0) }
                }
                .padding(12)
            }
            .onChange(of: model.consoleLog.count) { _, _ in
                if let last = model.consoleLog.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyHint: some View {
        Text("Type a command below, or click one on the left, then Send.\nIt goes straight to the camera — advanced use. The camera has no `help`, so the list is your map.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)
    }

    private func entryView(_ e: CameraModel.ConsoleEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("› \(e.command)")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tint)
            Text(e.response)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(e.ok ? Color.primary : Color.red)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(e.id)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("›").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            TextField("get info", text: $input)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($inputFocused)
                .onSubmit(send)
            Button("Send", action: send)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !model.connected)
        }
        .padding(10)
    }

    private func send() {
        let cmd = input
        model.runConsoleCommand(cmd)
        input = ""
        inputFocused = true
    }
}
