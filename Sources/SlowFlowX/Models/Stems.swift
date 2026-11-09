import Foundation
import SwiftUI

enum StemKind: String, Codable, CaseIterable, Identifiable {
    case vocals, drums, bass, guitar, piano, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .guitar: return "Guitar"
        case .piano: return "Piano"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "metronome.fill"
        case .bass: return "waveform.path"
        case .guitar: return "guitars"
        case .piano: return "pianokeys"
        case .other: return "square.stack.3d.up"
        }
    }

    var color: Color {
        switch self {
        case .vocals: return Color(red: 0.96, green: 0.45, blue: 0.62)
        case .drums: return Color(red: 0.98, green: 0.72, blue: 0.30)
        case .bass: return Color(red: 0.40, green: 0.62, blue: 0.98)
        case .guitar: return Color(red: 0.36, green: 0.85, blue: 0.62)
        case .piano: return Color(red: 0.72, green: 0.56, blue: 0.98)
        case .other: return Color(red: 0.60, green: 0.66, blue: 0.74)
        }
    }
}

enum StemEngine: String, Codable {
    case demucs, builtin

    var label: String { self == .demucs ? "Demucs (AI)" : "Built-in (quick)" }
}

struct StemSet: Codable, Hashable {
    var engine: StemEngine
    var model: String
    /// StemKind.rawValue → file name inside the song's stem folder.
    var files: [String: String]
    var createdAt: Date

    var kinds: [StemKind] { StemKind.allCases.filter { files[$0.rawValue] != nil } }

    func url(_ kind: StemKind, songID: String) -> URL? {
        guard let name = files[kind.rawValue] else { return nil }
        return LibraryPaths.stems(songID).appendingPathComponent(name)
    }

    /// The stem that best isolates a transcription part.
    func bestStem(for source: MelodySource) -> StemKind? {
        let order: [StemKind]
        switch source {
        case .vocal: order = [.vocals]
        case .bass: order = [.bass]
        case .lead, .rhythm: order = [.guitar, .other, .piano]
        }
        return order.first { files[$0.rawValue] != nil }
    }
}

/// Per-stem mixer state (not persisted).
struct StemMixState: Hashable {
    var muted = false
    var solo = false
    var volume: Float = 1
}

extension LibraryPaths {
    static func stems(_ songID: String) -> URL {
        let dir = root.appendingPathComponent("Stems", isDirectory: true).appendingPathComponent(songID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum DemucsModel: String, CaseIterable, Identifiable {
    case sixStem = "htdemucs_6s"
    case fourStem = "htdemucs"
    case fineTuned = "htdemucs_ft"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixStem: return "6 stems (vocals, drums, bass, guitar, piano, other)"
        case .fourStem: return "4 stems (vocals, drums, bass, other) – fast"
        case .fineTuned: return "4 stems, fine-tuned – best quality, ~4× slower"
        }
    }

    static var current: DemucsModel {
        DemucsModel(rawValue: UserDefaults.standard.string(forKey: "demucsModel") ?? "") ?? .sixStem
    }
}
