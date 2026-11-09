import SwiftUI

struct ExportSheet: View {
    enum AudioChoice: String, CaseIterable, Identifiable {
        case original, stemMix, separate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Original mix"
            case .stemMix: return "Stems → one WAV"
            case .separate: return "One WAV per stem"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var useSelection = false
    @State private var applyProcessing = true
    @State private var bitDepth = 24
    @State private var audio: AudioChoice = .original
    @State private var selectedStems: Set<StemKind> = []
    @State private var useMixerLevels = true

    var body: some View {
        let player = model.player
        let stems = song.stems?.kinds ?? []
        let hasStems = !stems.isEmpty
        let hasSelection = player.loopStart != nil && player.loopEnd != nil
        let processed = player.rate != 1 || player.pitchSemitones != 0
        let start = (useSelection && hasSelection) ? (player.loopStart ?? 0) : 0
        let end = (useSelection && hasSelection) ? (player.loopEnd ?? player.duration) : player.duration
        let rate = (applyProcessing && processed) ? Double(player.rate) : 1
        let outSeconds = max(0, end - start) / rate
        let fileCount = audio == .separate ? max(1, selectedStems.count) : 1
        let bytes = outSeconds * 44_100 * 2 * Double(bitDepth / 8) * Double(fileCount)

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentGradient)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export WAV")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                    Text(song.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.subtextColor)
                        .lineLimit(1)
                }
            }

            // AUDIO
            VStack(alignment: .leading, spacing: 8) {
                label("AUDIO")
                Picker("Audio", selection: $audio) {
                    ForEach(AudioChoice.allCases) { c in Text(c.label).tag(c) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if !hasStems && audio != .original {
                    VStack(alignment: .leading, spacing: 8) {
                        if let status = model.stemStatus[song.id] {
                            HStack(spacing: 8) {
                                ProgressView(value: status.progress).frame(width: 180)
                                Text("\(status.stage) · \(Int(status.progress * 100))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.subtextColor)
                            }
                            Text("The stems will appear here when separation finishes.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.subtextColor)
                        } else {
                            Text("This song has no stems yet. Separate it first, then choose which parts to export.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textColor)
                            HStack(spacing: 8) {
                                Button {
                                    model.separateStems(song.id, engine: .demucs)
                                } label: {
                                    Label("Separate with Demucs (AI)", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(model.tools.demucs == nil)
                                .help(model.tools.demucs == nil ? "Install Demucs first (Settings › Tools)" : "High-quality separation")
                                Button("Quick (built-in)") { model.separateStems(song.id, engine: .builtin) }
                                    .buttonStyle(GhostButtonStyle())
                            }
                            if model.tools.demucs == nil {
                                Text("Demucs isn't installed — see Settings › Tools, or use the quick built-in separator.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.subtextColor)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedColor))
                } else if hasStems && audio != .original {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(stems) { k in
                                let on = selectedStems.contains(k)
                                Button {
                                    if on { selectedStems.remove(k) } else { selectedStems.insert(k) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        Image(systemName: k.icon)
                                        Text(k.label)
                                    }
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(on ? Color.white : theme.textColor)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Capsule().fill(on ? k.color : theme.elevatedColor))
                                    .overlay(Capsule().strokeBorder(k.color.opacity(0.6), lineWidth: on ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 10) {
                            Button("All") { selectedStems = Set(stems) }
                            Button("None") { selectedStems = [] }
                            Button("Current Mix") { selectedStems = currentlyAudible(stems) }
                            if audio == .stemMix {
                                Toggle("Use mixer volumes", isOn: $useMixerLevels)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11.5))
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                        Text(audio == .stemMix
                             ? "Selected stems are mixed into a single file — e.g. everything except vocals for a backing track."
                             : "Each selected stem is written as its own WAV file into a folder you choose.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.subtextColor)
                    }
                }
            }

            // RANGE
            VStack(alignment: .leading, spacing: 8) {
                label("RANGE")
                Picker("Range", selection: $useSelection) {
                    Text("Whole song").tag(false)
                    Text(hasSelection
                         ? "Selection \(formatTime(player.loopStart ?? 0))–\(formatTime(player.loopEnd ?? 0))"
                         : "Selection (none)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!hasSelection)
            }

            // PROCESSING
            VStack(alignment: .leading, spacing: 8) {
                label("PROCESSING")
                Toggle(isOn: $applyProcessing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apply current speed & transpose")
                            .foregroundStyle(theme.textColor)
                        Text(processed
                             ? "\(Int((player.rate * 100).rounded()))% speed\(player.pitchSemitones != 0 ? String(format: ", %+d semitones", player.pitchSemitones) : "") · pitch-preserving time-stretch"
                             : "Playback is at 100% with no transpose, so the audio is exported unchanged")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.subtextColor)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!processed)
            }

            // FORMAT
            VStack(alignment: .leading, spacing: 8) {
                label("FORMAT")
                Picker("Bit depth", selection: $bitDepth) {
                    Text("16-bit").tag(16)
                    Text("24-bit").tag(24)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            HStack {
                Text("≈ \(formatTime(outSeconds))\(fileCount > 1 ? " × \(fileCount) files" : "") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.subtextColor)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(GhostButtonStyle())
                Button("Export…") { startExport(hasSelection: hasSelection, processed: processed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(audio != .original && (!hasStems || selectedStems.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(theme.surfaceColor)
        .onChange(of: stems) { _, newStems in
            if selectedStems.isEmpty { selectedStems = Set(newStems) }
        }
        .onAppear {
            useSelection = hasSelection
            if hasStems {
                selectedStems = currentlyAudible(stems)
                if player.usingStems { audio = .stemMix }
            }
        }
    }

    private func currentlyAudible(_ stems: [StemKind]) -> Set<StemKind> {
        let player = model.player
        guard player.usingStems else { return Set(stems) }
        return Set(stems.filter { player.effectiveGain($0) > 0 })
    }

    private func startExport(hasSelection: Bool, processed: Bool) {
        let player = model.player
        let choice: AppModel.ExportAudio
        switch audio {
        case .original:
            choice = .original
        case .stemMix:
            var gains: [StemKind: Float] = [:]
            for k in selectedStems {
                gains[k] = (useMixerLevels && player.usingStems) ? max(player.mix[k]?.volume ?? 1, 0.0001) : 1
            }
            choice = .stemMix(gains)
        case .separate:
            choice = .separateStems(StemKind.allCases.filter { selectedStems.contains($0) })
        }
        let id = song.id, sel = useSelection && hasSelection, proc = applyProcessing && processed, depth = bitDepth
        dismiss()
        let model = model
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)   // let the sheet close before the save panel
            model.exportWAV(songID: id, useSelection: sel, applyProcessing: proc, bitDepth: depth, audio: choice)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(theme.subtextColor)
    }
}
