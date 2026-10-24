import SwiftUI

/// PCC-style "Image Tools" develop panel. Adjusts the camera's `video.adj.*` pipeline
/// live over the 7115 protocol — the camera applies it to SDI out and bakes it into
/// recorded cines. Presence-gated per body, so the same window serves the Flex 4K, the
/// Flex 2K (PH16, ×1024 encoding), and the VEO with no per-model branching.
struct ImageToolsView: View {
    @EnvironmentObject var model: CameraModel
    var body: some View {
        VStack(spacing: 0) {
            ImageToolsHeader()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.connected {
                        Text("Connect to a camera to adjust its develop pipeline.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if model.adjPresent.isEmpty {
                        Text("Reading develop settings from the camera…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(AdjControl.Group.allCases, id: \.self) { group in
                        if model.groupPresent(group) { AdjGroupView(group: group) }
                    }
                    Text("Applies to the camera's live SDI out and newly recorded cines. "
                         + "The raw sensor data stays raw. White balance and EI live in the main panel.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Button("Reset All to Neutral") { model.resetAllAdjust() }
                Button("Revert to Camera") { model.refreshCameraColor() }
                Spacer()
            }
            .controlSize(.small)
            .disabled(!model.connected)
            .padding(10)
        }
        .frame(minWidth: 440, minHeight: 480)
        .onAppear { if model.connected { model.refreshCameraColor() } }
    }
}

private struct ImageToolsHeader: View {
    @EnvironmentObject var model: CameraModel
    var body: some View {
        HStack(spacing: 8) {
            Text("Image Tools").font(.headline)
            if model.connected {
                Text(model.adjIsFloat ? "float" : "1024-int")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .help("How this body encodes develop values (auto-detected).")
            }
            Spacer()
            Text(model.connected ? "● \(model.host)" : "○ offline")
                .font(.caption.monospaced())
                .foregroundStyle(model.connected ? .green : .secondary)
            Button("Re-read") { model.refreshCameraColor() }
                .controlSize(.small)
                .disabled(!model.connected)
        }
        .padding(10)
    }
}

private struct AdjGroupView: View {
    @EnvironmentObject var model: CameraModel
    let group: AdjControl.Group
    private var controls: [AdjControl] {
        ImageAdjust.controls.filter { $0.group == group && model.hasAdj($0.key) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.rawValue.uppercased())
                    .font(.caption.bold()).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                Button("Reset") { model.resetAdjGroup(group) }
                    .controlSize(.small).buttonStyle(.borderless)
            }
            ForEach(controls) { AdjSlider(control: $0) }
        }
    }
}

private struct AdjSlider: View {
    @EnvironmentObject var model: CameraModel
    let control: AdjControl
    var body: some View {
        HStack(spacing: 8) {
            Text(control.label)
                .font(.callout)
                .frame(width: 108, alignment: .leading)
            Slider(value: model.adjBinding(control.key), in: control.min...control.max)
            TextField("", value: model.adjBinding(control.key),
                      format: .number.precision(.fractionLength(control.decimals)))
                .frame(width: 54)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Button { model.resetAdjust(control.key) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reset \(control.label) to \(control.neutral, format: .number)")
        }
    }
}
