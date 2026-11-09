import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var themes
    @Environment(\.appTheme) private var theme
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            DetailView()
        }
        .background(theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeMenu()
            }
        }
        .toolbarBackground(theme.background, for: .windowToolbar)
        .sheet(isPresented: $model.showDemucsInstaller) {
            InstallDemucsSheet()
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .onAppear { KeyMonitor.shared.install(model: model) }
    }
}

struct ThemeMenu: View {
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        Menu {
            ForEach(AppTheme.all) { t in
                Button {
                    themes.select(t)
                } label: {
                    if t.id == themes.current.id {
                        Label(t.name, systemImage: "checkmark")
                    } else {
                        Text(t.name)
                    }
                }
            }
        } label: {
            Label("Theme", systemImage: "paintpalette")
        }
        .help("Change theme")
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ImportBar()
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 14)
            if let song = model.selectedSong {
                SongWorkspace(song: song)
            } else {
                EmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
