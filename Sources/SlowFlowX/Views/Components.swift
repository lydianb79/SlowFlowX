import SwiftUI

// MARK: - Card

struct CardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.surfaceColor)
                    .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(theme.accentGradient)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            )
            .shadow(color: theme.accentColor.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? theme.accentColor : theme.textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? theme.accentColor.opacity(0.15) : theme.elevatedColor)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? theme.accentColor.opacity(0.5) : theme.borderColor, lineWidth: 1)
            )
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(theme.textColor)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.elevatedColor).opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(Circle().strokeBorder(theme.borderColor, lineWidth: 1))
            .contentShape(Circle())
    }
}

// MARK: - Chips & labels

struct StatChip: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accentColor)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.subtextColor)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.elevatedColor))
        .overlay(Capsule().strokeBorder(theme.borderColor, lineWidth: 1))
    }
}

struct SectionHeader<Trailing: View>: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let icon: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textColor)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, icon: String) {
        self.init(title: title, icon: icon) { EmptyView() }
    }
}

struct Badge: View {
    @Environment(\.appTheme) private var theme
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? theme.subtextColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill((tint ?? theme.subtextColor).opacity(0.12)))
    }
}

struct ArtworkView: View {
    @Environment(\.appTheme) private var theme
    let url: URL?
    var size: CGFloat = 40
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(theme.accentGradient).opacity(0.35)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Small rendition of the app mark used in the sidebar.
struct AppLogoMark: View {
    @Environment(\.appTheme) private var theme
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.15, blue: 0.55), Color(red: 0.12, green: 0.1, blue: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
            WaveGlyph()
                .stroke(LinearGradient(colors: [Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 0.66, green: 0.55, blue: 0.98), Color(red: 0.96, green: 0.45, blue: 0.71)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

/// A wave whose frequency decreases left → right ("slowing down").
struct WaveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = 120
        for i in 0...n {
            let u = Double(i) / Double(n)
            let phase = 2 * Double.pi * (5.0 * u + (1.0 - 5.0) * u * u / 2)
            let env = pow(sin(Double.pi * u), 0.8)
            let x = rect.minX + rect.width * u
            let y = rect.midY + rect.height * 0.42 * env * sin(phase)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}
