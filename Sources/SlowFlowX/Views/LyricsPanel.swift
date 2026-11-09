import SwiftUI

struct LyricsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    let song: Song
    @State private var showSearch = false

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Lyrics", icon: "text.quote") {
                if let lyrics = song.lyrics, lyrics.source != .notFound {
                    Badge(text: lyrics.source.label)
                }
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Search lyrics manually")
                .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                    LyricsSearchPopover(song: song) { artist, title in
                        showSearch = false
                        model.fetchLyrics(song.id, artist: artist, title: title)
                    }
                }
            }

            if model.lyricsLoading.contains(song.id) {
                Spacer()
                HStack { Spacer(); ProgressView("Looking for lyrics…"); Spacer() }
                Spacer()
            } else if let lyrics = song.lyrics, !lyrics.lines.isEmpty {
                LyricsScroller(lyrics: lyrics,
                               chords: song.analysis?.chords ?? [],
                               time: player.currentTime,
                               transpose: player.pitchSemitones,
                               onSeek: { player.seek(to: $0) })
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else if song.lyrics?.source == .instrumental {
                placeholder(icon: "guitars", title: "Instrumental", text: "This track has no vocals.")
            } else if song.lyrics != nil {
                VStack(spacing: 14) {
                    Spacer()
                    placeholder(icon: "text.magnifyingglass", title: "No lyrics found",
                                text: "Try a manual search with the exact artist and title,\nor transcribe the vocals on-device (approximate).")
                    HStack(spacing: 10) {
                        Button("Search…") { showSearch = true }.buttonStyle(GhostButtonStyle())
                        Button("Transcribe from Audio") { model.transcribeLyrics(song.id) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func placeholder(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(theme.subtextColor.opacity(0.7))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textColor)
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.subtextColor)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LyricsScroller: View {
    @Environment(\.appTheme) private var theme
    let lyrics: Lyrics
    let chords: [ChordSegment]
    let time: Double
    let transpose: Int
    let onSeek: (Double) -> Void

    var body: some View {
        let current = lyrics.lineIndex(at: time)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lyrics.lines) { line in
                        LyricRow(line: line,
                                 chordNames: chordNames(for: line),
                                 state: rowState(line.id, current: current),
                                 synced: lyrics.isSynced)
                            .id(line.id)
                            .onTapGesture { if let t = line.time { onSeek(t) } }
                    }
                }
                .padding(.vertical, 40)
                .padding(.horizontal, 4)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: current) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func rowState(_ id: Int, current: Int?) -> LyricRow.RowState {
        guard let current else { return .upcoming }
        if id == current { return .current }
        return id < current ? .past : .upcoming
    }

    /// Chords that sound during this line (shown above it like a chord sheet).
    private func chordNames(for line: LyricLine) -> [String] {
        guard let start = line.time, !chords.isEmpty else { return [] }
        let nextTime = lyrics.lines.first(where: { ($0.time ?? -1) > start })?.time ?? (start + 6)
        var names: [String] = []
        for seg in chords where seg.isChord && seg.end > start + 0.15 && seg.start < nextTime - 0.15 {
            let n = seg.name(transpose: transpose)
            if names.last != n { names.append(n) }
        }
        return names
    }
}

private struct LyricRow: View {
    enum RowState { case past, current, upcoming }
    @Environment(\.appTheme) private var theme
    let line: LyricLine
    let chordNames: [String]
    let state: RowState
    let synced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !chordNames.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(chordNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(state == .current ? theme.accent2Color : theme.accentColor.opacity(state == .past ? 0.5 : 0.85))
                    }
                }
            }
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: state == .current ? 19 : 15, weight: state == .current ? .bold : .medium, design: .rounded))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state == .current ? theme.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var color: Color {
        guard synced else { return theme.textColor }
        switch state {
        case .current: return theme.textColor
        case .past: return theme.subtextColor.opacity(0.55)
        case .upcoming: return theme.subtextColor
        }
    }
}

private struct LyricsSearchPopover: View {
    @Environment(\.appTheme) private var theme
    let song: Song
    let onSearch: (String, String) -> Void
    @State private var artist = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search lyrics")
                .font(.system(size: 13, weight: .semibold))
            TextField("Artist", text: $artist)
                .textFieldStyle(.roundedBorder)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSearch(artist, title) }
            HStack {
                Text("Powered by LRCLIB")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Search") { onSearch(artist, title) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            let q = LyricsService.query(for: song)
            artist = q.artist ?? ""
            title = q.title
        }
    }
}
