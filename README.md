<p align="center">
  <img src="Resources/AppIcon-1024.png" width="160" alt="SlowFlowX icon">
</p>

<h1 align="center">SlowFlowX</h1>

<p align="center">
  A native macOS practice studio for musicians.<br>
  Paste a YouTube link → see the chords and lyrics → slow it down without changing the pitch.
</p>

---

SlowFlowX downloads the audio of a song and detects its chords on the GPU with **Metal**. It shows time-synced lyrics with the chords above each line, and you can practise any section at any speed, as a loop, transposed to your key.

## Features

### Import
- **YouTube import**: paste a link and SlowFlowX downloads the audio with [`yt-dlp`](https://github.com/yt-dlp/yt-dlp). If `ffmpeg` is installed, the audio is converted to M4A.
- **Library**: every song you import stays in the sidebar, together with its analysis and lyrics.

### Chord analysis (Metal + Accelerate)
- The audio is turned into a spectrum with **vDSP** (8192-point FFT, 93 ms hop).
- The **`fold_chroma` Metal compute kernel** turns the spectrum into a 12-bin chromagram.
- The **`score_chords` Metal compute kernel** compares every frame against 48 chord templates (maj, min, 7, m7) that take harmonics into account.
- An **HMM / Viterbi** pass smooths the result so chord changes are stable and musical.
- **Key** (Krumhansl–Schmuckler) and **tempo** (onset autocorrelation) are estimated as well.

### Chords
- A large **current / next chord** display, including how long until the next change at your current speed.
- **Piano or guitar diagrams**. Switch in the Chords panel or in Settings.
  - Guitar uses open shapes where they exist and E- or A-shape barre chords for everything else.
  - Root notes are highlighted.
- **Chords in this song**: a strip showing every chord the song uses, with its shape.
- A **chord grid** you can click to jump to a chord. Right-click a chord to loop it.

### Lyrics
- **Synced lyrics** from [LRCLIB](https://lrclib.net), with the chords shown above each line. The current line is highlighted and auto-scrolls; click a line to jump to it.
- **Manual search** by artist and title, for when the automatic match misses.
- **On-device transcription** with Apple's speech recogniser, as a fallback. It is approximate on music.

### Practice
- **Slow down without changing pitch**: 25 – 150 % speed via `AVAudioUnitTimePitch`, with 50/75/100 % presets.
- **Transpose** ±12 semitones. The chords, key and diagrams follow.
- **Zoomable waveform** drawn with Metal:
  - Scroll or swipe to move through the song. Zoom with ⌘-scroll, a pinch, or the +/− buttons.
  - **Drag to select a section**. It becomes the A–B practice loop. Dragging past the edge scrolls the view.
  - A full-song **overview** above the waveform shows where you are and can be dragged.
  - A time ruler, and a chord lane that zooms with the waveform.
  - The view follows the playhead while playing.
- **A–B looping**, plus "Play Section" and "Zoom to Section".
- A **live spectrum analyser** (Metal) fed from an audio-engine tap.

### Export
- **Export WAV** of the whole song or the selected section.
- Optionally with your current speed and transpose applied (pitch preserved). Useful as a practice track for your phone.
- 16- or 24-bit. Rendering runs offline, faster than real time.

### Look & feel
- Native SwiftUI with **7 themes**: Midnight, Aurora, Ember, Ocean, Graphite, Paper (light) and Sakura (light).
- A custom app icon.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- Xcode 15+ **or** the Command Line Tools (Swift 5.9+)
- `yt-dlp`, plus `ffmpeg` (recommended):

```bash
brew install yt-dlp ffmpeg
```

## Build & run

```bash
git clone https://github.com/lydianb79/SlowFlowX.git
cd SlowFlowX
./Scripts/build_app.sh                    # → build/SlowFlowX.app (release)
open build/SlowFlowX.app

./Scripts/build_app.sh release --install  # also copies it to /Applications
```

To work in Xcode, open `Package.swift` and run the **SlowFlowX** scheme. Use the `.app` from the build script for speech transcription, because that feature needs the permission string in `Info.plist`.

The Metal shaders are compiled at runtime from `MetalShaders.swift`. You don't need the separate Metal toolchain or a `.metallib` build step.

## Keyboard & mouse

| Action | Shortcut |
|---|---|
| Play / pause | Space, or ⌘P |
| Back / forward 5 s | ← / →, or ⌘← / ⌘→ |
| Slower / faster / normal speed | ⌘[ / ⌘] / ⌘0 |
| Transpose down / up | ⌥⌘↓ / ⌥⌘↑ |
| Loop start / end / clear | ⇧⌘A / ⇧⌘B / ⇧⌘L |
| Export WAV | ⌘E |
| Move through the waveform | scroll or swipe |
| Zoom the waveform | ⌘-scroll or pinch |
| Select a section to practise | drag on the waveform |
| Jump to a position | click the waveform, a chord or a lyric line |

## Project layout

```
Sources/SlowFlowX/
  App/        SlowFlowXApp (scene, menus, key monitor), AppModel (state & workflows)
  Audio/      PlaybackEngine (AVAudioEngine + TimePitch), SpectrumTap (live FFT),
              AudioExporter (offline WAV render)
  Analysis/   AudioLoader (decode/resample), ChordAnalyzer (STFT → chroma → Viterbi, key, tempo)
  Metal/      MetalShaders (MSL source), MetalContext (pipelines + GPU compute),
              MetalViews (waveform & spectrum renderers, mouse/trackpad handling)
  Services/   YouTubeDownloader (yt-dlp), LyricsService (LRCLIB + Speech), ProcessRunner
  Theme/      Theme definitions + ThemeStore
  Views/      Sidebar, import bar, workspace & waveform, chords panel, chord diagrams,
              lyrics, transport, export sheet, settings
Resources/    Info.plist, AppIcon.icns, AppIcon.iconset, AppIcon-1024.png
Scripts/      build_app.sh
```

Your library (audio and analysis) is stored in `~/Library/Application Support/SlowFlowX/`.

## Troubleshooting

- **Downloads fail**: YouTube has probably changed something. Run `brew upgrade yt-dlp`.
- **"yt-dlp was not found"**: install it with Homebrew, then click *Re-check* on the start screen or in Settings › Tools.
- **No lyrics found**: use the 🔍 button in the Lyrics panel to search by exact artist and title, or transcribe from the audio.
- **Wrong chords**: automatic recognition is an estimate. It is very good for practice charts, but dense mixes, heavy distortion or jazz voicings will cause errors. Use the chord grid together with your ears.

## Credits

- Audio download: [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org)
- Synced lyrics: [LRCLIB](https://lrclib.net)
- Time-stretching, speech recognition and DSP: Apple AVFoundation, Speech and Accelerate

## Notice

Only download content that you have the right to use, and respect YouTube's Terms of Service. Lyrics are fetched at runtime from third-party services and are not part of this repository.
