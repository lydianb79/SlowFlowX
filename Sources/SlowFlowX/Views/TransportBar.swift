import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let song: Song
    @State private var showTrainer = false

    var body: some View {
        let player = model.player
        HStack(spacing: 22) {
            // Play controls
            HStack(spacing: 10) {
                Button { player.skip(by: -5) } label: { Image(systemName: "gobackward.5") }
                    .buttonStyle(IconButtonStyle(size: 34))
                    .help("Back 5 s (←)")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(theme.accentGradient))
                        .shadow(color: theme.accentColor.opacity(0.45), radius: 10, y: 3)
                        .offset(x: player.isPlaying ? 0 : 1.5)
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                Button { player.skip(by: 5) } label: { Image(systemName: "goforward.5") }
                    .buttonStyle(IconButtonStyle(size: 34))
                    .help("Forward 5 s (→)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(player.currentTime))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textColor)
                Text("of \(formatTime(player.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.subtextColor)
            }
            .frame(width: 70, alignment: .leading)

            divider

            // Speed
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tortoise.fill").font(.system(size: 11)).foregroundStyle(theme.accentColor)
                    Text("SPEED")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(theme.subtextColor)
                    Text("\(Int((player.rate * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textColor)
                    if let tr = player.trainer {
                        Text(tr.reachedTarget ? "trainer · target reached"
                             : "trainer → \(Int((tr.target * 100).rounded()))% · pass \(tr.pass + 1)/\(tr.repeats)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accent2Color)
                    } else {
                        Text("pitch preserved")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.subtextColor)
                    }
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(player.rate) },
                                          set: { player.setRate(Float(($0 * 20).rounded() / 20)) }),
                           in: 0.25...1.5)
                        .frame(minWidth: 140, maxWidth: 220)
                    ForEach([0.5, 0.75, 1.0], id: \.self) { r in
                        Button("\(Int(r * 100))") { player.setRate(Float(r)) }
                            .buttonStyle(GhostButtonStyle(active: abs(Double(player.rate) - r) < 0.001))
                    }
                }
            }

            divider

            // Transpose
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tuningfork").font(.system(size: 11)).foregroundStyle(theme.accentColor)
                    Text("TRANSPOSE")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(theme.subtextColor)
                }
                HStack(spacing: 6) {
                    Button { player.setPitch(semitones: player.pitchSemitones - 1) } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle(size: 26))
                    Text(player.pitchSemitones == 0 ? "0 st" : String(format: "%+d st", player.pitchSemitones))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textColor)
                        .frame(width: 44)
                    Button { player.setPitch(semitones: player.pitchSemitones + 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle(size: 26))
                    if player.pitchSemitones != 0 {
                        Button("Reset") { player.setPitch(semitones: 0) }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }

            divider

            // Loop
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(theme.accentColor)
                    Text("A–B LOOP")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(theme.subtextColor)
                }
                HStack(spacing: 6) {
                    Button("A") { player.setLoopStartHere() }
                        .buttonStyle(GhostButtonStyle(active: player.loopStart != nil))
                        .help("Set loop start at current position (⇧⌘A)")
                    Button("B") { player.setLoopEndHere() }
                        .buttonStyle(GhostButtonStyle(active: player.loopEnd != nil))
                        .help("Set loop end at current position (⇧⌘B)")
                    Button { player.toggleLoop() } label: { Image(systemName: "repeat") }
                        .buttonStyle(GhostButtonStyle(active: player.loopEnabled))
                        .disabled(player.loopStart == nil || player.loopEnd == nil)
                    Button { player.clearLoop() } label: { Image(systemName: "xmark") }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(player.loopStart == nil && player.loopEnd == nil)
                    Button {
                        showTrainer = true
                    } label: {
                        Image(systemName: "gauge.with.needle")
                    }
                    .buttonStyle(GhostButtonStyle(active: player.trainer != nil))
                    .help("Speed trainer: speed up a little every time the loop comes round")
                    .popover(isPresented: $showTrainer, arrowEdge: .top) {
                        SpeedTrainerPopover()
                    }
                }
            }

            Spacer(minLength: 8)

            // Volume
            HStack(spacing: 6) {
                Image(systemName: player.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.subtextColor)
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 90)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            theme.surfaceColor
                .overlay(alignment: .top) { Rectangle().fill(theme.borderColor).frame(height: 1) }
                .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.06), radius: 12, y: -4)
        )
    }

    private var divider: some View {
        Rectangle().fill(theme.borderColor).frame(width: 1, height: 40)
    }
}

/// Settings for the speed trainer: start slow, go up a step every N passes of the loop.
private struct SpeedTrainerPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("trainerStart") private var start = 60
    @AppStorage("trainerTarget") private var target = 100
    @AppStorage("trainerStep") private var step = 5
    @AppStorage("trainerRepeats") private var repeats = 2

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 12) {
            Text("Speed Trainer")
                .font(.system(size: 13, weight: .semibold))
            Text(player.loopEnabled
                 ? "Plays the A–B loop, raising the speed each time it comes round."
                 : "No loop set: the whole song is used. Set A and B to train a passage.")
                .font(.system(size: 11))
                .foregroundStyle(theme.subtextColor)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Start at", value: $start, range: 25...150, step: 5, unit: "%")
                row("Up to", value: $target, range: 25...150, step: 5, unit: "%")
                row("Step", value: $step, range: 1...25, step: 1, unit: "%")
                row("Passes per step", value: $repeats, range: 1...10, step: 1, unit: "×")
            }

            Text("\(stepsCount) speeds · about \(stepsCount * repeats) passes")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.subtextColor)

            HStack {
                if player.trainer != nil {
                    Button("Stop Trainer") { player.stopTrainer() }
                        .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button(player.trainer == nil ? "Start" : "Restart") {
                    player.startTrainer(start: Float(start) / 100, target: Float(target) / 100,
                                        step: Float(step) / 100, repeats: repeats)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    private var stepsCount: Int { abs(target - start) / max(1, step) + 1 }

    @ViewBuilder
    private func row(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.textColor)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)\(unit)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
