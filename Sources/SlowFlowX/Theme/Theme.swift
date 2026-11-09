import SwiftUI
import Observation

/// An sRGB colour that can be used both by SwiftUI and by the Metal shaders.
struct RGB: Hashable {
    let r: Double
    let g: Double
    let b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    func simd(_ alpha: Float = 1) -> SIMD4<Float> {
        SIMD4<Float>(Float(r), Float(g), Float(b), alpha)
    }
}

struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let bg: RGB
    let surface: RGB
    let elevated: RGB
    let border: RGB
    let text: RGB
    let subtext: RGB
    let accent: RGB
    let accent2: RGB

    var background: Color { bg.color }
    var surfaceColor: Color { surface.color }
    var elevatedColor: Color { elevated.color }
    var borderColor: Color { border.color }
    var textColor: Color { text.color }
    var subtextColor: Color { subtext.color }
    var accentColor: Color { accent.color }
    var accent2Color: Color { accent2.color }

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent.color, accent2.color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Colour used for a chord root, spread around the circle of fifths so related chords look related.
    func chordColor(root: Int) -> Color {
        guard root >= 0 else { return subtext.color }
        let hue = Double((root * 7) % 12) / 12.0
        return Color(hue: hue, saturation: isDark ? 0.55 : 0.65, brightness: isDark ? 0.92 : 0.78)
    }
}

extension AppTheme {
    static let midnight = AppTheme(
        id: "midnight", name: "Midnight", isDark: true,
        bg: RGB(0x0E1018), surface: RGB(0x161925), elevated: RGB(0x1E2232), border: RGB(0x2A2F42),
        text: RGB(0xEEF0F6), subtext: RGB(0x8D93A8), accent: RGB(0x7C5CFF), accent2: RGB(0x22D3EE))

    static let aurora = AppTheme(
        id: "aurora", name: "Aurora", isDark: true,
        bg: RGB(0x0B1415), surface: RGB(0x112022), elevated: RGB(0x182C2F), border: RGB(0x23403F),
        text: RGB(0xE8F5F2), subtext: RGB(0x86A8A2), accent: RGB(0x34D399), accent2: RGB(0xA78BFA))

    static let ember = AppTheme(
        id: "ember", name: "Ember", isDark: true,
        bg: RGB(0x160F0E), surface: RGB(0x211715), elevated: RGB(0x2C1F1C), border: RGB(0x3D2A25),
        text: RGB(0xF8EEEA), subtext: RGB(0xB09A92), accent: RGB(0xFF7A45), accent2: RGB(0xFFC857))

    static let ocean = AppTheme(
        id: "ocean", name: "Ocean", isDark: true,
        bg: RGB(0x0A1220), surface: RGB(0x101B2E), elevated: RGB(0x16243C), border: RGB(0x22355A),
        text: RGB(0xE7EEFA), subtext: RGB(0x8CA0C2), accent: RGB(0x3B82F6), accent2: RGB(0x2DD4BF))

    static let graphite = AppTheme(
        id: "graphite", name: "Graphite", isDark: true,
        bg: RGB(0x111113), surface: RGB(0x1A1A1D), elevated: RGB(0x232327), border: RGB(0x323236),
        text: RGB(0xF2F2F3), subtext: RGB(0x9A9AA2), accent: RGB(0xF5B83D), accent2: RGB(0xE5E7EB))

    static let paper = AppTheme(
        id: "paper", name: "Paper", isDark: false,
        bg: RGB(0xF3F3F6), surface: RGB(0xFFFFFF), elevated: RGB(0xF8F8FB), border: RGB(0xE2E2E9),
        text: RGB(0x1C1C22), subtext: RGB(0x6B6B78), accent: RGB(0x5B4BFF), accent2: RGB(0x0EA5E9))

    static let sakura = AppTheme(
        id: "sakura", name: "Sakura", isDark: false,
        bg: RGB(0xFBF4F6), surface: RGB(0xFFFFFF), elevated: RGB(0xFDF8FA), border: RGB(0xF0DDE4),
        text: RGB(0x2A1E24), subtext: RGB(0x8A6F7B), accent: RGB(0xE04882), accent2: RGB(0x8B5CF6))

    static let all: [AppTheme] = [.midnight, .aurora, .ember, .ocean, .graphite, .paper, .sakura]
}

@Observable
final class ThemeStore {
    private(set) var current: AppTheme

    init() {
        let id = UserDefaults.standard.string(forKey: "themeID") ?? AppTheme.midnight.id
        current = AppTheme.all.first { $0.id == id } ?? .midnight
    }

    func select(_ theme: AppTheme) {
        current = theme
        UserDefaults.standard.set(theme.id, forKey: "themeID")
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .midnight
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
