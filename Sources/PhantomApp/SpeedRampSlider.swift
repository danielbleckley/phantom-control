import SwiftUI

/// Playback speed-ramp slider for the deck: grab it DURING playback and drag
/// to ramp — crawl on the left, up to 5× on the right. The play engine watches
/// `playbackSpeed` live (camera-side SDI `vplay rate:` re-issue / Ethernet
/// frame skip-or-dwell), so drags take effect immediately.
///
/// Scale: the left half of the track is 5…100% and the right half 100…500%,
/// so normal speed sits at the center detent and slow-motion gets as much
/// travel as fast-forward. Snaps to 100% near the detent; double-click resets.
struct SpeedRampSlider: View {
    @EnvironmentObject var model: CameraModel
    @ObservedObject private var theme = AppTheme.shared

    private let trackWidth: CGFloat = 150
    private let minSpeed = 0.05     // "0%": one frame every ~⅔ s — never divide by zero
    private let maxSpeed = 5.0

    var body: some View {
        HStack(spacing: 7) {
            Button { model.playbackSpeed = 1.0 } label: {
                Image(systemName: "speedometer")
                    .foregroundStyle(model.playbackSpeed == 1.0 ? Color.secondary : .orange)
            }
            .buttonStyle(.plain)
            .help("Reset to 100%")

            track
                .frame(width: trackWidth, height: 18)

            Text("\(Int((model.playbackSpeed * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(model.playbackSpeed == 1.0 ? Color.primary : .orange)
                .frame(width: 46, alignment: .trailing)
        }
        .help("Playback speed — drag while playing to speed-ramp (100% = normal, up to 500%). Drives the camera's SDI vplay rate; double-click to snap back to 100%.")
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = pos(for: model.playbackSpeed) * w
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chrome(0.25)).frame(height: 5)
                // Fill from the 100% detent toward the knob, PCC-jog style.
                Capsule().fill(Color.orange.opacity(0.8))
                    .frame(width: max(2, abs(x - w / 2)), height: 5)
                    .offset(x: min(x, w / 2))
                // 100% detent tick.
                Rectangle().fill(theme.chrome(0.55))
                    .frame(width: 1.5, height: 11)
                    .offset(x: w / 2 - 0.75)
                Circle().fill(Color.white)
                    .frame(width: 13, height: 13)
                    .shadow(radius: 1.5)
                    .offset(x: x - 6.5)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.playbackSpeed = speed(at: g.location.x / w)
            })
            .onTapGesture(count: 2) { model.playbackSpeed = 1.0 }
        }
    }

    /// Track position (0…1) → speed. Left half 0.05…1, right half 1…5,
    /// with a snap zone around the center detent.
    private func speed(at rawPos: CGFloat) -> Double {
        let p = min(max(Double(rawPos), 0), 1)
        if abs(p - 0.5) < 0.03 { return 1.0 }                    // detent snap
        if p <= 0.5 { return max(minSpeed, p * 2) }              // 0…100%
        return 1 + (p - 0.5) * 2 * (maxSpeed - 1)                // 100…500%
    }

    /// Inverse of `speed(at:)` for drawing the knob.
    private func pos(for speed: Double) -> CGFloat {
        if speed <= 1 { return CGFloat(speed / 2) }
        return CGFloat(0.5 + (speed - 1) / (maxSpeed - 1) / 2)
    }
}
