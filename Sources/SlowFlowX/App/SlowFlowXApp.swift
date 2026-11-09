import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SlowFlowXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var themes = ThemeStore()

    var body: some Scene {
        WindowGroup("SlowFlowX") {
            ContentView()
                .environment(model)
                .environment(themes)
                .environment(\.appTheme, themes.current)
                .tint(themes.current.accentColor)
                .preferredColorScheme(themes.current.isDark ? .dark : .light)
                .frame(minWidth: 1120, minHeight: 740)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export WAV…") { model.showExportSheet = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedSong == nil || model.activity != nil)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { model.player.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Back 5 Seconds") { model.player.skip(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward 5 Seconds") { model.player.skip(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Slower") { model.player.setRate(model.player.rate - 0.05) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Faster") { model.player.setRate(model.player.rate + 0.05) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Normal Speed") { model.player.setRate(1) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Transpose Up") { model.player.setPitch(semitones: model.player.pitchSemitones + 1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Transpose Down") { model.player.setPitch(semitones: model.player.pitchSemitones - 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Set Loop Start (A)") { model.player.setLoopStartHere() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Set Loop End (B)") { model.player.setLoopEndHere() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Clear Loop") { model.player.clearLoop() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Theme") {
                ForEach(AppTheme.all) { theme in
                    Button(theme.name) { themes.select(theme) }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(themes)
                .environment(\.appTheme, themes.current)
                .tint(themes.current.accentColor)
                .preferredColorScheme(themes.current.isDark ? .dark : .light)
        }
    }
}

/// Space = play/pause, ←/→ = ±5 s, unless the user is typing in a text field.
@MainActor
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var token: Any?

    func install(model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }
            let keyCode = event.keyCode
            let window = event.window
            // Local monitors always run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                if window?.firstResponder is NSText { return false }   // user is typing
                switch keyCode {
                case 49: model.player.togglePlayPause(); return true     // space
                case 123: model.player.skip(by: -5); return true         // ←
                case 124: model.player.skip(by: 5); return true          // →
                default: return false
                }
            }
            return handled ? nil : event
        }
    }
}
