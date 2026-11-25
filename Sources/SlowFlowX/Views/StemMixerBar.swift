import SwiftUI

/// Compact stem mixer: separate stems, toggle stem playback, and mute / solo / balance each stem.
struct StemMixerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let song: Song

    var body: some View {
        let player = model.player
        HStack(spacing: 10) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentColor)
            Text("STEMS")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(theme.subtextColor)

            if let status = model.stemStatus[song.id] {
                ProgressView(value: status.progress)
                    .frame(width: 200)
                Text("\(status.stage) · \(Int(status.progress * 100))%")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.subtextColor)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { model.cancelStemSeparation(song.id) }
                    .buttonStyle(GhostButtonStyle())
            } else if let stems = song.stems {
                Toggle(isOn: Binding(get: { model.playStems }, set: { model.setPlayStems($0) })) {
                    Text(model.playStems ? "On" : "Off")
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Play the separated stems instead of the original mix")

                if stems.engine == .builtin {
                    Button {
                        if model.tools.demucsReady {
                            model.separateStems(song.id, engine: .demucs)
                        } else {
                            model.showDemucsInstaller = true
                        }
                    } label: {
                        Label(model.tools.demucsReady ? "Quick stems · Redo with Demucs"
                              : (model.tools.demucsBroken ? "Quick stems · Repair Demucs" : "Quick stems · Install Demucs"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GhostButtonStyle(active: true))
                    .help("These stems come from the quick built-in separator, which can only roughly split a mix. Demucs (AI) produces real, clean stems.")
                } else {
                    Badge(text: "Demucs · \(stems.model)", tint: theme.accent2Color)
                }
                if player.usingStems {
                    // Full channels when there's room, icon-only pills when it's tight, and a
                    // visible horizontal scroller only as a last resort — never a silently clipped stem.
                    ViewThatFits(in: .horizontal) {
                        channels(player.stemKinds, compact: false)
                        channels(player.stemKinds, compact: true)
                        ScrollView(.horizontal, showsIndicators: true) {
                            channels(player.stemKinds, compact: true)
                                .padding(.bottom, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { player.resetMix() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(GhostButtonStyle())
                        .help("Unmute all stems and reset volumes")
                } else {
                    Text("\(stems.kinds.count) stems ready · \(stems.engine.label)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.subtextColor)
                    Spacer()
                }
                Menu {
                    Button("Separate Again with Demucs") { model.separateStems(song.id, engine: .demucs) }
                    Button("Separate Again (Built-in, quick)") { model.separateStems(song.id, engine: .builtin) }
                    Divider()
                    Button("Delete Stems", role: .destructive) { model.deleteStems(song.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text("Split the song into vocals, drums, bass, guitar… to mute or solo parts and get far better transcriptions.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.subtextColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.tools.demucsChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking Demucs…").font(.system(size: 11.5)).foregroundStyle(theme.subtextColor)
                    }
                } else if !model.tools.demucsReady {
                    Button {
                        model.showDemucsInstaller = true
                    } label: {
                        Label(model.demucsInstalling ? "Installing Demucs…"
                              : (model.tools.demucsBroken ? "Repair Demucs" : "Install Demucs (AI)"),
                              systemImage: model.tools.demucsBroken ? "wrench.and.screwdriver" : "arrow.down.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help(model.tools.demucsBroken
                          ? "Demucs is installed but doesn't run: \(model.tools.demucsProblem ?? "unknown error"). Click to repair."
                          : "One-click install of Demucs, the AI separator. Needed for clean stems.")
                } else {
                    Button {
                        model.separateStems(song.id, engine: .demucs)
                    } label: {
                        Label("Separate (Demucs AI)", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("High-quality AI separation (\(DemucsModel.current.rawValue))")
                }
                Button("Quick (built-in)") { model.separateStems(song.id, engine: .builtin) }
                    .buttonStyle(GhostButtonStyle())
                    .help("Fast spectral separation without extra software (4 stems, lower quality)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.borderColor))
    }

    private func channels(_ kinds: [StemKind], compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            ForEach(kinds) { kind in
                StemChannel(kind: kind, compact: compact)
            }
        }
        .padding(.vertical, 1)
        .fixedSize()
    }
}

private struct StemChannel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let kind: StemKind
    var compact = false

    var body: some View {
        let player = model.player
        let state = player.mix[kind] ?? StemMixState()
        let audible = player.effectiveGain(kind) > 0
        HStack(spacing: 5) {
            Button {
                player.toggleMute(kind)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: kind.icon).font(.system(size: 10, weight: .semibold))
                    if !compact { Text(kind.label).font(.system(size: 11, weight: .semibold)) }
                }
                .foregroundStyle(audible ? Color.white : theme.subtextColor)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(audible ? kind.color : theme.elevatedColor))
                .overlay(Capsule().strokeBorder(kind.color.opacity(audible ? 0 : 0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(state.muted ? "\(kind.label) · click to unmute" : "\(kind.label) · click to mute")
            .contextMenu {
                Button("Solo \(kind.label)") { player.soloOnly(kind) }
                Button("Everything except \(kind.label)") { player.muteOnly(kind) }
                Button("Reset Mixer") { player.resetMix() }
            }

            Button("S") { player.toggleSolo(kind) }
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(state.solo ? Color.black : theme.subtextColor)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(state.solo ? Color.yellow : theme.elevatedColor))
                .buttonStyle(.plain)
                .help("Solo \(kind.label)")

            Slider(value: Binding(get: { Double(state.volume) }, set: { player.setStemVolume(kind, Float($0)) }), in: 0...1.5)
                .controlSize(.mini)
                .frame(width: compact ? 46 : 54)
                .help("\(kind.label) volume")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedColor.opacity(0.6)))
    }
}
