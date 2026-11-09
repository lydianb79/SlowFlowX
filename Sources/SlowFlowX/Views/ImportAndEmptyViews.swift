import SwiftUI
import AppKit

struct ImportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentColor)

            if let activity = model.activity {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(activity.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textColor)
                        Text(activity.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.subtextColor)
                            .lineLimit(1)
                        Spacer()
                        if let p = activity.progress {
                            Text("\(Int(p * 100))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.subtextColor)
                        }
                    }
                    if let p = activity.progress {
                        ProgressView(value: p).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Button("Cancel") { model.cancelImport() }
                    .buttonStyle(GhostButtonStyle())
            } else {
                TextField("Paste a YouTube link to download, analyse and practise…", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($focused)
                    .onSubmit { model.importFromURL() }

                Button {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        model.urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    model.importFromURL()
                } label: {
                    Label("Analyze", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? theme.accentColor.opacity(0.7) : theme.borderColor, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 30)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: theme.accentColor.opacity(0.35), radius: 30, y: 10)

                VStack(spacing: 8) {
                    Text("Learn any song at your own pace")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                    Text("Paste a YouTube link above. SlowFlowX downloads the audio, detects the chords on the GPU,\nfinds synced lyrics and lets you slow it down without changing the pitch.")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.subtextColor)
                }

                HStack(spacing: 14) {
                    FeatureTile(icon: "pianokeys", title: "Chord detection",
                                text: "Metal-accelerated chromagram + HMM decoding, key and tempo.")
                    FeatureTile(icon: "text.quote", title: "Synced lyrics",
                                text: "Time-synced lyrics with chords above each line.")
                    FeatureTile(icon: "tortoise", title: "Slow down",
                                text: "25 – 200 % speed with pitch preserved, transpose and A–B loops.")
                }
                .frame(maxWidth: 820)

                ToolsStatusCard()
                    .frame(maxWidth: 820)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct FeatureTile: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accentGradient)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.accentColor.opacity(0.12)))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct ToolsStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Requirements", icon: "wrench.and.screwdriver") {
                Button("Re-check") { model.refreshTools() }
                    .buttonStyle(GhostButtonStyle())
            }
            row(name: "yt-dlp", detail: "downloads audio from YouTube (required)", path: model.tools.ytdlp)
            row(name: "ffmpeg", detail: "converts any stream to M4A (recommended)", path: model.tools.ffmpeg)
            if model.tools.ytdlp == nil || model.tools.ffmpeg == nil {
                HStack {
                    Text("brew install yt-dlp ffmpeg")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textColor)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedColor))
            }
        }
        .card()
    }

    private func row(name: String, detail: String, path: URL?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? Color.orange : Color.green)
            Text(name)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textColor)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtextColor)
            Spacer()
            Text(path?.path ?? "not found")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.subtextColor)
                .lineLimit(1)
        }
    }
}
