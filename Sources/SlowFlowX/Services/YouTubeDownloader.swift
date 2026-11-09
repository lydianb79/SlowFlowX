import Foundation

struct VideoMetadata {
    let id: String
    let title: String
    let artist: String?
    let track: String?
    let uploader: String?
    let duration: Double
    let thumbnail: URL?
}

enum DownloadError: LocalizedError {
    case toolMissing
    case invalidURL
    case failed(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "yt-dlp was not found. Install it with Homebrew:  brew install yt-dlp ffmpeg"
        case .invalidURL:
            return "That doesn't look like a YouTube link."
        case .failed(let msg):
            return "yt-dlp reported an error:\n\(msg)\n\nIf YouTube changed something, updating usually helps:  brew upgrade yt-dlp"
        case .noOutput:
            return "The download finished but no audio file was produced."
        }
    }
}

/// Thin wrapper around the `yt-dlp` command-line tool.
final class YouTubeDownloader {

    static func isValidYouTubeURL(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com")
    }

    func metadata(for url: String) async throws -> VideoMetadata {
        guard let ytdlp = ToolLocator.find("yt-dlp") else { throw DownloadError.toolMissing }
        let result = try await ProcessRunner.run(
            ytdlp, ["-J", "--no-playlist", "--no-warnings", url],
            environment: ToolLocator.environment)

        guard result.status == 0,
              let obj = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let id = obj["id"] as? String else {
            throw DownloadError.failed(Self.tail(result.stderr))
        }

        let artist = (obj["artist"] as? String)
            ?? (obj["artists"] as? [String])?.joined(separator: ", ")
            ?? (obj["creator"] as? String)
        var uploader = (obj["channel"] as? String) ?? (obj["uploader"] as? String)
        if let u = uploader, u.hasSuffix(" - Topic") { uploader = String(u.dropLast(8)) }

        var thumb: URL?
        if let t = obj["thumbnail"] as? String { thumb = URL(string: t) }

        return VideoMetadata(
            id: id,
            title: (obj["title"] as? String) ?? id,
            artist: artist,
            track: obj["track"] as? String,
            uploader: uploader,
            duration: (obj["duration"] as? Double) ?? Double((obj["duration"] as? Int) ?? 0),
            thumbnail: thumb)
    }

    /// Downloads the best audio-only stream. Returns the URL of the resulting file.
    func downloadAudio(url: String, id: String, to directory: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let ytdlp = ToolLocator.find("yt-dlp") else { throw DownloadError.toolMissing }

        // Remove stale partial files from earlier attempts.
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in existing where f.lastPathComponent.hasPrefix(id + ".") { try? FileManager.default.removeItem(at: f) }
        }

        var args = [
            "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best",
            "--no-playlist", "--newline", "--progress", "--no-mtime", "--no-warnings",
            "-o", directory.appendingPathComponent("\(id).%(ext)s").path,
            "--print", "after_move:filepath"
        ]
        // With ffmpeg available, normalise everything to AAC/M4A which AVFoundation always decodes.
        if let ffmpeg = ToolLocator.find("ffmpeg") {
            args += ["-x", "--audio-format", "m4a", "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        args.append(url)

        let pathBox = LockedData()
        let progressRegex = try NSRegularExpression(pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#)

        let result = try await ProcessRunner.run(
            ytdlp, args, environment: ToolLocator.environment,
            onStdoutLine: { line in
                let ns = line as NSString
                if let m = progressRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let v = Double(ns.substring(with: m.range(at: 1))) {
                    progress(min(v / 100, 1))
                } else if line.hasPrefix("/") {
                    pathBox.append(Data((line + "\n").utf8))
                }
            })

        guard result.status == 0 else { throw DownloadError.failed(Self.tail(result.stderr)) }

        let printed = String(data: pathBox.value, encoding: .utf8)?
            .split(separator: "\n").map(String.init)
            .last { FileManager.default.fileExists(atPath: $0) }
        if let printed { return URL(fileURLWithPath: printed) }

        // Fallback: look for any file that starts with the video id.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if let f = files.first(where: { $0.lastPathComponent.hasPrefix(id + ".") && !$0.lastPathComponent.hasSuffix(".part") }) {
            return f
        }
        throw DownloadError.noOutput
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").suffix(4).joined(separator: "\n")
        return lines.isEmpty ? "Unknown error" : lines
    }
}
