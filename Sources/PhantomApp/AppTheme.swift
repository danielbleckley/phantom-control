import SwiftUI

/// UI brightness for the app's chrome — the Photoshop model.
///
/// Photoshop gives you four discrete interface brightnesses rather than a free
/// slider, because a colour-critical tool wants a small set of known surrounds,
/// not an infinitely tweakable one. Same reasoning here.
///
/// The whole palette is a grey RAMP: wells at 0.10, windows at 0.12–0.13,
/// panels at 0.14–0.16, raised elements 0.18–0.20, controls 0.25+. Rather than
/// re-tag every call site with a semantic name — which would mean deciding, for
/// 40 sites, which tier each one belongs to and getting some wrong — a theme
/// simply TRANSFORMS the existing ramp value. `Color(white: 0.16)` becomes
/// `theme.chrome(0.16)`, and the theme decides what 0.16 means today.
///
/// `.dark` is the identity transform, so it renders pixel-for-pixel what the app
/// has always looked like. Nobody's setup changes until they ask for it.
enum UIBrightness: String, CaseIterable, Identifiable {
    case darkest, dark, medium, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .darkest: return "Darkest"
        case .dark:    return "Dark"
        case .medium:  return "Medium"
        case .light:   return "Light"
        }
    }

    /// Maps a historical grey-ramp value to this brightness.
    ///
    /// The input is the literal that used to be hardcoded (0.10…0.30). Keeping
    /// the ramp intact preserves the DEPTH RELATIONSHIPS — a well stays darker
    /// than the panel it sits in, at every brightness — which is what makes the
    /// layout readable. Flattening to a couple of named colours would lose that.
    func chrome(_ v: Double) -> Double {
        switch self {
        case .dark:
            return v                                  // identity — today's look
        case .darkest:
            return v * 0.55                           // 0.16 → 0.088
        case .medium:
            return v + 0.11                           // 0.16 → 0.27
        case .light:
            // Invert the ramp: deep wells become the LIGHTEST surfaces, so
            // "recessed" still reads as recessed against light panels.
            return 1.0 - (v * 0.85)                   // 0.16 → 0.864, 0.10 → 0.915
        }
    }

    /// Only the lightest step flips macOS's control/text rendering. Medium is
    /// still a dark UI — light text on mid grey — exactly as in Photoshop.
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// App-wide appearance, persisted across launches.
///
/// Injected once at the root as an `.environmentObject` so a change re-renders
/// the whole tree. Views read colours through `theme.chrome(_:)`.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    private static let brightnessKey = "uiBrightness"
    private static let viewerDarkKey = "keepViewerDark"

    @Published var brightness: UIBrightness {
        didSet { UserDefaults.standard.set(brightness.rawValue, forKey: Self.brightnessKey) }
    }

    /// Keep the video viewer's surround dark even in a light UI.
    ///
    /// ON by default and deliberately so: judging exposure, colour and focus
    /// against a bright surround is bad practice — the eye adapts to the
    /// surround and misreads the image. Photoshop separates canvas colour from
    /// interface brightness for the same reason. Anyone who wants a fully light
    /// window can switch it off.
    @Published var keepViewerDark: Bool {
        didSet { UserDefaults.standard.set(keepViewerDark, forKey: Self.viewerDarkKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.brightnessKey) ?? UIBrightness.dark.rawValue
        brightness = UIBrightness(rawValue: raw) ?? .dark
        keepViewerDark = UserDefaults.standard.object(forKey: Self.viewerDarkKey) as? Bool ?? true
    }

    /// Themed chrome grey. Drop-in for a former `Color(white: v)`.
    func chrome(_ v: Double) -> Color { Color(white: brightness.chrome(v)) }

    /// Backdrop for anything showing camera imagery — live SDI, playback,
    /// thumbnails. Respects `keepViewerDark`.
    func viewerBackdrop(_ v: Double = 0.10) -> Color {
        keepViewerDark ? Color(white: v) : chrome(v)
    }

    /// The scheme to hand SwiftUI. Replaces the hardcoded
    /// `.preferredColorScheme(.dark)` scattered through the views.
    var colorScheme: ColorScheme { brightness.colorScheme }
}

/// `.themed()` — applies the current colour scheme to a window's root view.
/// One modifier instead of a hardcoded `.preferredColorScheme(.dark)`.
struct ThemedScheme: ViewModifier {
    @ObservedObject private var theme = AppTheme.shared
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .environmentObject(theme)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedScheme()) }
}

/// Window ▸ Appearance. A `Commands` struct rather than an inline
/// `CommandGroup` because it needs `@ObservedObject` to redraw the checkmarks
/// when the brightness changes — property wrappers can't live in a
/// `CommandsBuilder` closure.
struct AppearanceCommands: Commands {
    @ObservedObject var theme: AppTheme

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Picker("Interface Brightness", selection: $theme.brightness) {
                ForEach(UIBrightness.allCases) { b in
                    Text(b.label).tag(b)
                }
            }
            Toggle("Keep Viewer Dark", isOn: $theme.keepViewerDark)
                .help("Keeps the image area's surround dark even in a light interface. Judging exposure and colour against a bright surround misleads the eye.")
        }
    }
}
