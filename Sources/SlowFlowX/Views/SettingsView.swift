import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.appTheme) private var theme
    @AppStorage("chordDiagramStyle") private var diagramStyle = ChordDiagramStyle.piano.rawValue
    @AppStorage("demucsModel") private var demucsModel = DemucsModel.sixStem.rawValue

    var body: some View {
        TabView {
            appearance
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            stems
                .tabItem { Label("Stems", systemImage: "slider.vertical.3") }
            ScrollView { ToolsStatusCard().padding(20) }
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 470)
        .background(theme.background)
    }

    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(AppTheme.all) { t in
                        ThemePreviewCard(preview: t, selected: t.id == themes.current.id)
                            .onTapGesture { themes.select(t) }
                    }
                }
                Text("Chord diagrams")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                    .padding(.top, 8)
                Picker("Chord diagrams", selection: $diagramStyle) {
                    ForEach(ChordDiagramStyle.allCases) { s in
                        Label(s.label, systemImage: s.icon).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(20)
        }
    }

    private var stems: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Demucs model")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                Picker("Demucs model", selection: $demucsModel) {
                    ForEach(DemucsModel.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Demucs (by Meta AI Research) runs locally on your Mac and uses the GPU on Apple Silicon. A 4-minute song takes roughly 30 s – 2 min. The first run downloads the model (~80–300 MB).")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The built-in separator needs no installation but is much less clean: it splits the stereo centre (vocals) from the sides and sustained sounds from drum hits.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text("SlowFlowX")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textColor)
            Text("Version 1.0")
                .foregroundStyle(theme.subtextColor)
            Text("Audio via yt-dlp · Chords via Metal + Accelerate · Lyrics via LRCLIB / Apple Speech")
                .font(.system(size: 12))
                .foregroundStyle(theme.subtextColor)
                .multilineTextAlignment(.center)
            Text("Only download content you have the right to use.")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtextColor.opacity(0.8))
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThemePreviewCard: View {
    let preview: AppTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // miniature window
            HStack(spacing: 0) {
                Rectangle().fill(preview.surfaceColor).frame(width: 38)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(preview.surfaceColor).frame(height: 12)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<16, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i < 7 ? preview.accentColor : preview.subtextColor.opacity(0.5))
                                .frame(width: 3, height: CGFloat([10, 18, 12, 24, 16, 28, 14, 20, 26, 12, 18, 22, 10, 16, 24, 12][i]))
                        }
                    }
                    .frame(height: 30)
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == 1 ? AnyShapeStyle(preview.accentGradient) : AnyShapeStyle(preview.elevatedColor))
                                .frame(height: 14)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(preview.background)
            }
            .frame(height: 86)

            HStack {
                Text(preview.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(preview.textColor)
                Spacer()
                Circle().fill(preview.accentColor).frame(width: 9, height: 9)
                Circle().fill(preview.accent2Color).frame(width: 9, height: 9)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(preview.surfaceColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? preview.accentColor : preview.borderColor, lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }
}
