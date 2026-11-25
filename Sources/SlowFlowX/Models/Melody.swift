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

    var id: String { "\(start)|\(midi)" }
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
    /// Stem the part was transcribed from (nil = full mix).
    var stemUsed: String? = nil
    /// Transcription algorithm version (older tracks offer "Update Transcription").
    var version: Int? = nil
    /// Tuning used for the tab (id of a `Tuning` preset; nil = standard).
    var tuningID: String? = nil
    /// true when the player picked the tuning (kept when the part is transcribed again).
    var tuningUserSet: Bool? = nil
    /// "basic-pitch" (neural, polyphonic) or nil (classic single-pitch tracker).
    var engine: String? = nil
    static let currentVersion = 4
    var isOutdated: Bool { (version ?? 0) < Self.currentVersion }
    var usesNeuralModel: Bool { engine == "basic-pitch" }

    /// Older rhythm tracks only know strum times (shapes came from the chord analysis);
    /// new ones contain the real notes that were played.
    var usesStrums: Bool { source.isRhythm && notes.isEmpty && !(strums ?? []).isEmpty }

    var isEmpty: Bool { usesStrums ? (strums ?? []).isEmpty : notes.isEmpty }
    var eventCount: Int { usesStrums ? (strums ?? []).count : notes.count }

    /// Instrument and tuning the tab is written for.
    var instrument: TabInstrument {
        let fallback = source.tabInstrument
        guard let t = Tuning.preset(tuningID), t.isBass == fallback.isBass else { return fallback }
        return t
    }

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
        // Tracks from older versions measured tempo on the isolated stem, which is unreliable:
        // use the song's tempo for them until they are transcribed again.
        let trusted = (version ?? 0) >= 3
        let own = trusted ? (bpm ?? 0) : 0
        let b = own > 30 ? own : (fallbackBPM > 30 ? fallbackBPM : 120)
        return RhythmGrid(bpm: b, offset: trusted ? (beatOffset ?? 0) : 0)
    }

    /// Notes to display for this part. For the rhythm part these are the chord tones of each strum.
    func displayNotes(chords: [ChordSegment]) -> [MelodyNote] {
        guard usesStrums else { return notes }
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

/// A tuning: open-string MIDI notes from the lowest string up.
struct Tuning: Hashable, Identifiable {
    let id: String
    let name: String
    let openNotes: [Int]
    let isBass: Bool

    var tuning: [Int] { openNotes }
    var stringCount: Int { openNotes.count }
    var maxFret: Int { isBass ? 20 : 22 }
    var lowest: Int { openNotes[0] }
    var highest: Int { openNotes[openNotes.count - 1] + maxFret }

    /// Letter names, low → high. The top string is lower-case when it repeats the bottom one (E…e).
    var stringNames: [String] {
        var names = openNotes.map { ChordNaming.noteName(((($0 % 12) + 12) % 12)) }
        if names.count > 1, names[names.count - 1] == names[0] { names[names.count - 1] = names[names.count - 1].lowercased() }
        return names
    }

    /// e.g. "Drop C (CGCFAD)"
    var label: String { "\(name) (\(openNotes.map { ChordNaming.noteName((($0 % 12) + 12) % 12) }.joined()))" }

    static let guitar = Tuning(id: "std", name: "Standard", openNotes: [40, 45, 50, 55, 59, 64], isBass: false)
    static let bass = Tuning(id: "bass-std", name: "Standard", openNotes: [28, 33, 38, 43], isBass: true)

    static let guitarPresets: [Tuning] = [
        guitar,
        Tuning(id: "eb", name: "E♭ Standard", openNotes: [39, 44, 49, 54, 58, 63], isBass: false),
        Tuning(id: "dropd", name: "Drop D", openNotes: [38, 45, 50, 55, 59, 64], isBass: false),
        Tuning(id: "d", name: "D Standard", openNotes: [38, 43, 48, 53, 57, 62], isBass: false),
        Tuning(id: "dropcs", name: "Drop C♯", openNotes: [37, 44, 49, 54, 58, 63], isBass: false),
        Tuning(id: "dropc", name: "Drop C", openNotes: [36, 43, 48, 53, 57, 62], isBass: false),
        Tuning(id: "c", name: "C Standard", openNotes: [36, 41, 46, 51, 55, 60], isBass: false),
        Tuning(id: "dropb", name: "Drop B", openNotes: [35, 42, 47, 52, 56, 61], isBass: false),
        Tuning(id: "b", name: "B Standard", openNotes: [35, 40, 45, 50, 54, 59], isBass: false),
        Tuning(id: "dropa", name: "Drop A", openNotes: [33, 40, 45, 50, 54, 59], isBass: false),
        Tuning(id: "7b", name: "7-string Standard", openNotes: [35, 40, 45, 50, 55, 59, 64], isBass: false),
        Tuning(id: "7dropa", name: "7-string Drop A", openNotes: [33, 40, 45, 50, 55, 59, 64], isBass: false),
        Tuning(id: "8fs", name: "8-string Standard", openNotes: [30, 35, 40, 45, 50, 55, 59, 64], isBass: false),
    ]

    static let bassPresets: [Tuning] = [
        bass,
        Tuning(id: "bass-eb", name: "E♭ Standard", openNotes: [27, 32, 37, 42], isBass: true),
        Tuning(id: "bass-dropd", name: "Drop D", openNotes: [26, 33, 38, 43], isBass: true),
        Tuning(id: "bass-d", name: "D Standard", openNotes: [26, 31, 36, 41], isBass: true),
        Tuning(id: "bass-dropc", name: "Drop C", openNotes: [24, 31, 36, 41], isBass: true),
        Tuning(id: "bass-5", name: "5-string", openNotes: [23, 28, 33, 38, 43], isBass: true),
    ]

    static func presets(bass: Bool) -> [Tuning] { bass ? bassPresets : guitarPresets }

    static func preset(_ id: String?) -> Tuning? {
        guard let id else { return nil }
        return (guitarPresets + bassPresets).first { $0.id == id }
    }

    /// Picks the tuning a part was most likely played in from its lowest notes: the highest-pitched
    /// tuning that still reaches them, preferring drop tunings when the low string is used
    /// together with the string above it a fifth higher (power chords on one finger).
    static func suggest(for notes: [MelodyNote], bass: Bool) -> Tuning {
        let pitches = notes.filter { $0.confidence > 0.25 && $0.duration > 0.06 }.map(\.midi).sorted()
        guard pitches.count >= 8 else { return bass ? Self.bass : Self.guitar }
        // ignore the odd stray note: 1st percentile, but at least 3 notes at/below it
        let low = pitches[min(pitches.count - 1, max(2, pitches.count / 100))]
        let options = Self.presets(bass: bass)
        let standard = options[0]
        if low >= standard.lowest { return standard }

        let reaching = options.filter { $0.lowest <= low }
        guard !reaching.isEmpty else { return options.min { $0.lowest < $1.lowest } ?? standard }
        let best = reaching.max { a, b in
            if a.lowest != b.lowest { return a.lowest < b.lowest }
            // same low note: fewer strings first, then the drop tuning (most common in rock/metal)
            if a.stringCount != b.stringCount { return a.stringCount > b.stringCount }
            return !a.name.hasPrefix("Drop") && b.name.hasPrefix("Drop")
        }
        return best ?? standard
    }
}

typealias TabInstrument = Tuning

struct TabPosition: Hashable {
    let string: Int   // 0 = lowest string
    let fret: Int
    let octaveShift: Int  // octaves the note was moved to fit the instrument (0 = as played)
}

/// Notes that start together form one tab event (a chord / double stop).
enum NoteGrouping {
    static let tolerance = 0.035

    /// Indices of `notes` (sorted by start) grouped by common start time.
    static func groups(_ notes: [MelodyNote]) -> [[Int]] {
        var out: [[Int]] = []
        var groupStart = -Double.infinity
        for (i, n) in notes.enumerated() {
            if !out.isEmpty && n.start - groupStart <= tolerance {
                out[out.count - 1].append(i)
            } else {
                out.append([i]); groupStart = n.start
            }
        }
        return out
    }
}

enum TabFingering {
    /// A way to fret one event: one position per note of the group (nil = left out).
    private struct Shape {
        var positions: [Int: TabPosition]   // note index → position
        var low: Int                        // lowest fretted fret (Int.max if all open)
        var high: Int                       // highest fretted fret
        var intrinsic: Double               // cost independent of hand position
        var lowestString: Int
    }

    /// Chooses string and fret for every note the way a guitarist would:
    /// - notes that sound together become a chord shape: one note per string, within a hand span,
    ///   lower notes on lower strings (notes that can't be fitted are dropped, weakest first);
    /// - the fretting hand sits in a position (index finger on fret P, covering P…P+3) and a
    ///   dynamic-programming pass picks the sequence of positions with the least movement,
    ///   preferring the lower half of the neck and open strings where they fit.
    /// Returns one position per note; nil where a note was left out of an unplayable chord.
    static func positions(for notes: [MelodyNote], instrument: TabInstrument, transpose: Int) -> [TabPosition?] {
        guard !notes.isEmpty else { return [] }
        let tuning = instrument.tuning
        let groups = NoteGrouping.groups(notes)

        // Pitch of each note after folding it into the instrument's range.
        var pitch = [Int](repeating: 0, count: notes.count)
        var shift = [Int](repeating: 0, count: notes.count)
        for (i, n) in notes.enumerated() {
            var m = n.midi + transpose, s = 0
            while m < instrument.lowest { m += 12; s += 1 }
            while m > instrument.highest { m -= 12; s -= 1 }
            pitch[i] = m; shift[i] = s
        }

        func enumerateShapes(_ members: [Int]) -> [Shape] {
            var result: [Shape] = []
            var current: [Int: TabPosition] = [:]
            func rec(_ k: Int, _ minString: Int, _ lo: Int, _ hi: Int) {
                if result.count > 400 { return }
                if k == members.count {
                    let span = hi >= lo ? hi - lo : 0
                    let used = current.values.map(\.string).sorted()
                    let skipped = used.count > 1 ? (used.last! - used.first! + 1 - used.count) : 0
                    let opens = current.values.filter { $0.fret == 0 }.count
                    var cost = Double(max(0, span - 3)) * 1.2 + Double(skipped) * 0.25
                    if members.count > 1 && opens > 0 && opens < members.count && span > 2 { cost += 0.4 } // awkward mix
                    result.append(Shape(positions: current, low: lo == Int.max ? Int.max : lo, high: hi,
                                        intrinsic: cost, lowestString: used.first ?? 0))
                    return
                }
                let i = members[k]
                for s in minString..<tuning.count {
                    let f = pitch[i] - tuning[s]
                    guard f >= 0 && f <= instrument.maxFret else { continue }
                    var nlo = lo, nhi = hi
                    if f > 0 { nlo = min(lo, f); nhi = max(hi, f) }
                    if nhi >= nlo && nhi != Int.min && nlo != Int.max && nhi - nlo > 4 { continue }   // beyond a stretch
                    current[i] = TabPosition(string: s, fret: f, octaveShift: shift[i])
                    rec(k + 1, s + 1, nlo, nhi)
                    current[i] = nil
                }
            }
            rec(0, 0, Int.max, Int.min)
            return result
        }

        // Candidate shapes per group (dropping notes until something is playable).
        var shapes: [[Shape]] = []
        for g in groups {
            // one note per pitch, low → high
            var seen = Set<Int>()
            var members = g.sorted { pitch[$0] < pitch[$1] }.filter { seen.insert(pitch[$0]).inserted }
            var found = enumerateShapes(members)
            while found.isEmpty && members.count > 1 {
                // drop the weakest note other than the lowest (the bass of the chord matters most)
                let rest = members.dropFirst()
                if let weakest = rest.min(by: { notes[$0].confidence < notes[$1].confidence }) {
                    members.removeAll { $0 == weakest }
                }
                found = enumerateShapes(members)
            }
            if found.count > 60 { found = Array(found.sorted { $0.intrinsic < $1.intrinsic }.prefix(60)) }
            shapes.append(found)
        }

        let maxPos = max(1, min(17, instrument.maxFret - 3))
        let positions = Array(1...maxPos)
        let P = positions.count

        /// Cost of a shape with the hand at `pos` (∞ if it can't be reached).
        func reach(_ sh: Shape, _ pos: Int) -> Double {
            var c = sh.intrinsic
            let chord = sh.positions.count > 1
            for p in sh.positions.values {
                if p.fret == 0 { c += chord ? 0.1 : 0.35; continue }
                if p.fret >= pos && p.fret <= pos + 3 { continue }
                if p.fret == pos - 1 || p.fret == pos + 4 { c += 1.0; continue }
                return .infinity
            }
            return c
        }
        func positionCost(_ pos: Int) -> Double { Double(pos) * 0.08 + Double(max(0, pos - 7)) * 0.25 }

        let G = groups.count
        var bestReach = [[Double]](repeating: [Double](repeating: .infinity, count: P), count: G)
        for gi in 0..<G {
            for (pi, pos) in positions.enumerated() {
                bestReach[gi][pi] = shapes[gi].map { reach($0, pos) }.min() ?? 0
            }
        }
        func gStart(_ gi: Int) -> Double { notes[groups[gi][0]].start }
        func gEnd(_ gi: Int) -> Double { groups[gi].map { notes[$0].end }.max() ?? gStart(gi) }

        var cost = (0..<P).map { bestReach[0][$0] + positionCost(positions[$0]) }
        var back: [[Int]] = [Array(repeating: 0, count: P)]
        for gi in 1..<max(1, G) {
            let gap = gStart(gi) - gEnd(gi - 1)
            let relax = gap > 1.0 ? 0.35 : (gap > 0.3 ? 0.7 : 1.0)      // rests make shifting easy
            var newCost = [Double](repeating: .infinity, count: P)
            var choice = [Int](repeating: 0, count: P)
            for pi in 0..<P {
                let r = bestReach[gi][pi]
                guard r.isFinite else { continue }
                var best = Double.infinity, bestJ = 0
                for pj in 0..<P where cost[pj].isFinite {
                    let move = pi == pj ? 0 : (1.5 + 0.3 * Double(abs(pi - pj))) * relax
                    if cost[pj] + move < best { best = cost[pj] + move; bestJ = pj }
                }
                newCost[pi] = best + r + positionCost(positions[pi])
                choice[pi] = bestJ
            }
            if newCost.allSatisfy({ !$0.isFinite }) {
                let prevBest = cost.indices.min { cost[$0] < cost[$1] } ?? 0
                newCost = (0..<P).map { bestReach[gi][$0] + positionCost(positions[$0]) }
                choice = Array(repeating: prevBest, count: P)
            }
            cost = newCost
            back.append(choice)
        }

        var pIdx = cost.indices.min { cost[$0] < cost[$1] } ?? 0
        var handPos = [Int](repeating: 1, count: G)
        for gi in stride(from: G - 1, through: 0, by: -1) {
            handPos[gi] = positions[pIdx]
            pIdx = back[gi][pIdx]
        }

        var result = [TabPosition?](repeating: nil, count: notes.count)
        var prevString: Int?
        for gi in 0..<G {
            let pos = handPos[gi]
            guard let best = shapes[gi].min(by: { a, b in
                func score(_ s: Shape) -> Double {
                    reach(s, pos) + (prevString.map { Double(abs(s.lowestString - $0)) * 0.15 } ?? 0)
                }
                return score(a) < score(b)
            }) else { continue }
            for (i, p) in best.positions { result[i] = p }
            prevString = best.lowestString
        }
        return result
    }
}


// MARK: - Export formats

enum MelodyExport {

    /// Plain-text tablature on a 16th-note grid (4 bars per system) with a rhythm line underneath.
    static func asciiTab(track: MelodyTrack, chords: [ChordSegment], title: String, fallbackBPM: Double,
                         transpose: Int, resolution: Int) -> String {
        let instrument = track.instrument
        let grid = track.grid(fallbackBPM: fallbackBPM)
        let strings = instrument.tuning.count
        let stepsPerBar = 16

        struct Col { var frets: [Int: Int] = [:]; var rhythm = ""; var stroke = ""; var chord = "" }
        var starts: [Double] = [], ends: [Double] = []
        var payload: [(frets: [Int: Int], stroke: String, chord: String)] = []

        if track.usesStrums {
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
            for g in NoteGrouping.groups(track.notes) {
                var frets: [Int: Int] = [:]
                for i in g { if let p = positions[i] { frets[p.string] = p.fret } }
                guard !frets.isEmpty else { continue }
                starts.append(track.notes[g[0]].start)
                ends.append(g.map { track.notes[$0].end }.max() ?? track.notes[g[0]].end)
                let chord = MelodyTrack.chord(at: track.notes[g[0]].start + 0.02, in: chords)?.name(transpose: transpose) ?? ""
                payload.append((frets, "", track.source.isRhythm ? chord : ""))
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
        out += "\(track.source.label) · auto-transcribed by SlowFlowX\(track.usesNeuralModel ? " (Basic Pitch)" : "") – check by ear\n"
        out += "Tempo ≈ \(Int(grid.bpm.rounded())) BPM · \(instrument.isBass ? "Bass" : "Guitar"), \(instrument.label)"
        if transpose != 0 { out += String(format: " · transposed %+d", transpose) }
        out += "\nRhythm: W whole · H half · Q quarter · E eighth · S sixteenth · . dotted"
        if track.usesStrums { out += " · D/U = down/up strum" }
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
            if track.usesStrums { out += strokes + "\n" }
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
                if track.usesStrums { end = max(end, n.end) }   // chord tones share a strum: don't clip
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
