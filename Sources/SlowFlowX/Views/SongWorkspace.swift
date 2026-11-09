import SwiftUI

enum LowerPane: String, CaseIterable, Identifiable {
    case chordsLyrics, melody
    var id: String { rawValue }
    var label: String { self == .chordsLyrics ? "Chords & Lyrics" : "Tab & Notes" }
    var icon: String { self == .chordsLyrics ? "text.quote" : "music.note.list" }
}

struct SongWorkspace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("lowerPane") private var paneRaw = LowerPane.chordsLyrics.rawValue
    let song: Song

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                SongHeader(song: song)
                WaveformPanel(song: song)
                if paneRaw == LowerPane.melody.rawValue {
                    MelodyPanel(song: song)
                        .frame(minHeight: 0, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ChordsPanel(song: song)
                            .frame(minWidth: 380, maxWidth: .infinity)
                        LyricsPanel(song: song)
                            .frame(minWidth: 340, maxWidth: .infinity)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()

            // The transport always keeps its full height and stays pinned to the bottom.
            TransportBar(song: song)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .sheet(isPresented: Binding(get: { model.showExportSheet }, set: { model.showExportSheet = $0 })) {
            ExportSheet(song: song)
        }
    }
}

// MARK: - Header

private struct SongHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("lowerPane") private var paneRaw = LowerPane.chordsLyrics.rawValue
    let song: Song

    var body: some View {
        let transpose = model.player.pitchSemitones
        HStack(alignment: .center, spacing: 16) {
            ArtworkView(url: song.thumbnailURL, size: 72, corner: 14)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(song.displayTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.subtextColor)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let a = song.analysis {
                        StatChip(icon: "music.quarternote.3", label: "Key", value: a.keyName(transpose: transpose))
                        if a.bpm > 0 {
                            StatChip(icon: "metronome", label: "Tempo",
                                     value: "\(Int((a.bpm * Double(model.player.rate)).rounded())) BPM")
                        }
                        StatChip(icon: "pianokeys", label: "Chords", value: "\(a.uniqueChordCount)")
                    }
                    StatChip(icon: "clock", label: "Length", value: formatTime(model.player.duration > 0 ? model.player.duration : song.duration))
                    if let a = song.analysis, a.usedMetal {
                        Badge(text: "Metal", tint: theme.accent2Color)
                    }
                }
            }
            Spacer(minLength: 12)

            if let status = model.analysisStatus[song.id] {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(status.stage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.subtextColor)
                    ProgressView(value: status.progress)
                        .frame(width: 180)
                }
            }

            Picker("View", selection: $paneRaw) {
                ForEach(LowerPane.allCases) { p in
                    Label(p.label, systemImage: p.icon).tag(p.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between chords & lyrics and the melody tab / piano roll")

            Menu {
                Button("Re-analyze Chords") { model.analyze(song.id) }
                Button("Refresh Lyrics") { model.fetchLyrics(song.id) }
                Button("Transcribe Lyrics from Audio") { model.transcribeLyrics(song.id) }
                Divider()
                Button("Export WAV…") { model.showExportSheet = true }
                Divider()
                Button("Show in Finder") { model.revealInFinder(song.id) }
                Button("Open on YouTube") { model.openSource(song.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Waveform viewport

/// Visible window of the zoomable waveform, in normalised song positions (0...1).
@Observable
final class WaveformViewport {
    var start: Double = 0
    var end: Double = 1
    /// Keep the playhead in view while playing. Turned off when the user scrolls manually.
    var follow = true
    private(set) var minSpan: Double = 0.01

    var span: Double { end - start }
    var isZoomed: Bool { span < 0.999 }

    func setDuration(_ seconds: Double) {
        minSpan = min(1, max(2.0 / max(seconds, 0.001), 0.0002))   // at most ~2 s on screen
        if span < minSpan { zoom(by: span / minSpan, anchor: 0.5) }
    }

    func zoom(by factor: Double, anchor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let a = min(max(anchor, 0), 1)
        let t = start + a * span
        let newSpan = min(1, max(minSpan, span / factor))
        set(start: t - a * newSpan, span: newSpan)
    }

    func pan(by delta: Double) { set(start: start + delta, span: span) }

    func center(on t: Double) { set(start: t - span / 2, span: span) }

    func fit() { start = 0; end = 1 }

    /// Zoom so that [a, b] fills the view with a little padding.
    func show(_ a: Double, _ b: Double) {
        let pad = max((b - a) * 0.08, minSpan * 0.05)
        let newSpan = min(1, max(minSpan, b - a + 2 * pad))
        set(start: a - pad - max(0, newSpan - (b - a + 2 * pad)) / 2, span: newSpan)
    }

    /// Page the view forward/backward so the playhead stays visible.
    func keepVisible(_ t: Double) {
        guard isZoomed else { return }
        if t < start || t > end - span * 0.04 { set(start: t - span * 0.08, span: span) }
    }

    func position(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return start }
        return min(max(start + Double(x / width) * span, 0), 1)
    }

    private func set(start s: Double, span sp: Double) {
        let clamped = min(max(s, 0), 1 - sp)
        start = clamped
        end = clamped + sp
    }
}

// MARK: - Waveform panel

private struct WaveformPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let song: Song
    @State private var viewport = WaveformViewport()
    @State private var hover: Double?
    @State private var dragSelection: (Double, Double)?

    var body: some View {
        let player = model.player
        let duration = max(player.duration, 0.001)
        let progress = player.currentTime / duration
        let transpose = player.pitchSemitones
        let peaks = model.detailPeaks[song.id] ?? song.analysis?.peaks ?? []
        let peaksID = song.id + (model.detailPeaks[song.id] != nil ? "-hi" : (song.analysis == nil ? "-none" : "-lo"))
        let loopA = dragSelection.map { min($0.0, $0.1) } ?? player.loopStart.map { $0 / duration }
        let loopB = dragSelection.map { max($0.0, $0.1) } ?? player.loopEnd.map { $0 / duration }
        let hasLoop = player.loopStart != nil && player.loopEnd != nil

        VStack(spacing: 8) {
            // Toolbar
            HStack(spacing: 8) {
                Text(formatTime(player.currentTime))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textColor)
                if let h = hover {
                    Text("→ \(formatTime(h * duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.subtextColor)
                }
                if let sel = dragSelection {
                    Badge(text: "Selecting \(formatTime(min(sel.0, sel.1) * duration)) – \(formatTime(max(sel.0, sel.1) * duration))",
                          tint: theme.accent2Color)
                } else if hasLoop {
                    Badge(text: "Section \(formatTime(player.loopStart ?? 0)) – \(formatTime(player.loopEnd ?? 0))",
                          tint: player.loopEnabled ? theme.accent2Color : nil)
                    Button { player.seek(to: player.loopStart ?? 0); if !player.isPlaying { player.play() } } label: {
                        Label("Play Section", systemImage: "play.circle")
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button { viewport.show((player.loopStart ?? 0) / duration, (player.loopEnd ?? duration) / duration); viewport.follow = false } label: {
                        Image(systemName: "arrow.left.and.right.square")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Zoom to section")
                } else {
                    Text("Drag on the waveform to select a section · scroll to move · ⌘-scroll or pinch to zoom")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.subtextColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                Button { viewport.zoom(by: 1 / 1.6, anchor: anchorForButtons(progress)) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Zoom out")
                Button { viewport.zoom(by: 1.6, anchor: anchorForButtons(progress)) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Zoom in")
                Button { viewport.fit() } label: { Text("Fit") }
                    .buttonStyle(GhostButtonStyle(active: !viewport.isZoomed))
                    .help("Show the whole song")
                Button { viewport.follow.toggle(); if viewport.follow { viewport.keepVisible(progress) } } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(GhostButtonStyle(active: viewport.follow))
                .help("Follow playhead")
                Button { model.showExportSheet = true } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Export WAV…")
                Text(formatTime(player.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.subtextColor)
            }

            // Overview / minimap
            OverviewStrip(peaks: song.analysis?.peaks ?? model.detailPeaks[song.id] ?? [],
                          viewStart: viewport.start, viewEnd: viewport.end,
                          progress: progress, loopA: loopA, loopB: loopB) { t in
                viewport.center(on: t)
                viewport.follow = false
            }
            .frame(height: 20)

            // Time ruler + zoomable waveform
            GeometryReader { geo in
                let width = geo.size.width
                VStack(spacing: 2) {
                    TimeRuler(viewStart: viewport.start * duration, viewEnd: viewport.end * duration,
                              step: gridStep(width: width, duration: duration))
                        .frame(height: 14)
                    ZStack {
                        if MetalContext.shared != nil {
                            WaveformMetalView(
                                peaks: peaks,
                                peaksID: peaksID,
                                progress: progress,
                                loopStart: loopA,
                                loopEnd: loopB,
                                hover: hover,
                                viewStart: viewport.start,
                                viewEnd: viewport.end,
                                gridStep: gridStep(width: width, duration: duration) / duration,
                                theme: theme,
                                events: events(width: width, duration: duration))
                        } else {
                            Rectangle().fill(theme.elevatedColor)
                                .overlay(Text("Metal is not available on this Mac").foregroundStyle(theme.subtextColor))
                        }
                        if peaks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Analysing waveform…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.subtextColor)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(height: 106)

            if let analysis = song.analysis {
                ChordLane(chords: analysis.chords,
                          viewStart: viewport.start * duration, viewEnd: viewport.end * duration,
                          currentIndex: analysis.chordIndex(at: player.currentTime),
                          transpose: transpose) { seg in
                    player.seek(to: seg.start)
                }
                .frame(height: 26)
            }
        }
        .card(padding: 14)
        .onAppear { viewport.setDuration(duration) }
        .onChange(of: song.id) { _, _ in viewport.fit(); viewport.follow = true; dragSelection = nil }
        .onChange(of: player.duration) { _, d in viewport.setDuration(d) }
        .onChange(of: player.currentTime) { _, t in
            if viewport.follow && player.isPlaying && dragSelection == nil { viewport.keepVisible(t / duration) }
        }
    }

    private func anchorForButtons(_ progress: Double) -> Double {
        // Zoom around the playhead when it's visible, otherwise around the centre.
        (progress >= viewport.start && progress <= viewport.end) ? (progress - viewport.start) / viewport.span : 0.5
    }

    /// Seconds between grid lines so labels are at least ~70 pt apart.
    private func gridStep(width: CGFloat, duration: Double) -> Double {
        let visibleSeconds = viewport.span * duration
        guard width > 0, visibleSeconds > 0 else { return 0 }
        let ptsPerSecond = Double(width) / visibleSeconds
        for step in [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120] where step * ptsPerSecond >= 70 { return step }
        return 300
    }

    private func events(width: CGFloat, duration: Double) -> WaveformEvents {
        let player = model.player
        let vp = viewport
        var e = WaveformEvents()
        e.onHover = { x in hover = x.map { vp.position(x: $0, width: width) } }
        e.onDrag = { startX, x in
            dragSelection = (vp.position(x: startX, width: width), vp.position(x: x, width: width))
            // auto-scroll when dragging past the edges
            if x >= width - 2 { vp.pan(by: vp.span * 0.02) } else if x <= 2 { vp.pan(by: -vp.span * 0.02) }
        }
        e.onMouseUp = { _, endX, didDrag in
            let clicked = vp.position(x: endX, width: width)
            if didDrag, let sel = dragSelection, abs(sel.1 - sel.0) * duration > 0.2 {
                // Dragged: the selection becomes the A–B practice loop.
                let s = min(sel.0, sel.1) * duration, en = max(sel.0, sel.1) * duration
                player.setLoop(start: s, end: en)
                player.seek(to: s)
            } else {
                player.seek(to: clicked * duration)
            }
            dragSelection = nil
        }
        e.onScroll = { dx, dy, precise, zoomMod, x in
            if zoomMod {
                let factor = exp(Double(dy) * (precise ? 0.01 : 0.12))
                vp.zoom(by: factor, anchor: Double(x / max(width, 1)))
            } else {
                let delta = abs(dx) >= abs(dy) ? -dx : -dy
                let pts = Double(delta) * (precise ? 1 : 12)
                vp.pan(by: pts / Double(max(width, 1)) * vp.span)
                vp.follow = false
            }
        }
        e.onMagnify = { factor, x in
            vp.zoom(by: Double(factor), anchor: Double(x / max(width, 1)))
        }
        return e
    }
}

/// Small full-song overview with a draggable window showing the zoomed region.
private struct OverviewStrip: View {
    @Environment(\.appTheme) private var theme
    let peaks: [Float]
    let viewStart: Double
    let viewEnd: Double
    let progress: Double
    let loopA: Double?
    let loopB: Double?
    let onMove: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
                ctx.fill(bg, with: .color(theme.elevatedColor))
                if let a = loopA, let b = loopB, b > a {
                    ctx.fill(Path(CGRect(x: a * size.width, y: 0, width: (b - a) * size.width, height: size.height)),
                             with: .color(theme.accent2Color.opacity(0.18)))
                }
                if !peaks.isEmpty {
                    let bars = max(1, Int(size.width / 2))
                    let mid = size.height / 2
                    var path = Path()
                    for i in 0..<bars {
                        let i0 = i * peaks.count / bars, i1 = max(i0 + 1, (i + 1) * peaks.count / bars)
                        var m: Float = 0
                        for k in i0..<min(i1, peaks.count) { m = max(m, peaks[k]) }
                        let h = max(1, CGFloat(m) * (size.height - 4) / 2)
                        let x = CGFloat(i) * 2
                        path.addRect(CGRect(x: x, y: mid - h, width: 1.2, height: h * 2))
                    }
                    ctx.fill(path, with: .color(theme.subtextColor.opacity(0.45)))
                }
                // visible window
                let win = CGRect(x: viewStart * size.width, y: 0.5, width: max(4, (viewEnd - viewStart) * size.width), height: size.height - 1)
                let winPath = Path(roundedRect: win, cornerRadius: 5)
                ctx.fill(winPath, with: .color(theme.accentColor.opacity(0.14)))
                ctx.stroke(winPath, with: .color(theme.accentColor.opacity(0.9)), lineWidth: 1.5)
                // playhead
                let px = progress * size.width
                ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(theme.accent2Color))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onMove(min(max(v.location.x / geo.size.width, 0), 1)) }
            )
            .help("Drag to move the zoomed view")
        }
    }
}

/// Time labels aligned with the waveform grid.
private struct TimeRuler: View {
    @Environment(\.appTheme) private var theme
    let viewStart: Double   // seconds
    let viewEnd: Double     // seconds
    let step: Double        // seconds

    var body: some View {
        Canvas { ctx, size in
            guard step > 0, viewEnd > viewStart else { return }
            let span = viewEnd - viewStart
            var t = (viewStart / step).rounded(.up) * step
            while t <= viewEnd {
                let x = (t - viewStart) / span * size.width
                let label: String
                if step < 1 {
                    label = String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                } else {
                    label = formatTime(t)
                }
                ctx.fill(Path(CGRect(x: x, y: size.height - 4, width: 1, height: 4)), with: .color(theme.subtextColor.opacity(0.6)))
                ctx.draw(Text(label).font(.system(size: 9.5, design: .monospaced)).foregroundColor(theme.subtextColor),
                         at: CGPoint(x: x + 3, y: size.height / 2 - 1), anchor: .leading)
                t += step
            }
        }
    }
}

/// Coloured chord blocks aligned with the (zoomed) waveform timeline.
private struct ChordLane: View {
    @Environment(\.appTheme) private var theme
    let chords: [ChordSegment]
    let viewStart: Double   // seconds
    let viewEnd: Double     // seconds
    let currentIndex: Int?
    let transpose: Int
    let onTap: (ChordSegment) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let span = max(viewEnd - viewStart, 0.001)
                for (i, seg) in chords.enumerated() where seg.isChord && seg.end > viewStart && seg.start < viewEnd {
                    let x0 = (seg.start - viewStart) / span * size.width
                    let w = seg.duration / span * size.width
                    let rect = CGRect(x: x0 + 0.5, y: 0, width: max(w - 1, 0.5), height: size.height)
                    let active = i == currentIndex
                    let color = theme.chordColor(root: (seg.root + transpose + 12) % 12)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(active ? 0.95 : 0.28)))
                    if w > 24 {
                        let label = Text(seg.name(transpose: transpose))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(active ? .white : theme.textColor)
                        let visible = rect.intersection(CGRect(origin: .zero, size: size))
                        ctx.draw(label, at: CGPoint(x: visible.isNull ? rect.midX : visible.midX, y: rect.midY))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let t = viewStart + location.x / geo.size.width * (viewEnd - viewStart)
                if let seg = chords.last(where: { $0.start <= t }) { onTap(seg) }
            }
        }
    }
}
