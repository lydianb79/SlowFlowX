import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var useSelection = false
    @State private var applyProcessing = true
    @State private var bitDepth = 24

    var body: some View {
        let player = model.player
        let hasSelection = player.loopStart != nil && player.loopEnd != nil
        let processed = player.rate != 1 || player.pitchSemitones != 0
        let start = (useSelection && hasSelection) ? (player.loopStart ?? 0) : 0
        let end = (useSelection && hasSelection) ? (player.loopEnd ?? player.duration) : player.duration
        let rate = (applyProcessing && processed) ? Double(player.rate) : 1
        let outSeconds = max(0, end - start) / rate
        let bytes = outSeconds * 44_100 * 2 * Double(bitDepth / 8)

        VStack(alignment: .leading, spacing: 18) {
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

            VStack(alignment: .leading, spacing: 8) {
                label("PROCESSING")
                Toggle(isOn: $applyProcessing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apply current speed & transpose")
                            .foregroundStyle(theme.textColor)
                        Text(processed
                             ? "\(Int((player.rate * 100).rounded()))% speed\(player.pitchSemitones != 0 ? String(format: ", %+d semitones", player.pitchSemitones) : "") · pitch-preserving time-stretch"
                             : "Playback is at 100% with no transpose, so the original audio is exported")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.subtextColor)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!processed)
            }

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
                Text("≈ \(formatTime(outSeconds)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.subtextColor)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(GhostButtonStyle())
                Button("Export…") {
                    let id = song.id, sel = useSelection && hasSelection, proc = applyProcessing && processed, depth = bitDepth
                    dismiss()
                    // Let the sheet close before the save panel appears.
                    let model = model
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        model.exportWAV(songID: id, useSelection: sel, applyProcessing: proc, bitDepth: depth)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.surfaceColor)
        .onAppear { useSelection = hasSelection }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(theme.subtextColor)
    }
}
