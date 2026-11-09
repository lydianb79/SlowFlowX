import Foundation

// MARK: - Melody model

enum MelodySource: String, Codable, CaseIterable, Identifiable {
    case vocal, lead, rhythm, bass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vocal: return "Vocal melody"
        case .lead: return "Lead / riff"
        case .rhythm: return "Rhythm guitar"
        case .bass: return "Bass line"
        }
    }

    var shortLabel: String {
        switch self {
        case .vocal: return "Vocal"
        case .lead: return "Lead"
        case .rhythm: return "Rhythm"
        case .bass: return "Bass"
        }
    }

    var icon: String {
        switch self {
        case .vocal: return "music.mic"
        case .lead: return "guitars"
        case .rhythm: return "hand.draw"
        case .bass: return "waveform.path"
        }
    }

    /// Fundamental-frequency search range in Hz (pitched parts).
    var frequencyRange: ClosedRange<Double> {
        switch self {
        case .vocal: return 110...880      // A2 – A5
        case .lead: return 82...1320       // E2 – E6
        case .rhythm: return 82...1320
        case .bass: return 40...330        // E1 – E4
        }
    }

    /// Frequency band used for attack (onset) detection.
    var onsetBand: ClosedRange<Double> {
        switch self {
        case .vocal: return 150...4000
        case .lead: return 120...6000
        case .rhythm: return 150...6000
        case .bass: return 40...600
        }
    }

    var harmonics: Int { self == .bass ? 8 : 10 }

    /// Plucked instruments decay, so their notes end when the sound dies away.
    var isPlucked: Bool { self != .vocal }

    var isRhythm: Bool { self == .rhythm }

    /// Instrument used for the tab view.
    var tabInstrument: TabInstrument { self == .bass ? .bass : .guitar }
}

struct MelodyNote: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var midi: Int
    var confidence: Float

    var id: Double { start }
    var duration: Double { end - start }

    func name(transpose: Int = 0) -> String { MidiNote.name(midi + transpose) }
}

/// One strum of a rhythm-guitar part.
struct Strum: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var down: Bool
    var strength: Float

    var id: Double { start }
}

struct MelodyTrack: Codable, Hashable {
    var source: MelodySource
    var notes: [MelodyNote]
    var analyzedAt: Date
    var usedMetal: Bool
    /// Tempo and first-beat position detected for this part (seconds).
    var bpm: Double? = nil
    var beatOffset: Double? = nil
    /// Rhythm part only.
    var strums: [Strum]? = nil

    var isEmpty: Bool { source.isRhythm ? (strums ?? []).isEmpty : notes.isEmpty }
    var eventCount: Int { source.isRhythm ? (strums ?? []).count : notes.count }

    func noteIndex(at time: Double) -> Int? {
        guard !notes.isEmpty else { return nil }
        var lo = 0, hi = notes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if notes[mid].start <= time { lo = mid } else { hi = mid - 1 }
        }
        let n = notes[lo]
        return (n.start <= time && time < n.end) ? lo : nil
    }

    func strumIndex(at time: Double) -> Int? {
        guard let s = strums, !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if s[mid].start <= time { lo = mid } else { hi = mid - 1 }
        }
        return (s[lo].start <= time && time < s[lo].end) ? lo : nil
    }

    func grid(fallbackBPM: Double) -> RhythmGrid {
        let own = bpm ?? 0
        let b = own > 30 ? own : (fallbackBPM > 30 ? fallbackBPM : 120)
        return RhythmGrid(bpm: b, offset: beatOffset ?? 0)
    }

    /// Notes to display for this part. For the rhythm part these are the chord tones of each strum.
    func displayNotes(chords: [ChordSegment]) -> [MelodyNote] {
        guard source.isRhythm else { return notes }
        var out: [MelodyNote] = []
        for s in strums ?? [] {
            guard let chord = Self.chord(at: s.start + 0.02, in: chords) else { continue }
            for (i, iv) in chord.quality.intervals.enumerated() {
                // close voicing: root in octave 3, upper tones an octave higher
                let midi = 48 + chord.root + iv + (i == 0 ? 0 : 12)
                out.append(MelodyNote(start: s.start + Double(i) * 0.0001, end: s.end, midi: midi, confidence: s.strength))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func chord(at time: Double, in chords: [ChordSegment]) -> ChordSegment? {
        guard let c = chords.last(where: { $0.start <= time }), c.isChord, time < c.end else { return nil }
        return c
    }
}

enum MidiNote {
    static func name(_ midi: Int) -> String {
        ChordNaming.noteName(midi % 12) + "\(midi / 12 - 1)"
    }

    static func isBlack(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12)
    }
}

// MARK: - Rhythm grid & note values

/// Beat grid: 16th-note steps counted from the first detected beat.
struct RhythmGrid: Hashable {
    let bpm: Double
    let offset: Double

    var beat: Double { 60 / bpm }
    var step: Double { beat / 4 }

    func stepPosition(_ t: Double) -> Double { (t - offset) / step }
    func time(ofStep s: Double) -> Double { offset + s * step }
}

struct RhythmValue: Hashable {
    let sixteenths: Int     // base value: 1 = 16th, 2 = 8th, 4 = quarter, 8 = half, 16 = whole
    let dotted: Bool

    var flags: Int { sixteenths == 1 ? 2 : (sixteenths == 2 ? 1 : 0) }
    var hasStem: Bool { sixteenths < 16 }
    var isBeamable: Bool { sixteenths <= 2 }

    var symbol: String {
        let s: String
        switch sixteenths {
        case 1: s = "S"
        case 2: s = "E"
        case 4: s = "Q"
        case 8: s = "H"
        default: s = "W"
        }
        return dotted ? s + "." : s
    }

    /// Nearest standard note value for a length in 16th steps.
    static func from(steps: Int) -> RhythmValue {
        switch max(1, steps) {
        case 1: return RhythmValue(sixteenths: 1, dotted: false)
        case 2: return RhythmValue(sixteenths: 2, dotted: false)
        case 3: return RhythmValue(sixteenths: 2, dotted: true)
        case 4, 5: return RhythmValue(sixteenths: 4, dotted: false)
        case 6, 7: return RhythmValue(sixteenths: 4, dotted: true)
        case 8...10: return RhythmValue(sixteenths: 8, dotted: false)
        case 11...13: return RhythmValue(sixteenths: 8, dotted: true)
        default: return RhythmValue(sixteenths: 16, dotted: false)
        }
    }
}

/// A note or strum placed on the 16th grid.
struct GridEvent: Hashable {
    let index: Int
    let startStep: Int
    let endStep: Int
    var steps: Int { max(1, endStep - startStep) }
    var value: RhythmValue { RhythmValue.from(steps: steps) }
}

enum RhythmQuantizer {
    /// Places events on a grid of `resolution` 16ths (1 = 16ths, 2 = 8ths). Overlaps are clipped
    /// so every event ends no later than the next one starts.
    static func quantize(starts: [Double], ends: [Double], grid: RhythmGrid, resolution: Int) -> [GridEvent] {
        let r = Double(max(1, resolution))
        var events: [GridEvent] = []
        for i in starts.indices {
            let s = Int(((grid.stepPosition(starts[i]) / r).rounded()) * r)
            var e = Int(((grid.stepPosition(ends[i]) / r).rounded()) * r)
            if e <= s { e = s + Int(r) }
            events.append(GridEvent(index: i, startStep: s, endStep: e))
        }
        if events.count > 1 {
            for i in 0..<(events.count - 1) {
                let next = events[i + 1]
                if events[i].endStep > next.startStep && next.startStep > events[i].startStep {
                    events[i] = GridEvent(index: events[i].index, startStep: events[i].startStep, endStep: next.startStep)
                }
            }
        }
        return events
    }
}

// MARK: - Tab fingering

enum TabInstrument {
    case guitar, bass

    /// Open-string MIDI notes, low → high.
    var tuning: [Int] { self == .guitar ? [40, 45, 50, 55, 59, 64] : [28, 33, 38, 43] }
    var stringNames: [String] { self == .guitar ? ["E", "A", "D", "G", "B", "e"] : ["E", "A", "D", "G"] }
    var maxFret: Int { 20 }
    var lowest: Int { tuning[0] }
    var highest: Int { tuning[tuning.count - 1] + maxFret }
}

struct TabPosition: Hashable {
    let string: Int   // 0 = lowest string
    let fret: Int
    let octaveShift: Int  // octaves the note was moved to fit the instrument (0 = as played)
}

enum TabFingering {
    /// Chooses a string/fret for every note, minimising hand movement (dynamic programming).
    static func positions(for notes: [MelodyNote], instrument: TabInstrument, transpose: Int) -> [TabPosition] {
        guard !notes.isEmpty else { return [] }
        let tuning = instrument.tuning

        var candidates: [[TabPosition]] = []
        for n in notes {
            var midi = n.midi + transpose
            var shift = 0
            while midi < instrument.lowest { midi += 12; shift += 1 }
            while midi > instrument.highest { midi -= 12; shift -= 1 }
            var c: [TabPosition] = []
            for (s, open) in tuning.enumerated() {
                let f = midi - open
                if f >= 0 && f <= instrument.maxFret { c.append(TabPosition(string: s, fret: f, octaveShift: shift)) }
            }
            if c.isEmpty { c.append(TabPosition(string: 0, fret: 0, octaveShift: shift)) }
            candidates.append(c)
        }

        func positionCost(_ p: TabPosition) -> Double {
            (p.fret > 12 ? Double(p.fret - 12) * 0.35 : 0) + Double(p.fret) * 0.04
        }
        func moveCost(_ a: TabPosition, _ b: TabPosition, gap: Double) -> Double {
            let fretMove: Double = (a.fret == 0 || b.fret == 0) ? 1.0 : Double(abs(b.fret - a.fret))
            let stringMove = Double(abs(b.string - a.string)) * 0.25
            let span = (abs(b.fret - a.fret) > 4 && a.fret > 0 && b.fret > 0) ? 2.0 : 0
            let relax = gap > 1.2 ? 0.3 : 1.0
            return (fretMove + stringMove + span) * relax
        }

        var cost = candidates[0].map(positionCost)
        var back: [[Int]] = [Array(repeating: 0, count: candidates[0].count)]
        for i in 1..<candidates.count {
            let gap = notes[i].start - notes[i - 1].end
            var newCost: [Double] = []
            var choice: [Int] = []
            for b in candidates[i] {
                var best = Double.greatestFiniteMagnitude, bestJ = 0
                for (j, a) in candidates[i - 1].enumerated() {
                    let v = cost[j] + moveCost(a, b, gap: gap)
                    if v < best { best = v; bestJ = j }
                }
                newCost.append(best + positionCost(b))
                choice.append(bestJ)
            }
            cost = newCost
            back.append(choice)
        }
        var idx = cost.indices.min { cost[$0] < cost[$1] } ?? 0
        var result = [TabPosition](repeating: candidates[0][0], count: notes.count)
        for i in stride(from: notes.count - 1, through: 0, by: -1) {
            result[i] = candidates[i][idx]
            idx = back[i][idx]
        }
        return result
    }
}

// MARK: - Export formats

enum MelodyExport {

    /// Plain-text tablature on a 16th-note grid (4 bars per system) with a rhythm line underneath.
    static func asciiTab(track: MelodyTrack, chords: [ChordSegment], title: String, fallbackBPM: Double,
                         transpose: Int, resolution: Int) -> String {
        let instrument = track.source.tabInstrument
        let grid = track.grid(fallbackBPM: fallbackBPM)
        let strings = instrument.tuning.count
        let stepsPerBar = 16

        struct Col { var frets: [Int: Int] = [:]; var rhythm = ""; var stroke = ""; var chord = "" }
        var starts: [Double] = [], ends: [Double] = []
        var payload: [(frets: [Int: Int], stroke: String, chord: String)] = []

        if track.source.isRhythm {
            for s in track.strums ?? [] {
                guard let c = MelodyTrack.chord(at: s.start + 0.02, in: chords),
                      let v = GuitarChords.voicing(root: (c.root + transpose + 12) % 12, quality: c.quality) else { continue }
                var frets: [Int: Int] = [:]
                for (i, f) in v.frets.enumerated() where f >= 0 { frets[i] = f }
                starts.append(s.start); ends.append(s.end)
                payload.append((frets, s.down ? "D" : "U", c.name(transpose: transpose)))
            }
        } else {
            let positions = TabFingering.positions(for: track.notes, instrument: instrument, transpose: transpose)
            for (n, p) in zip(track.notes, positions) {
                starts.append(n.start); ends.append(n.end)
                payload.append(([p.string: p.fret], "", ""))
            }
        }
        guard !starts.isEmpty else { return "\(title)\n\n(no notes)\n" }

        let events = RhythmQuantizer.quantize(starts: starts, ends: ends, grid: grid, resolution: max(1, resolution))
        let firstBar = Int((Double(events.map(\.startStep).min() ?? 0) / Double(stepsPerBar)).rounded(.down))
        let lastStep = events.map(\.endStep).max() ?? stepsPerBar
        let bars = max(1, Int((Double(lastStep) / Double(stepsPerBar)).rounded(.up)) - firstBar)
        var cols = Array(repeating: Col(), count: bars * stepsPerBar)

        var lastChord = ""
        for e in events {
            let c = e.startStep - firstBar * stepsPerBar
            guard c >= 0 && c < cols.count, cols[c].rhythm.isEmpty else { continue }
            let p = payload[e.index]
            cols[c].frets = p.frets
            cols[c].rhythm = e.value.symbol
            cols[c].stroke = p.stroke
            if p.chord != lastChord { cols[c].chord = p.chord; lastChord = p.chord }
        }

        var out = "\(title)\n"
        out += "\(track.source.label) · auto-transcribed by SlowFlowX (approximate)\n"
        out += "Tempo ≈ \(Int(grid.bpm.rounded())) BPM · \(instrument == .guitar ? "Standard tuning EADGBE" : "Bass EADG")"
        if transpose != 0 { out += String(format: " · transposed %+d", transpose) }
        out += "\nRhythm: W whole · H half · Q quarter · E eighth · S sixteenth · . dotted"
        if track.source.isRhythm { out += " · D/U = down/up strum" }
        out += "\n\n"

        func cell(_ s: String) -> String { s.isEmpty ? "   " : s.padding(toLength: 3, withPad: " ", startingAt: 0) }
        var bar = 0
        while bar < bars {
            let endBar = min(bars, bar + 4)
            let t = grid.time(ofStep: Double((firstBar + bar) * stepsPerBar))
            out += "[\(formatTime(max(0, t)))]\n"
            if track.source.isRhythm {
                var line = "   "
                for b in bar..<endBar {
                    for k in 0..<stepsPerBar { line += cell(cols[b * stepsPerBar + k].chord) }
                    line += " "
                }
                out += line + "\n"
            }
            for s in stride(from: strings - 1, through: 0, by: -1) {
                var line = instrument.stringNames[s].padding(toLength: 2, withPad: " ", startingAt: 0) + "|"
                for b in bar..<endBar {
                    for k in 0..<stepsPerBar {
                        if let f = cols[b * stepsPerBar + k].frets[s] {
                            line += "\(f)".padding(toLength: 3, withPad: "-", startingAt: 0)
                        } else {
                            line += "---"
                        }
                    }
                    line += "|"
                }
                out += line + "\n"
            }
            var rhythm = "   ", strokes = "   "
            for b in bar..<endBar {
                for k in 0..<stepsPerBar {
                    rhythm += cell(cols[b * stepsPerBar + k].rhythm)
                    strokes += cell(cols[b * stepsPerBar + k].stroke)
                }
                rhythm += " "; strokes += " "
            }
            out += rhythm + "\n"
            if track.source.isRhythm { out += strokes + "\n" }
            out += "\n"
            bar = endBar
        }
        return out
    }

    /// Standard MIDI file (format 0). The first detected beat is aligned to a MIDI beat so notation
    /// programs show correct bar lines.
    static func midiFile(track: MelodyTrack, chords: [ChordSegment], title: String, fallbackBPM: Double,
                         transpose: Int, resolution: Int) -> Data {
        let ppq = 480
        let grid = track.grid(fallbackBPM: fallbackBPM)
        let notes = track.displayNotes(chords: chords)
        let shift = grid.beat * (grid.offset / grid.beat).rounded(.up) - grid.offset

        let quantized: [GridEvent]? = resolution > 0
            ? RhythmQuantizer.quantize(starts: notes.map(\.start), ends: notes.map(\.end), grid: grid, resolution: resolution)
            : nil
        func ticks(_ seconds: Double) -> Int { max(0, Int(((seconds + shift) / grid.beat * Double(ppq)).rounded())) }

        struct Event { let tick: Int; let order: Int; let bytes: [UInt8] }
        var events: [Event] = []
        for (i, n) in notes.enumerated() {
            var start = n.start, end = n.end
            if let q = quantized, i < q.count {
                start = grid.time(ofStep: Double(q[i].startStep))
                end = grid.time(ofStep: Double(q[i].endStep))
                if track.source.isRhythm { end = max(end, n.end) }   // chord tones share a strum: don't clip
            }
            let note = UInt8(clamping: max(0, min(127, n.midi + transpose)))
            let vel = UInt8(clamping: 60 + Int(min(max(n.confidence, 0), 1) * 50))
            let on = ticks(start), off = max(on + 1, ticks(end))
            events.append(Event(tick: on, order: 1, bytes: [0x90, note, vel]))
            events.append(Event(tick: off, order: 0, bytes: [0x80, note, 0]))
        }
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : $0.order < $1.order }

        func vlq(_ value: Int) -> [UInt8] {
            var v = max(0, value)
            var bytes: [UInt8] = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
            return bytes
        }

        var trackData: [UInt8] = []
        let name = Array(title.utf8.prefix(120))
        trackData += [0x00, 0xFF, 0x03] + vlq(name.count) + name
        let mpqn = Int(60_000_000 / grid.bpm)
        trackData += [0x00, 0xFF, 0x51, 0x03, UInt8((mpqn >> 16) & 0xFF), UInt8((mpqn >> 8) & 0xFF), UInt8(mpqn & 0xFF)]
        trackData += [0x00, 0xFF, 0x58, 0x04, 4, 2, 24, 8]               // 4/4
        let program: UInt8
        switch track.source {
        case .bass: program = 33
        case .lead: program = 29
        case .rhythm: program = 25
        case .vocal: program = 0
        }
        trackData += [0x00, 0xC0, program]
        var last = 0
        for e in events {
            trackData += vlq(e.tick - last) + e.bytes
            last = e.tick
        }
        trackData += [0x00, 0xFF, 0x2F, 0x00]

        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var file: [UInt8] = Array("MThd".utf8) + be32(6) + be16(0) + be16(1) + be16(ppq)
        file += Array("MTrk".utf8) + be32(trackData.count) + trackData
        return Data(file)
    }
}
