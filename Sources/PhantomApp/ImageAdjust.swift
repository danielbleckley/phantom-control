import Foundation

/// One camera develop control (`video.adj.<key>`) exposed in the Image Tools panel —
/// PCC's "Image Tools" pipeline, driven live over the 7115 protocol.
///
/// The camera applies these to its SDI/HDMI out AND bakes them into saved `.cine`
/// develop metadata (the raw sensor data stays raw). Encoding differs per body:
///   • `.scaled`   — ×1024 fixed-point on older PH16 bodies (Flex 2K); plain float on
///                   newer bodies (Flex 4K / VEO). `CameraModel.adjIsFloat` (probed per
///                   camera from the live `gamma` value) selects which.
///   • `.passthru` — the same integer/scalar on every body (hue degrees, SDI codes).
struct AdjControl: Identifiable {
    enum Kind { case scaled, passthru }
    enum Group: String, CaseIterable {
        case tonal    = "Gamma / Tone"
        case color    = "Color"
        case pedestal = "Pedestal (lift)"
    }
    let key: String       // video.adj.<key>
    let label: String
    let kind: Kind
    let min: Double        // human units (unscaled)
    let max: Double
    let neutral: Double
    let decimals: Int
    let group: Group
    var id: String { key }
}

enum ImageAdjust {
    /// Phase 1 — the develop controls the app does NOT already expose. White balance
    /// stays in the main camera panel; `gain`/`tone` are owned by the EI control;
    /// detail/edge, SDI legal range, and the color-matrix editor are later phases.
    ///
    /// Ranges are from the SDK `.cine` develop metadata (Cine File Format PDF); neutrals
    /// were verified against a live Flex 4K `get video.adj` dump (gamma 2.22, sat/toe/
    /// chroma 1, offset/flare/hue/pedestal/gamma-trim 0). Every write round-trips exactly
    /// on the Flex 4K (float body). The ×1024 path is exercised on a PH16 Flex 2K.
    static let controls: [AdjControl] = [
        // Gamma / tone
        .init(key: "gamma",  label: "Gamma",        kind: .scaled,   min: 0.1,  max: 10,  neutral: 2.22, decimals: 2, group: .tonal),
        .init(key: "toe",    label: "Toe",          kind: .scaled,   min: 0.1,  max: 2.0, neutral: 1,    decimals: 2, group: .tonal),
        .init(key: "offset", label: "Offset",       kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .tonal),
        .init(key: "flare",  label: "Flare",        kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .tonal),
        .init(key: "rgamma", label: "Gamma R trim", kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .tonal),
        .init(key: "bgamma", label: "Gamma B trim", kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .tonal),
        // Color
        .init(key: "sat",    label: "Saturation",   kind: .scaled,   min: 0,    max: 2,   neutral: 1,    decimals: 2, group: .color),
        .init(key: "chroma", label: "Chroma",       kind: .scaled,   min: 0,    max: 2,   neutral: 1,    decimals: 2, group: .color),
        .init(key: "hue",    label: "Hue (°)",      kind: .passthru, min: -180, max: 180, neutral: 0,    decimals: 0, group: .color),
        // Pedestal (per-channel lift, post-gamma)
        .init(key: "rped",   label: "Pedestal R",   kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .pedestal),
        .init(key: "gped",   label: "Pedestal G",   kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .pedestal),
        .init(key: "bped",   label: "Pedestal B",   kind: .scaled,   min: -1,   max: 1,   neutral: 0,    decimals: 2, group: .pedestal),
    ]
    static let byKey: [String: AdjControl] = .init(uniqueKeysWithValues: controls.map { ($0.key, $0) })
}
