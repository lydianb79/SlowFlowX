import Foundation

/// MusicXML export of a transcribed part, readable by Guitar Pro (7/8), MuseScore and TuxGuitar.
/// Guitar and bass parts are written as a TAB staff with the tuning and every note's string and
/// fret, so the fingering survives the import; the vocal melody is written as a normal treble staff.
enum MusicXMLExport {
    private struct Event {
        var start: Int                    // 16th steps from bar 1, beat 1
        var end: Int
        var notes: [(midi: Int, string: Int?, fret: Int?)]   // string: MusicXML numbering (1 = highest)
    }

    static func document(track: MelodyTrack, title: String, artist: String, fallbackBPM: Double, transpose: Int) -> String {
        let grid = track.grid(fallbackBPM: fallbackBPM)
        let tab = track.source != .vocal
        let instrument = track.instrument
        let events = buildEvents(track: track, grid: grid, transpose: transpose, tab: tab, instrument: instrument)

        let bpm = Int(grid.bpm.rounded())
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <work><work-title>\(esc(title))</work-title></work>
          <identification>
            <creator type="composer">\(esc(artist))</creator>
            <encoding><software>SlowFlowX (auto-transcribed)</software><encoding-date>\(isoDate())</encoding-date></encoding>
          </identification>
          <part-list>
            <score-part id="P1">
              <part-name>\(esc(partName(track.source)))</part-name>
              <score-instrument id="P1-I1"><instrument-name>\(esc(partName(track.source)))</instrument-name></score-instrument>
              <midi-instrument id="P1-I1"><midi-channel>1</midi-channel><midi-program>\(midiProgram(track.source))</midi-program></midi-instrument>
            </score-part>
          </part-list>
          <part id="P1">

        """

        let firstBar = events.map { floorDiv($0.start, 16) }.min() ?? 0
        let lastBar = max(firstBar, events.map { floorDiv(max($0.start, $0.end - 1), 16) }.max() ?? 0)
        var ei = 0
        // pieces of an event that spill over into the next bar (tied)
        var carry: Event?

        for (n, bar) in (firstBar...lastBar).enumerated() {
            let barStart = bar * 16, barEnd = barStart + 16
            x += "    <measure number=\"\(n + 1)\">\n"
            if n == 0 {
                x += attributes(tab: tab, instrument: instrument)
                x += """
                      <direction placement="above">
                        <direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>\(bpm)</per-minute></metronome></direction-type>
                        <sound tempo="\(bpm)"/>
                      </direction>

                """
            }
            var cursor = barStart

            func emit(_ e: Event, from s: Int, to t: Int, tieStart: Bool, tieStop: Bool) {
                if s > cursor { x += rests(cursor, s) }
                let pieces = split(from: s, length: t - s)
                for (pi, len) in pieces.enumerated() {
                    let first = pi == 0, last = pi == pieces.count - 1
                    x += notesXML(e.notes, length: len,
                                  tieStop: tieStop || !first,
                                  tieStart: tieStart || !last)
                }
                cursor = t
            }

            if let c = carry {
                let t = min(c.end, barEnd)
                emit(c, from: barStart, to: t, tieStart: c.end > barEnd, tieStop: true)
                carry = c.end > barEnd ? c : nil
            }
            while ei < events.count && events[ei].start < barEnd {
                let e = events[ei]
                ei += 1
                let s = max(e.start, cursor)
                guard e.end > s else { continue }
                let t = min(e.end, barEnd)
                emit(e, from: s, to: t, tieStart: e.end > barEnd, tieStop: false)
                if e.end > barEnd { carry = e }
            }
            if cursor < barEnd { x += rests(cursor, barEnd) }
            x += "    </measure>\n"
        }
        x += "  </part>\n</score-partwise>\n"
        return x
    }

    // MARK: Events

    private static func buildEvents(track: MelodyTrack, grid: RhythmGrid, transpose: Int, tab: Bool,
                                    instrument: TabInstrument) -> [Event] {
        let notes = track.notes
        guard !notes.isEmpty else { return [] }
        let positions = tab ? TabFingering.positions(for: notes, instrument: instrument, transpose: transpose) : []
        let groups = NoteGrouping.groups(notes)
        let starts = groups.map { notes[$0[0]].start }
        let ends = groups.map { g in g.map { notes[$0].end }.max() ?? notes[g[0]].start }
        let q = RhythmQuantizer.quantize(starts: starts, ends: ends, grid: grid, resolution: 1)
        let count = instrument.stringCount

        var out: [Event] = []
        for e in q {
            var ns: [(midi: Int, string: Int?, fret: Int?)] = []
            var used = Set<Int>()
            for i in groups[e.index] {
                if tab {
                    guard let p = positions[i], used.insert(p.string).inserted else { continue }
                    ns.append((midi: instrument.tuning[p.string] + p.fret, string: Optional(count - p.string), fret: Optional(p.fret)))
                } else if used.insert(notes[i].midi + transpose).inserted {
                    ns.append((midi: notes[i].midi + transpose, string: nil, fret: nil))
                }
            }
            guard !ns.isEmpty else { continue }
            if !tab { ns = [ns.max { $0.midi < $1.midi }!] }   // one melody line
            if let last = out.last, last.start == e.startStep {
                // attacks that land on the same 16th: one chord
                var merged = last
                for n in ns where !merged.notes.contains(where: { $0.midi == n.midi || ($0.string != nil && $0.string == n.string) }) {
                    merged.notes.append(n)
                }
                merged.end = max(merged.end, e.endStep)
                out[out.count - 1] = merged
            } else {
                out.append(Event(start: e.startStep, end: e.endStep, notes: ns))
            }
        }
        // one voice: no overlaps
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].end = max(out[i].start + 1, out[i + 1].start)
        }
        return out.map { e in
            var e = e
            e.notes.sort { $0.midi < $1.midi }
            return e
        }
    }

    // MARK: XML pieces

    private static func attributes(tab: Bool, instrument: TabInstrument) -> String {
        var s = """
              <attributes>
                <divisions>4</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>

        """
        if tab {
            s += "        <clef><sign>TAB</sign><line>5</line></clef>\n"
            s += "        <staff-details>\n          <staff-lines>\(instrument.stringCount)</staff-lines>\n"
            for (i, m) in instrument.tuning.enumerated() {
                let (step, alter, octave) = pitch(m)
                s += "          <staff-tuning line=\"\(i + 1)\"><tuning-step>\(step)</tuning-step>"
                if alter != 0 { s += "<tuning-alter>\(alter)</tuning-alter>" }
                s += "<tuning-octave>\(octave)</tuning-octave></staff-tuning>\n"
            }
            s += "        </staff-details>\n"
        } else {
            s += "        <clef><sign>G</sign><line>2</line></clef>\n"
        }
        s += "      </attributes>\n"
        return s
    }

    private static func notesXML(_ notes: [(midi: Int, string: Int?, fret: Int?)], length: Int,
                                 tieStop: Bool, tieStart: Bool) -> String {
        let (type, dots) = noteType(length)
        var s = ""
        for (k, n) in notes.enumerated() {
            let (step, alter, octave) = pitch(n.midi)
            s += "      <note>\n"
            if k > 0 { s += "        <chord/>\n" }
            s += "        <pitch><step>\(step)</step>"
            if alter != 0 { s += "<alter>\(alter)</alter>" }
            s += "<octave>\(octave)</octave></pitch>\n"
            s += "        <duration>\(length)</duration>\n"
            if tieStop { s += "        <tie type=\"stop\"/>\n" }
            if tieStart { s += "        <tie type=\"start\"/>\n" }
            s += "        <voice>1</voice>\n        <type>\(type)</type>\n"
            s += String(repeating: "        <dot/>\n", count: dots)
            var notations = ""
            if tieStop { notations += "<tied type=\"stop\"/>" }
            if tieStart { notations += "<tied type=\"start\"/>" }
            if let st = n.string, let fr = n.fret {
                notations += "<technical><string>\(st)</string><fret>\(fr)</fret></technical>"
            }
            if !notations.isEmpty { s += "        <notations>\(notations)</notations>\n" }
            s += "      </note>\n"
        }
        return s
    }

    private static func rests(_ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        if from % 16 == 0 && to - from == 16 {
            return "      <note><rest measure=\"yes\"/><duration>16</duration><voice>1</voice></note>\n"
        }
        var s = ""
        for len in split(from: from, length: to - from) {
            let (type, dots) = noteType(len)
            s += "      <note><rest/><duration>\(len)</duration><voice>1</voice><type>\(type)</type>"
            s += String(repeating: "<dot/>", count: dots) + "</note>\n"
        }
        return s
    }

    /// Splits a length (in 16ths, starting at `from`) into note values that can be written,
    /// breaking at beat boundaries for off-beat starts so the rhythm stays readable.
    private static func split(from: Int, length: Int) -> [Int] {
        let allowed = [16, 12, 8, 6, 4, 3, 2, 1]
        var out: [Int] = []
        var pos = from, left = length
        while left > 0 {
            var maxLen = left
            let inBeat = ((pos % 4) + 4) % 4
            if inBeat != 0 { maxLen = min(maxLen, 4 - inBeat) }          // finish the beat first
            else if ((pos % 8) + 8) % 8 != 0 {
                maxLen = min(maxLen, 4)                                    // beat 2 / 4: don't hide beat 3
            }
            let len = allowed.first { $0 <= maxLen } ?? 1
            out.append(len)
            pos += len; left -= len
        }
        return out
    }

    private static func noteType(_ len: Int) -> (String, Int) {
        switch len {
        case 16: return ("whole", 0)
        case 12: return ("half", 1)
        case 8: return ("half", 0)
        case 6: return ("quarter", 1)
        case 4: return ("quarter", 0)
        case 3: return ("eighth", 1)
        case 2: return ("eighth", 0)
        default: return ("16th", 0)
        }
    }

    private static func pitch(_ midi: Int) -> (String, Int, Int) {
        let names = [("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0),
                     ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0)]
        let pc = ((midi % 12) + 12) % 12
        return (names[pc].0, names[pc].1, floorDiv(midi, 12) - 1)
    }

    private static func partName(_ s: MelodySource) -> String {
        switch s {
        case .vocal: return "Vocals"
        case .lead: return "Lead Guitar"
        case .rhythm: return "Rhythm Guitar"
        case .bass: return "Bass"
        }
    }

    private static func midiProgram(_ s: MelodySource) -> Int {
        switch s {
        case .vocal: return 54          // voice oohs (1-based)
        case .lead: return 30           // overdriven guitar
        case .rhythm: return 31         // distortion guitar
        case .bass: return 34           // electric bass (finger)
        }
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func isoDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
