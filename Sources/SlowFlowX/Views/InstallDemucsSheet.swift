import SwiftUI

/// Installs Demucs (Homebrew → uv → Demucs on Python 3.12 with torch/torchaudio 2.8) and shows the log.
struct InstallDemucsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let installed = model.tools.demucsReady
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentGradient)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Demucs")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                    Text("AI stem separation by Meta AI Research · runs locally on your Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.subtextColor)
                }
            }

            Text("SlowFlowX will run these steps for you (about 1–2 GB download, a few minutes):")
                .font(.system(size: 12))
                .foregroundStyle(theme.textColor)
            VStack(alignment: .leading, spacing: 4) {
                step("1", "brew install uv", "only if uv isn't installed yet")
                step("2", "uv tool install --python 3.12 demucs --with torch==2.8.* --with torchaudio==2.8.* --with numpy --with soundfile",
                     "Python 3.12 and torch 2.8 avoid known build/TorchCodec problems; numpy and soundfile are missing dependencies")
                step("3", "demucs --help", "self-test")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.demucsInstallLog.isEmpty ? "The installation log will appear here." : model.demucsInstallLog)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(model.demucsInstallLog.isEmpty ? theme.subtextColor : theme.textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("log")
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedColor))
                .onChange(of: model.demucsInstallLog) { _, _ in
                    proxy.scrollTo("log", anchor: .bottom)
                }
            }

            if model.tools.demucsBroken && !model.demucsInstalling && model.demucsInstallError == nil {
                Label("Demucs is installed but doesn't run: \(model.tools.demucsProblem ?? "unknown error"). Click Repair.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if let err = model.demucsInstallError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if installed && !model.demucsInstalling && !model.demucsInstallLog.isEmpty {
                Label("Demucs is ready. Use “Separate (Demucs AI)” in the Stems bar.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }

            HStack {
                if model.demucsInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing… you can keep using SlowFlowX.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.subtextColor)
                }
                Spacer()
                Button(model.demucsInstalling ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(GhostButtonStyle())
                Button(installed ? "Reinstall" : (model.tools.demucsBroken ? "Repair" : "Install")) { model.installDemucs() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.demucsInstalling)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(theme.surfaceColor)
    }

    private func step(_ n: String, _ cmd: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(theme.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textColor)
                Text(note).font(.system(size: 10.5)).foregroundStyle(theme.subtextColor)
            }
        }
    }
}
