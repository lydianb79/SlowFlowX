import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var filter = ""

    private var filtered: [Song] {
        guard !filter.isEmpty else { return model.songs }
        return model.songs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(filter) || $0.displayArtist.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppLogoMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SlowFlowX")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                    Text("Practice Studio")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.subtextColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.subtextColor)
                TextField("Filter library", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.borderColor))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            HStack {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.subtextColor)
                Spacer()
                Text("\(model.songs.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.subtextColor)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)

            if model.songs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.subtextColor.opacity(0.6))
                    Text("Songs you import appear here")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.subtextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(filtered) { song in
                        SongRow(song: song, isAnalyzing: model.analysisStatus[song.id] != nil)
                            .tag(song.id)
                            .contextMenu {
                                Button("Re-analyze Chords") { model.analyze(song.id) }
                                Button("Refresh Lyrics") { model.fetchLyrics(song.id) }
                                Divider()
                                Button("Show in Finder") { model.revealInFinder(song.id) }
                                Button("Open on YouTube") { model.openSource(song.id) }
                                Divider()
                                Button("Remove from Library", role: .destructive) { model.delete(song.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.surfaceColor)
    }
}

private struct SongRow: View {
    @Environment(\.appTheme) private var theme
    let song: Song
    let isAnalyzing: Bool

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: song.thumbnailURL, size: 38, corner: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(song.displayArtist)
                        .lineLimit(1)
                    if let a = song.analysis {
                        Text("·")
                        Text(a.keyName())
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.subtextColor)
            }
            Spacer(minLength: 0)
            if isAnalyzing {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }
}
