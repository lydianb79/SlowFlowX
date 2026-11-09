import SwiftUI

// MARK: - Preference

enum ChordDiagramStyle: String, CaseIterable, Identifiable {
    case piano, guitar
    var id: String { rawValue }
    var label: String { self == .piano ? "Piano" : "Guitar" }
    var icon: String { self == .piano ? "pianokeys" : "guitars" }
}

// MARK: - Guitar voicings

/// A guitar chord shape. Strings are ordered low E (index 0) → high e (index 5).
struct GuitarVoicing: Hashable {
    let frets: [Int]          // -1 = muted, 0 = open, n = fret
    let barreFret: Int?       // fret of a full/partial barre
    let barreFromString: Int  // first string covered by the barre

    static let openStringPCs = [4, 9, 2, 7, 11, 4]   // E A D G B E

    func pitchClass(string: Int) -> Int? {
        let f = frets[string]
        guard f >= 0 else { return nil }
        return (Self.openStringPCs[string] + f) % 12
    }

    /// First fret shown in the diagram (1 = nut visible).
    var baseFret: Int {
        let fretted = frets.filter { $0 > 0 }
        guard let maxF = fretted.max(), let minF = fretted.min() else { return 1 }
        return maxF <= 4 ? 1 : minF
    }
}

enum GuitarChords {
    /// Common open-position shapes. Everything else uses an E- or A-shape barre chord.
    private static let open: [String: [Int]] = [
        // C
        "0-major": [-1, 3, 2, 0, 1, 0],
        "0-dominant7": [-1, 3, 2, 3, 1, 0],
        // D
        "2-major": [-1, -1, 0, 2, 3, 2],
        "2-minor": [-1, -1, 0, 2, 3, 1],
        "2-dominant7": [-1, -1, 0, 2, 1, 2],
        "2-minor7": [-1, -1, 0, 2, 1, 1],
        // E
        "4-major": [0, 2, 2, 1, 0, 0],
        "4-minor": [0, 2, 2, 0, 0, 0],
        "4-dominant7": [0, 2, 0, 1, 0, 0],
        "4-minor7": [0, 2, 0, 0, 0, 0],
        // G
        "7-major": [3, 2, 0, 0, 0, 3],
        "7-dominant7": [3, 2, 0, 0, 0, 1],
        // A
        "9-major": [-1, 0, 2, 2, 2, 0],
        "9-minor": [-1, 0, 2, 2, 1, 0],
        "9-dominant7": [-1, 0, 2, 0, 2, 0],
        "9-minor7": [-1, 0, 2, 0, 1, 0],
        // B
        "11-dominant7": [-1, 2, 1, 2, 0, 2],
    ]

    /// Offsets relative to the barre fret (-1 = muted).
    private static let eShape: [ChordQuality: [Int]] = [
        .major: [0, 2, 2, 1, 0, 0], .minor: [0, 2, 2, 0, 0, 0],
        .dominant7: [0, 2, 0, 1, 0, 0], .minor7: [0, 2, 0, 0, 0, 0],
    ]
    private static let aShape: [ChordQuality: [Int]] = [
        .major: [-1, 0, 2, 2, 2, 0], .minor: [-1, 0, 2, 2, 1, 0],
        .dominant7: [-1, 0, 2, 0, 2, 0], .minor7: [-1, 0, 2, 0, 1, 0],
    ]

    static func voicing(root: Int, quality: ChordQuality) -> GuitarVoicing? {
        guard root >= 0, quality != .none else { return nil }
        let r = ((root % 12) + 12) % 12
        if let frets = open["\(r)-\(quality.rawValue)"] {
            return GuitarVoicing(frets: frets, barreFret: nil, barreFromString: 0)
        }
        guard let e = eShape[quality], let a = aShape[quality] else { return nil }
        var eFret = (r - 4 + 12) % 12; if eFret == 0 { eFret = 12 }
        var aFret = (r - 9 + 12) % 12; if aFret == 0 { aFret = 12 }
        let useE = eFret <= aFret
        let fret = useE ? eFret : aFret
        let offsets = useE ? e : a
        let frets = offsets.map { $0 < 0 ? -1 : $0 + fret }
        return GuitarVoicing(frets: frets, barreFret: fret, barreFromString: useE ? 0 : 1)
    }
}

// MARK: - Diagram views

/// Shows a chord as either a piano or a guitar diagram.
struct ChordDiagramView: View {
    let style: ChordDiagramStyle
    let segment: ChordSegment?
    let transpose: Int

    var body: some View {
        let root = segment.map { ($0.root + transpose + 12) % 12 }
        switch style {
        case .piano:
            PianoView(highlight: segment?.pitchClasses(transpose: transpose) ?? [], root: segment?.isChord == true ? root : nil)
        case .guitar:
            GuitarChordView(voicing: segment.flatMap { s in
                s.isChord ? GuitarChords.voicing(root: (s.root + transpose + 12) % 12, quality: s.quality) : nil
            }, root: root)
        }
    }
}

struct GuitarChordView: View {
    @Environment(\.appTheme) private var theme
    let voicing: GuitarVoicing?
    let root: Int?
    var fretCount = 4

    var body: some View {
        Canvas { ctx, size in
            let strings = 6
            let topPad = size.height * 0.16          // room for x / o markers
            let compact = size.width < 70
            let leftPad = max(size.width * 0.16, compact ? 10 : 14)   // room for fret number
            let rightPad = size.width * 0.06
            let bottomPad = size.height * 0.04
            let gridW = size.width - leftPad - rightPad
            let gridH = size.height - topPad - bottomPad
            let sx = gridW / CGFloat(strings - 1)
            let fy = gridH / CGFloat(fretCount)
            let lineColor = theme.subtextColor.opacity(0.7)
            let base = voicing?.baseFret ?? 1

            // Fret lines
            for f in 0...fretCount {
                let y = topPad + CGFloat(f) * fy
                var p = Path()
                p.move(to: CGPoint(x: leftPad, y: y))
                p.addLine(to: CGPoint(x: leftPad + gridW, y: y))
                let isNut = f == 0 && base == 1
                ctx.stroke(p, with: .color(isNut ? theme.textColor : lineColor), lineWidth: isNut ? 3 : 1)
            }
            // Strings
            for s in 0..<strings {
                let x = leftPad + CGFloat(s) * sx
                var p = Path()
                p.move(to: CGPoint(x: x, y: topPad))
                p.addLine(to: CGPoint(x: x, y: topPad + gridH))
                ctx.stroke(p, with: .color(lineColor), lineWidth: 1 + CGFloat(strings - 1 - s) * 0.12)
            }

            guard let v = voicing else {
                ctx.draw(Text("—").font(.system(size: 14, weight: .bold)).foregroundColor(theme.subtextColor),
                         at: CGPoint(x: leftPad + gridW / 2, y: topPad + gridH / 2))
                return
            }

            if base > 1 {
                ctx.draw(Text(compact ? "\(base)" : "\(base)fr")
                            .font(.system(size: compact ? 8 : max(8, min(11, fy * 0.42)), weight: .semibold, design: .rounded))
                            .foregroundColor(theme.subtextColor),
                         at: CGPoint(x: leftPad / 2 - 1, y: topPad + fy * 0.5))
            }

            let dotR = min(sx, fy) * 0.36
            let markerFont = Font.system(size: max(8, topPad * 0.62), weight: .bold)

            // Barre
            if let bf = v.barreFret, bf >= base, bf < base + fretCount {
                let y = topPad + (CGFloat(bf - base) + 0.5) * fy
                let x0 = leftPad + CGFloat(v.barreFromString) * sx
                let rect = CGRect(x: x0 - dotR, y: y - dotR, width: CGFloat(5 - v.barreFromString) * sx + dotR * 2, height: dotR * 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: dotR), with: .color(theme.accent2Color.opacity(0.85)))
            }

            for s in 0..<strings {
                let x = leftPad + CGFloat(s) * sx
                let f = v.frets[s]
                if f < 0 {
                    ctx.draw(Text("×").font(markerFont).foregroundColor(theme.subtextColor), at: CGPoint(x: x, y: topPad * 0.45))
                } else if f == 0 {
                    let isRoot = v.pitchClass(string: s) == root
                    let r = topPad * 0.24
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: topPad * 0.45 - r, width: 2 * r, height: 2 * r)),
                               with: .color(isRoot ? theme.accentColor : theme.subtextColor), lineWidth: 1.4)
                } else {
                    // skip dots that are covered by the barre (unless it's the root on the barre)
                    let onBarre = v.barreFret == f && s >= v.barreFromString
                    let isRoot = v.pitchClass(string: s) == root
                    if onBarre && !isRoot { continue }
                    let y = topPad + (CGFloat(f - base) + 0.5) * fy
                    let rect = CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(isRoot ? theme.accentColor : theme.accent2Color))
                }
            }
        }
    }
}

/// Compact "chord vocabulary" card: name + diagram, used in the song-chords strip.
struct ChordShapeCard: View {
    @Environment(\.appTheme) private var theme
    let segment: ChordSegment
    let style: ChordDiagramStyle
    let transpose: Int
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(segment.name(transpose: transpose))
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? theme.accentColor : theme.textColor)
            ChordDiagramView(style: style, segment: segment, transpose: transpose)
                .frame(width: style == .guitar ? 50 : 76, height: style == .guitar ? 56 : 30)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent ? theme.accentColor.opacity(0.12) : theme.elevatedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCurrent ? theme.accentColor.opacity(0.6) : theme.borderColor, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}
