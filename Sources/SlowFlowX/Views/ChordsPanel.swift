import SwiftUI

struct ChordsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("chordDiagramStyle") private var styleRaw = ChordDiagramStyle.piano.rawValue
    let song: Song

    private var style: ChordDiagramStyle { ChordDiagramStyle(rawValue: styleRaw) ?? .piano }

    var body: some View {
        let player = model.player
        let transpose = player.pitchSemitones
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Chords", icon: "pianokeys") {
                if transpose != 0 {
                    Badge(text: "Transposed \(transpose > 0 ? "+" : "")\(transpose)", tint: theme.accent2Color)
                }
                if let a = song.analysis {
                    Badge(text: a.keyName(transpose: transpose))
                }
                Picker("Diagram", selection: $styleRaw) {
                    ForEach(ChordDiagramStyle.allCases) { s in
                        Label(s.label, systemImage: s.icon).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show chords as piano or guitar diagrams")
            }

            if let analysis = song.analysis, !analysis.chords.isEmpty {
                let idx = analysis.chordIndex(at: player.currentTime)
                NowChordView(analysis: analysis, index: idx, time: player.currentTime,
                             transpose: transpose, rate: Double(player.rate), style: style)
                // Everything below the current chord scrolls, so the panel can shrink on small windows.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            SongChordsStrip(analysis: analysis, currentIndex: idx, transpose: transpose, style: style)
                            SpectrumMetalViewContainer(isActive: player.isPlaying)
                                .frame(height: 40)
                            ChordSheetGrid(chords: analysis.chords, currentIndex: idx, transpose: transpose,
                                           proxy: proxy,
                                           onSeek: { player.seek(to: $0.start) },
                                           onLoop: { player.setLoop(start: $0.start, end: $0.end) })
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            } else if model.analysisStatus[song.id] != nil {
                Spacer()
                HStack { Spacer(); ProgressView("Detecting chords…"); Spacer() }
                Spacer()
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Button("Analyze Chords") { model.analyze(song.id) }.buttonStyle(PrimaryButtonStyle())
                    Spacer()
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct SpectrumMetalViewContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let isActive: Bool

    var body: some View {
        if MetalContext.shared != nil {
            SpectrumMetalView(tap: model.player.spectrum, isActive: isActive, theme: theme)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Now playing chord

private struct NowChordView: View {
    @Environment(\.appTheme) private var theme
    let analysis: SongAnalysis
    let index: Int?
    let time: Double
    let transpose: Int
    let rate: Double
    let style: ChordDiagramStyle

    var body: some View {
        let current = index.map { analysis.chords[$0] }
        let next = index.flatMap { i in analysis.chords[(i + 1)...].first(where: \.isChord) }

        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.subtextColor)
                Text(current?.name(transpose: transpose) ?? "—")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.accentGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: index)
                    .frame(minWidth: 130, alignment: .leading)
            }

            if style == .guitar {
                ChordDiagramView(style: .guitar, segment: current, transpose: transpose)
                    .frame(width: 76, height: 86)
            }

            VStack(alignment: .leading, spacing: 8) {
                if style == .piano {
                    ChordDiagramView(style: .piano, segment: current, transpose: transpose)
                        .frame(height: 54)
                } else if let n = next {
                    HStack(spacing: 10) {
                        ChordDiagramView(style: .guitar, segment: n, transpose: transpose)
                            .frame(width: 46, height: 52)
                            .opacity(0.75)
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 6) {
                    Text("NEXT")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.subtextColor)
                    Text(next?.name(transpose: transpose) ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                    if let n = next {
                        // real (wall-clock) seconds until the change, accounting for slow-down
                        Text(String(format: "in %.1fs", max(0, n.start - time) / max(rate, 0.01)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.subtextColor)
                    }
                    Spacer()
                    if let c = current, c.isChord {
                        Text("\(Int(c.confidence * 100))% match")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.subtextColor)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.elevatedColor))
    }
}

// MARK: - Piano

struct PianoView: View {
    @Environment(\.appTheme) private var theme
    let highlight: [Int]
    let root: Int?

    private let whitePCs = [0, 2, 4, 5, 7, 9, 11]
    private let blackPCs: [(pc: Int, afterWhite: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]

    var body: some View {
        Canvas { ctx, size in
            let octaves = 2
            let whiteCount = 7 * octaves
            let ww = size.width / CGFloat(whiteCount)
            let set = Set(highlight)

            for o in 0..<octaves {
                for (i, pc) in whitePCs.enumerated() {
                    let x = CGFloat(o * 7 + i) * ww
                    let rect = CGRect(x: x + 0.5, y: 0, width: ww - 1, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    let on = set.contains(pc)
                    let isRoot = pc == root
                    ctx.fill(path, with: .color(on ? (isRoot ? theme.accentColor : theme.accent2Color) : Color.white.opacity(theme.isDark ? 0.92 : 1)))
                    ctx.stroke(path, with: .color(theme.borderColor), lineWidth: 0.5)
                }
            }
            for o in 0..<octaves {
                for b in blackPCs {
                    let x = CGFloat(o * 7 + b.afterWhite + 1) * ww - ww * 0.3
                    let rect = CGRect(x: x, y: 0, width: ww * 0.6, height: size.height * 0.6)
                    let on = set.contains(b.pc)
                    let isRoot = b.pc == root
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(on ? (isRoot ? theme.accentColor : theme.accent2Color) : Color(white: 0.12)))
                }
            }
        }
    }
}

// MARK: - Chord sheet grid

private struct ChordSheetGrid: View {
    @Environment(\.appTheme) private var theme
    let chords: [ChordSegment]
    let currentIndex: Int?
    let transpose: Int
    let proxy: ScrollViewProxy
    let onSeek: (ChordSegment) -> Void
    let onLoop: (ChordSegment) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
            ForEach(Array(chords.enumerated()), id: \.offset) { i, seg in
                ChordCell(segment: seg, isCurrent: i == currentIndex, transpose: transpose)
                    .id(i)
                    .onTapGesture { onSeek(seg) }
                    .contextMenu {
                        Button("Play from Here") { onSeek(seg) }
                        Button("Loop This Chord") { onLoop(seg) }
                    }
            }
        }
        .padding(2)
        .onChange(of: currentIndex) { _, newValue in
            guard let newValue else { return }
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(newValue, anchor: .center) }
        }
    }
}

private struct ChordCell: View {
    @Environment(\.appTheme) private var theme
    let segment: ChordSegment
    let isCurrent: Bool
    let transpose: Int

    var body: some View {
        let color = theme.chordColor(root: segment.isChord ? (segment.root + transpose + 12) % 12 : -1)
        VStack(spacing: 2) {
            Text(segment.name(transpose: transpose))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? Color.white : theme.textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(formatTime(segment.start))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : theme.subtextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent ? color : color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCurrent ? Color.clear : color.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 8).opacity(isCurrent ? 0 : 1)
        }
        .scaleEffect(isCurrent ? 1.04 : 1)
        .animation(.spring(duration: 0.25), value: isCurrent)
        .contentShape(Rectangle())
    }
}

// MARK: - Chord vocabulary strip

/// Every distinct chord in the song, in order of first appearance, with its diagram.
private struct SongChordsStrip: View {
    @Environment(\.appTheme) private var theme
    let analysis: SongAnalysis
    let currentIndex: Int?
    let transpose: Int
    let style: ChordDiagramStyle

    private var unique: [ChordSegment] {
        var seen = Set<String>()
        var out: [ChordSegment] = []
        for seg in analysis.chords where seg.isChord {
            let key = "\(seg.root)-\(seg.quality.rawValue)"
            if seen.insert(key).inserted { out.append(seg) }
        }
        return out
    }

    var body: some View {
        let current = currentIndex.map { analysis.chords[$0] }
        VStack(alignment: .leading, spacing: 6) {
            Text("CHORDS IN THIS SONG")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.subtextColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(unique) { seg in
                        ChordShapeCard(segment: seg, style: style, transpose: transpose,
                                       isCurrent: current?.root == seg.root && current?.quality == seg.quality)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}
