import SwiftUI

enum MelodyViewStyle: String, CaseIterable, Identifiable {
    case tab, piano
    var id: String { rawValue }
    var label: String { self == .tab ? "Tab" : "Piano roll" }
    var icon: String { self == .tab ? "guitars" : "pianokeys" }
}

/// Caches tab fingerings so the DP isn't recomputed on every frame.
@MainActor
private enum FingeringCache {
    private static var cache: [String: [TabPosition]] = [:]

    static func positions(songID: String, track: MelodyTrack, transpose: Int) -> [TabPosition] {
        let key = "\(songID)|\(track.source.rawValue)|\(transpose)|\(track.analyzedAt.timeIntervalSince1970)|\(track.notes.count)"
        if let p = cache[key] { return p }
        let p = TabFingering.positions(for: track.notes, instrument: track.source.tabInstrument, transpose: transpose)
        if cache.count > 40 { cache.removeAll() }
        cache[key] = p
        return p
    }
}

// MARK: - Panel

struct MelodyPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("melodySource") private var sourceRaw = MelodySource.vocal.rawValue
    @AppStorage("melodyViewStyle") private var styleRaw = MelodyViewStyle.tab.rawValue
    @AppStorage("melodyWindowSeconds") private var windowSeconds = 8.0
    @AppStorage("melodyQuantize") private var quantize = 0          // 0 off, 1 = 16ths, 2 = 8ths
    let song: Song

    private var source: MelodySource { MelodySource(rawValue: sourceRaw) ?? .vocal }
    private var style: MelodyViewStyle { MelodyViewStyle(rawValue: styleRaw) ?? .tab }

    var body: some View {
        let player = model.player
        let key = AppModel.melodyKey(song.id, source)
        let track = song.melodies?[source.rawValue]
        let transpose = player.pitchSemitones
        let chords = song.analysis?.chords ?? []

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Tab & Notes", icon: "music.note.list") {
                Picker("Part", selection: $sourceRaw) {
                    ForEach(MelodySource.allCases) { s in
                        Label(s.shortLabel, systemImage: s.icon).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Which part to transcribe")

                Picker("View", selection: $styleRaw) {
                    ForEach(MelodyViewStyle.allCases) { s in
                        Label(s.label, systemImage: s.icon).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Menu {
                    Button("Export MIDI…") { model.exportMIDI(song.id, source: source) }
                    Button("Copy as Text Tab") { model.copyASCIITab(song.id, source: source) }
                    Button("Save Text Tab…") { model.saveASCIITab(song.id, source: source) }
                    Divider()
                    Button("Transcribe Again") { model.analyzeMelody(song.id, source: source) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(track == nil)
            }

            if let track, !track.isEmpty {
                RhythmToolbar(song: song, track: track, quantize: $quantize, windowSeconds: $windowSeconds)
            }

            if let status = model.melodyStatus[key] {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView(value: status.progress).frame(width: 260)
                    Text("Transcribing \(source.label.lowercased()) · \(status.stage)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.subtextColor)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let track, !track.isEmpty {
                let grid = track.grid(fallbackBPM: song.analysis?.bpm ?? 0)
                NowNoteBar(song: song, track: track, chords: chords, time: player.currentTime, transpose: transpose)
                Group {
                    switch style {
                    case .tab:
                        if track.source.isRhythm {
                            StrumTabView(track: track, chords: chords, grid: grid, quantize: quantize,
                                         time: player.currentTime, window: windowSeconds, transpose: transpose,
                                         onSeek: { player.seek(to: $0) })
                        } else {
                            TabStaffView(track: track,
                                         positions: FingeringCache.positions(songID: song.id, track: track, transpose: transpose),
                                         chords: chords, grid: grid, quantize: quantize,
                                         time: player.currentTime, window: windowSeconds, transpose: transpose,
                                         onSeek: { player.seek(to: $0) })
                        }
                    case .piano:
                        PianoRollView(notes: track.displayNotes(chords: chords),
                                      chords: chords, grid: grid, quantize: quantize,
                                      time: player.currentTime, window: windowSeconds, transpose: transpose,
                                      onSeek: { player.seek(to: $0) })
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(track.source.isRhythm
                     ? "Strums are detected from attacks in the mix; directions follow the beat (down on the beat, up in between). Chord shapes come from the chord analysis."
                     : "Auto-transcribed from the mix. Works best when the part is prominent; use it as a starting point and check by ear. Drag to scrub.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.subtextColor)
                    .lineLimit(2)
            } else if track != nil {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash").font(.system(size: 26)).foregroundStyle(theme.subtextColor)
                    Text("No clear \(source.label.lowercased()) found")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textColor)
                    Text("Try another part, or transcribe again.")
                        .font(.system(size: 12)).foregroundStyle(theme.subtextColor)
                    Button("Transcribe Again") { model.analyzeMelody(song.id, source: source) }
                        .buttonStyle(GhostButtonStyle())
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        model.analyzeMelody(song.id, source: source)
                    } label: {
                        Label("Transcribe \(source.label)", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Spacer()
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .onAppear { autoTranscribe() }
        .onChange(of: key) { _, _ in autoTranscribe() }
    }

    /// Transcribe automatically the first time a part is shown.
    private func autoTranscribe() {
        let key = AppModel.melodyKey(song.id, source)
        if song.melodies?[source.rawValue] == nil && model.melodyStatus[key] == nil {
            model.analyzeMelody(song.id, source: source)
        }
    }
}

// MARK: - Rhythm toolbar (grid, tempo, zoom)

private struct RhythmToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let song: Song
    let track: MelodyTrack
    @Binding var quantize: Int
    @Binding var windowSeconds: Double

    var body: some View {
        let grid = track.grid(fallbackBPM: song.analysis?.bpm ?? 0)
        HStack(spacing: 10) {
            Text("GRID")
                .font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(theme.subtextColor)
            Picker("Grid", selection: $quantize) {
                Text("Off").tag(0)
                Text("1/8").tag(2)
                Text("1/16").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Snap notes to the beat grid (display and export)")

            Rectangle().fill(theme.borderColor).frame(width: 1, height: 18)

            Image(systemName: "metronome").font(.system(size: 11)).foregroundStyle(theme.accentColor)
            Text("♩ = \(Int(grid.bpm.rounded()))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textColor)
                .frame(minWidth: 58, alignment: .leading)
            Group {
                Button("½×") { model.setMelodyTempo(song.id, source: track.source, bpm: grid.bpm / 2) }
                    .help("Half tempo")
                Button("2×") { model.setMelodyTempo(song.id, source: track.source, bpm: grid.bpm * 2) }
                    .help("Double tempo")
                Button { model.setMelodyTempo(song.id, source: track.source, bpm: (grid.bpm - 1).rounded()) } label: { Image(systemName: "minus") }
                    .help("Tempo −1")
                Button { model.setMelodyTempo(song.id, source: track.source, bpm: (grid.bpm + 1).rounded()) } label: { Image(systemName: "plus") }
                    .help("Tempo +1")
                Button {
                    model.alignBeat(song.id, source: track.source, at: model.player.currentTime)
                } label: {
                    Label("Beat Here", systemImage: "scope")
                }
                .help("Move the beat grid so a beat falls at the playhead (use it on a clear downbeat)")
            }
            .buttonStyle(GhostButtonStyle())

            if track.beatOffset == nil {
                Button {
                    model.analyzeMelody(song.id, source: track.source)
                } label: {
                    Label("Update Transcription", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GhostButtonStyle(active: true))
                .help("This part was transcribed with an older version. Transcribe again for accurate note lengths and beat grid.")
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.subtextColor)
                Slider(value: $windowSeconds, in: 3...24)
                    .frame(width: 90)
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.subtextColor)
            }
            .help("Visible time window (zoom)")
        }
    }
}

// MARK: - Now / next

private struct NowNoteBar: View {
    @Environment(\.appTheme) private var theme
    let song: Song
    let track: MelodyTrack
    let chords: [ChordSegment]
    let time: Double
    let transpose: Int

    var body: some View {
        let lyricLine: String? = song.lyrics.flatMap { l in l.lineIndex(at: time).map { l.lines[$0].text } }

        HStack(alignment: .center, spacing: 16) {
            if track.source.isRhythm {
                rhythmContent
            } else {
                melodyContent
            }
            if let lyricLine, !lyricLine.isEmpty {
                Text("♪ " + lyricLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.subtextColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Badge(text: "\(track.eventCount) \(track.source.isRhythm ? "strums" : "notes")" + (track.usedMetal ? " · Metal" : ""))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.elevatedColor))
    }

    @ViewBuilder private var melodyContent: some View {
        let idx = track.noteIndex(at: time)
        let nextStart = track.notes.firstIndex { $0.start > time } ?? track.notes.count
        let upcoming = Array(track.notes[nextStart..<min(track.notes.count, nextStart + 8)])
        VStack(alignment: .leading, spacing: 0) {
            Text("NOTE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(theme.subtextColor)
            Text(idx.map { track.notes[$0].name(transpose: transpose) } ?? "—")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.accentGradient)
                .frame(minWidth: 80, alignment: .leading)
        }
        HStack(spacing: 6) {
            Text("NEXT")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(theme.subtextColor)
            ForEach(upcoming) { n in
                Text(n.name(transpose: transpose))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textColor)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(theme.chordColor(root: ((n.midi + transpose) % 12 + 12) % 12).opacity(0.22)))
            }
        }
    }

    @ViewBuilder private var rhythmContent: some View {
        let strums = track.strums ?? []
        let idx = track.strumIndex(at: time)
        let chord = MelodyTrack.chord(at: time, in: chords)
        let nextStart = strums.firstIndex { $0.start > time } ?? strums.count
        let upcoming = Array(strums[nextStart..<min(strums.count, nextStart + 12)])
        VStack(alignment: .leading, spacing: 0) {
            Text("STRUM")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(theme.subtextColor)
            HStack(spacing: 6) {
                Text(chord?.name(transpose: transpose) ?? "—")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.accentGradient)
                if let idx {
                    Image(systemName: strums[idx].down ? "arrow.down" : "arrow.up")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(theme.accent2Color)
                }
            }
            .frame(minWidth: 96, alignment: .leading)
        }
        HStack(spacing: 4) {
            Text("NEXT")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(theme.subtextColor)
            ForEach(upcoming) { s in
                Image(systemName: s.down ? "arrow.down" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(s.down ? theme.accentColor : theme.accent2Color)
                    .frame(width: 18, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.surfaceColor))
                    .opacity(0.5 + Double(min(s.strength, 1)) * 0.5)
            }
        }
    }
}

// MARK: - Shared timeline helpers

private struct Timeline {
    let time: Double
    let window: Double
    let left: CGFloat
    let width: CGFloat

    var start: Double { time - window * 0.2 }      // playhead sits at 20 %
    var end: Double { start + window }

    func x(_ t: Double) -> CGFloat { left + CGFloat((t - start) / window) * width }
    func t(_ x: CGFloat) -> Double { start + Double((x - left) / max(width, 1)) * window }
}

private func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }

private func drawBeatGrid(_ ctx: GraphicsContext, tl: Timeline, grid: RhythmGrid, top: CGFloat, bottom: CGFloat,
                          theme: AppTheme, showSixteenths: Bool) {
    let firstStep = Int(grid.stepPosition(tl.start).rounded(.up))
    let lastStep = Int(grid.stepPosition(tl.end).rounded(.down))
    guard lastStep >= firstStep, lastStep - firstStep < 4000 else { return }
    for s in firstStep...lastStep {
        let x = tl.x(grid.time(ofStep: Double(s)))
        guard x >= tl.left else { continue }
        let isBar = ((s % 16) + 16) % 16 == 0
        let isBeat = ((s % 4) + 4) % 4 == 0
        if !isBeat && !showSixteenths { continue }
        let width: CGFloat = isBar ? 1.4 : (isBeat ? 0.7 : 0.5)
        let alpha: Double = isBar ? 0.42 : (isBeat ? 0.18 : 0.07)
        ctx.fill(Path(CGRect(x: x, y: top, width: width, height: bottom - top)),
                 with: .color(theme.subtextColor.opacity(alpha)))
        if isBar {
            let bar = floorDiv(s, 16) + 1
            ctx.draw(Text("\(bar)").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.subtextColor.opacity(0.7)),
                     at: CGPoint(x: x + 3, y: top - 1), anchor: .bottomLeading)
        }
    }
}

private func drawChordNames(_ ctx: GraphicsContext, tl: Timeline, chords: [ChordSegment], transpose: Int, y: CGFloat, theme: AppTheme) {
    for seg in chords where seg.isChord && seg.end > tl.start && seg.start < tl.end {
        let x = max(tl.x(seg.start), tl.left)
        let label = Text(seg.name(transpose: transpose))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(theme.chordColor(root: (seg.root + transpose + 12) % 12))
        ctx.draw(label, at: CGPoint(x: x + 2, y: y), anchor: .leading)
    }
}

/// Standard rhythm notation below a tab: stems, flags, beams (per beat) and dots.
private func drawRhythm(_ ctx: GraphicsContext, items: [(x: CGFloat, event: GridEvent, active: Bool)],
                        top: CGFloat, theme: AppTheme) {
    let L: CGFloat = 16
    let beamY = top + L
    func color(_ active: Bool) -> Color { active ? theme.accentColor : theme.subtextColor }
    func stem(_ x: CGFloat, length: CGFloat, active: Bool) {
        ctx.fill(Path(CGRect(x: x - 0.6, y: top, width: 1.2, height: length)), with: .color(color(active)))
    }
    func dot(_ x: CGFloat, _ y: CGFloat, active: Bool) {
        ctx.fill(Path(ellipseIn: CGRect(x: x + 3, y: y - 1.5, width: 3, height: 3)), with: .color(color(active)))
    }

    var i = 0
    while i < items.count {
        let it = items[i]
        let v = it.event.value
        if v.isBeamable {
            let beat = floorDiv(it.event.startStep, 4)
            var j = i
            while j + 1 < items.count, items[j + 1].event.value.isBeamable,
                  floorDiv(items[j + 1].event.startStep, 4) == beat, items[j + 1].x > items[j].x + 2 {
                j += 1
            }
            if j > i {
                for k in i...j {
                    stem(items[k].x, length: L, active: items[k].active)
                    if items[k].event.value.dotted { dot(items[k].x, beamY - 6, active: items[k].active) }
                }
                ctx.fill(Path(CGRect(x: items[i].x - 0.6, y: beamY - 2.5, width: items[j].x - items[i].x + 1.2, height: 2.5)),
                         with: .color(theme.subtextColor))
                for k in i...j where items[k].event.value.sixteenths == 1 {
                    if k < j && items[k + 1].event.value.sixteenths == 1 {
                        ctx.fill(Path(CGRect(x: items[k].x - 0.6, y: beamY - 7, width: items[k + 1].x - items[k].x + 1.2, height: 2.5)),
                                 with: .color(theme.subtextColor))
                    } else if !(k > i && items[k - 1].event.value.sixteenths == 1) {
                        let w: CGFloat = 6
                        let x0 = k < j ? items[k].x : items[k].x - w
                        ctx.fill(Path(CGRect(x: x0, y: beamY - 7, width: w, height: 2.5)), with: .color(theme.subtextColor))
                    }
                }
                i = j + 1
                continue
            }
        }
        // un-beamed single note
        switch v.sixteenths {
        case 16:
            ctx.stroke(Path(ellipseIn: CGRect(x: it.x - 4, y: top + 2, width: 8, height: 5.5)),
                       with: .color(color(it.active)), lineWidth: 1.3)
        case 8:
            stem(it.x, length: L * 0.55, active: it.active)
            ctx.stroke(Path(ellipseIn: CGRect(x: it.x - 3, y: top + L * 0.55, width: 6, height: 4.5)),
                       with: .color(color(it.active)), lineWidth: 1.1)
        default:
            stem(it.x, length: L, active: it.active)
            for f in 0..<v.flags {
                var p = Path()
                let y = beamY - CGFloat(f) * 5
                p.move(to: CGPoint(x: it.x, y: y))
                p.addLine(to: CGPoint(x: it.x + 6, y: y - 5))
                ctx.stroke(p, with: .color(color(it.active)), lineWidth: 1.6)
            }
        }
        if v.dotted { dot(it.x, beamY - 6, active: it.active) }
        i += 1
    }
}

/// Drag to scrub (moves the timeline), click to jump.
private struct ScrubModifier: ViewModifier {
    let time: Double
    let window: Double
    let left: CGFloat
    let onSeek: (Double) -> Void
    @State private var dragOrigin: Double?

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragOrigin == nil { dragOrigin = time }
                            guard abs(v.translation.width) > 3, let o = dragOrigin else { return }
                            let width = max(geo.size.width - left, 1)
                            onSeek(max(0, o - Double(v.translation.width / width) * window))
                        }
                        .onEnded { v in
                            if abs(v.translation.width) <= 3 {
                                let tl = Timeline(time: dragOrigin ?? time, window: window, left: left, width: geo.size.width - left)
                                onSeek(max(0, tl.t(v.location.x)))
                            }
                            dragOrigin = nil
                        }
                )
        }
    }
}

/// Start/end times for display, snapped to the grid when quantising.
private func displayTimes(_ starts: [Double], _ ends: [Double], grid: RhythmGrid, quantize: Int)
    -> (events: [GridEvent], start: [Double], end: [Double]) {
    let events = RhythmQuantizer.quantize(starts: starts, ends: ends, grid: grid, resolution: max(1, quantize))
    guard quantize > 0 else { return (events, starts, ends) }
    return (events,
            events.map { grid.time(ofStep: Double($0.startStep)) },
            events.map { grid.time(ofStep: Double($0.endStep)) })
}

// MARK: - Guitar / bass tab (pitched parts)

private struct TabStaffView: View {
    @Environment(\.appTheme) private var theme
    let track: MelodyTrack
    let positions: [TabPosition]
    let chords: [ChordSegment]
    let grid: RhythmGrid
    let quantize: Int
    let time: Double
    let window: Double
    let transpose: Int
    let onSeek: (Double) -> Void

    private let left: CGFloat = 30

    var body: some View {
        let instrument = track.source.tabInstrument
        let timing = displayTimes(track.notes.map(\.start), track.notes.map(\.end), grid: grid, quantize: quantize)
        Canvas { ctx, size in
            let tl = Timeline(time: time, window: window, left: left, width: size.width - left)
            let strings = instrument.tuning.count
            let top: CGFloat = 34, bottom = size.height - 34
            let gap = (bottom - top) / CGFloat(max(strings - 1, 1))
            func y(_ s: Int) -> CGFloat { top + CGFloat(strings - 1 - s) * gap }   // highest string on top

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.elevatedColor))
            drawBeatGrid(ctx, tl: tl, grid: grid, top: top - 8, bottom: bottom + 6, theme: theme,
                         showSixteenths: window <= 6)
            drawChordNames(ctx, tl: tl, chords: chords, transpose: transpose, y: 10, theme: theme)

            for s in 0..<strings {
                ctx.fill(Path(CGRect(x: left, y: y(s) - 0.5, width: size.width - left, height: 1)),
                         with: .color(theme.subtextColor.opacity(0.45)))
                ctx.draw(Text(instrument.stringNames[s]).font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.subtextColor),
                         at: CGPoint(x: left / 2, y: y(s)))
            }
            ctx.fill(Path(CGRect(x: left - 2, y: top, width: 2, height: bottom - top)), with: .color(theme.subtextColor.opacity(0.6)))

            let fontSize = min(13, max(9, gap * 0.62))
            var rhythmItems: [(x: CGFloat, event: GridEvent, active: Bool)] = []
            for i in track.notes.indices where i < positions.count && i < timing.events.count {
                let start = timing.start[i], end = timing.end[i]
                guard end > tl.start && start < tl.end else { continue }
                let n = track.notes[i]
                let p = positions[i]
                let x0 = max(tl.x(start), left), x1 = tl.x(end)
                let yy = y(p.string)
                let active = n.start <= time && time < n.end
                let past = n.end <= time
                let color = active ? theme.accentColor : theme.accent2Color

                if x1 > x0 + 4 {
                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: yy - 2, width: x1 - x0, height: 4), cornerRadius: 2),
                             with: .color(color.opacity(past ? 0.18 : 0.38)))
                }
                let label = ctx.resolve(Text("\(p.fret)")
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundColor(active ? .white : (past ? theme.subtextColor : theme.textColor)))
                let sz = label.measure(in: size)
                let pillW = max(sz.width + 8, sz.height + 4)
                let pill = CGRect(x: x0 - pillW / 2, y: yy - sz.height / 2 - 2, width: pillW, height: sz.height + 4)
                ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                         with: .color(active ? theme.accentColor : theme.surfaceColor))
                ctx.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                           with: .color(color.opacity(past ? 0.3 : 0.8)), lineWidth: 1)
                ctx.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
                if p.octaveShift != 0 {
                    ctx.draw(Text(p.octaveShift > 0 ? "8vb" : "8va").font(.system(size: 7.5, weight: .semibold))
                                .foregroundColor(theme.subtextColor),
                             at: CGPoint(x: pill.midX, y: pill.minY - 5))
                }
                if tl.x(start) >= left { rhythmItems.append((tl.x(start), timing.events[i], active)) }
            }
            drawRhythm(ctx, items: rhythmItems, top: bottom + 10, theme: theme)

            let px = tl.x(time)
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(theme.accent2Color))
        }
        .modifier(ScrubModifier(time: time, window: window, left: left, onSeek: onSeek))
    }
}

// MARK: - Rhythm guitar tab (strums)

private struct StrumTabView: View {
    @Environment(\.appTheme) private var theme
    let track: MelodyTrack
    let chords: [ChordSegment]
    let grid: RhythmGrid
    let quantize: Int
    let time: Double
    let window: Double
    let transpose: Int
    let onSeek: (Double) -> Void

    private let left: CGFloat = 30

    var body: some View {
        let strums = track.strums ?? []
        let timing = displayTimes(strums.map(\.start), strums.map(\.end), grid: grid, quantize: quantize)
        Canvas { ctx, size in
            let tl = Timeline(time: time, window: window, left: left, width: size.width - left)
            let strings = 6
            let top: CGFloat = 44, bottom = size.height - 34
            let gap = (bottom - top) / CGFloat(strings - 1)
            func y(_ s: Int) -> CGFloat { top + CGFloat(strings - 1 - s) * gap }

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.elevatedColor))
            drawBeatGrid(ctx, tl: tl, grid: grid, top: top - 8, bottom: bottom + 6, theme: theme,
                         showSixteenths: window <= 8)
            drawChordNames(ctx, tl: tl, chords: chords, transpose: transpose, y: 10, theme: theme)

            let names = TabInstrument.guitar.stringNames
            for s in 0..<strings {
                ctx.fill(Path(CGRect(x: left, y: y(s) - 0.5, width: size.width - left, height: 1)),
                         with: .color(theme.subtextColor.opacity(0.45)))
                ctx.draw(Text(names[s]).font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.subtextColor),
                         at: CGPoint(x: left / 2, y: y(s)))
            }
            ctx.fill(Path(CGRect(x: left - 2, y: top, width: 2, height: bottom - top)), with: .color(theme.subtextColor.opacity(0.6)))

            let fontSize = min(11, max(8, gap * 0.6))
            var rhythmItems: [(x: CGFloat, event: GridEvent, active: Bool)] = []
            for i in strums.indices where i < timing.events.count {
                let start = timing.start[i], end = timing.end[i]
                guard end > tl.start && start < tl.end else { continue }
                let s = strums[i]
                let x = tl.x(start)
                guard x >= left - 4 else { continue }
                let active = s.start <= time && time < s.end
                let past = s.end <= time
                let colColor = s.down ? theme.accentColor : theme.accent2Color

                if active {
                    ctx.fill(Path(roundedRect: CGRect(x: x - 9, y: top - 6, width: 18, height: bottom - top + 12), cornerRadius: 5),
                             with: .color(theme.accentColor.opacity(0.16)))
                }
                // strum arrow (length/opacity follow strength)
                let a = 0.45 + Double(min(s.strength, 1)) * 0.55
                ctx.draw(Text(s.down ? "↓" : "↑").font(.system(size: 13, weight: .heavy))
                            .foregroundColor(colColor.opacity(past ? a * 0.5 : a)),
                         at: CGPoint(x: x, y: top - 14))

                // chord shape stacked on the strings
                if let c = MelodyTrack.chord(at: s.start + 0.02, in: chords),
                   let v = GuitarChords.voicing(root: (c.root + transpose + 12) % 12, quality: c.quality) {
                    for str in 0..<strings {
                        let f = v.frets[str]
                        let text = f < 0 ? "x" : "\(f)"
                        ctx.draw(Text(text).font(.system(size: fontSize, weight: .bold, design: .rounded))
                                    .foregroundColor(active ? theme.textColor : (past ? theme.subtextColor.opacity(0.6) : theme.textColor.opacity(0.85))),
                                 at: CGPoint(x: x, y: y(str)))
                    }
                } else {
                    // no chord known: show a muted strum
                    for str in 0..<strings {
                        ctx.draw(Text("x").font(.system(size: fontSize, weight: .bold)).foregroundColor(theme.subtextColor),
                                 at: CGPoint(x: x, y: y(str)))
                    }
                }
                rhythmItems.append((x, timing.events[i], active))
            }
            drawRhythm(ctx, items: rhythmItems, top: bottom + 10, theme: theme)

            let px = tl.x(time)
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(theme.accent2Color))
        }
        .modifier(ScrubModifier(time: time, window: window, left: left, onSeek: onSeek))
    }
}

// MARK: - Piano roll

private struct PianoRollView: View {
    @Environment(\.appTheme) private var theme
    let notes: [MelodyNote]
    let chords: [ChordSegment]
    let grid: RhythmGrid
    let quantize: Int
    let time: Double
    let window: Double
    let transpose: Int
    let onSeek: (Double) -> Void

    private let left: CGFloat = 46

    var body: some View {
        let lo0 = (notes.map(\.midi).min() ?? 60) + transpose
        let hi0 = (notes.map(\.midi).max() ?? 72) + transpose
        let lo = min(lo0 - 2, (lo0 + hi0) / 2 - 12)
        let hi = max(hi0 + 2, lo + 24)
        let timing = displayTimes(notes.map(\.start), notes.map(\.end), grid: grid, quantize: quantize)
        let activeMidis = Set(notes.filter { $0.start <= time && time < $0.end }.map { $0.midi + transpose })

        Canvas { ctx, size in
            let tl = Timeline(time: time, window: window, left: left, width: size.width - left)
            let top: CGFloat = 24
            let rows = hi - lo + 1
            let rowH = (size.height - top) / CGFloat(rows)
            func y(_ m: Int) -> CGFloat { top + CGFloat(hi - m) * rowH }

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.elevatedColor))
            for m in lo...hi where MidiNote.isBlack(m) {
                ctx.fill(Path(CGRect(x: left, y: y(m), width: size.width - left, height: rowH)),
                         with: .color(theme.subtextColor.opacity(0.07)))
            }
            for m in lo...hi where ((m % 12) + 12) % 12 == 0 {
                ctx.fill(Path(CGRect(x: left, y: y(m) + rowH - 0.5, width: size.width - left, height: 0.5)),
                         with: .color(theme.subtextColor.opacity(0.3)))
            }
            drawBeatGrid(ctx, tl: tl, grid: grid, top: top, bottom: size.height, theme: theme, showSixteenths: window <= 6)
            drawChordNames(ctx, tl: tl, chords: chords, transpose: transpose, y: 9, theme: theme)

            // keyboard
            for m in lo...hi {
                let r = CGRect(x: 0, y: y(m), width: left - 2, height: rowH)
                let black = MidiNote.isBlack(m)
                let isActive = activeMidis.contains(m)
                let fill: Color = isActive ? theme.accentColor : (black ? Color(white: 0.15) : Color.white.opacity(theme.isDark ? 0.9 : 1))
                ctx.fill(Path(CGRect(x: r.minX, y: r.minY + 0.5, width: black ? r.width * 0.65 : r.width, height: max(r.height - 1, 0.5))),
                         with: .color(fill))
                if ((m % 12) + 12) % 12 == 0 && rowH >= 7 {
                    ctx.draw(Text(MidiNote.name(m)).font(.system(size: min(9, rowH * 0.9), weight: .semibold))
                                .foregroundColor(isActive ? .white : Color(white: 0.35)),
                             at: CGPoint(x: left - 5, y: r.midY), anchor: .trailing)
                }
            }

            // notes
            for i in notes.indices where i < timing.events.count {
                let start = timing.start[i], end = timing.end[i]
                guard end > tl.start && start < tl.end else { continue }
                let n = notes[i]
                let m = n.midi + transpose
                guard m >= lo && m <= hi else { continue }
                let x0 = max(tl.x(start), left), x1 = tl.x(end)
                guard x1 > x0 else { continue }
                let active = n.start <= time && time < n.end
                let past = n.end <= time
                let rect = CGRect(x: x0, y: y(m) + 1, width: max(x1 - x0 - 1, 2), height: max(rowH - 2, 2))
                let color = theme.chordColor(root: ((m % 12) + 12) % 12)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(4, rect.height / 2)),
                         with: .color(color.opacity(active ? 1 : (past ? 0.35 : 0.75))))
                if active {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 4),
                               with: .color(theme.textColor), lineWidth: 1.5)
                }
                if rect.width > 26 && rowH >= 9 {
                    ctx.draw(Text(MidiNote.name(m)).font(.system(size: min(10, rowH * 0.8), weight: .bold, design: .rounded))
                                .foregroundColor(.black.opacity(0.75)),
                             at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }

            let px = tl.x(time)
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(theme.accent2Color))
        }
        .modifier(ScrubModifier(time: time, window: window, left: left, onSeek: onSeek))
    }
}
