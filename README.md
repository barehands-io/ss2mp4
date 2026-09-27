# ss2mp4

Convert [Screen Studio](https://screen.studio) projects into compact HEVC MP4 files.

Screen Studio projects are large. They store high-bitrate H.264 screen recordings, and each project also keeps a second copy of the media as HLS segment files. `ss2mp4` produces an MP4 with the screen recording and the microphone and system audio mixed together. It uses the Mac's hardware HEVC encoder, and the output is typically **1–5% of the project's size**. For example, a 56-minute Retina recording went from 14.3 GB to 159 MB.

It is native Swift built on AVFoundation, with no dependencies such as ffmpeg. There's a command-line tool and a small Mac app for picking projects and exporting them; both use the same conversion code.

## Install

Requires macOS 13+ and the Xcode Command Line Tools. It's built for Apple silicon, which has hardware HEVC encoding.

```sh
make install          # builds and installs the command-line tool to ~/.local/bin/ss2mp4
make install PREFIX=/usr/local
make install-app      # builds and installs the app to ~/Applications/ss2mp4.app
make install-app APPDIR=/Applications
```

## App

The app lists the projects in `~/Screen Studio Projects` (you can pick another folder) with a thumbnail, recording date, length and size on disk, and marks the ones that already have an export. Tick the projects you want, choose the options and press **Export** (⌘E).

- **Video:** resolution (original, 2160p, 1440p, 1080p or 720p), frame rate (24, 30 or 60 fps) and quality.
- **Audio:** include or leave out the microphone and system audio, and optionally leave out audio that's muted in Screen Studio.
- **Save To:** the output folder (default `~/Movies/Screen Studio Exports`), and whether to replace existing exports.
- **Select:** all, none, not exported yet, or older than 7–365 days. Search and sorting are in the toolbar.

While exporting, the app shows progress, speed and time left, keeps the Mac awake, and shows the count in the Dock icon. **Stop** cancels the current export and removes its unfinished file; finished exports are kept. Settings and folders are remembered between launches. The app follows the same rules as the command-line tool below: it never changes your projects.

## Usage

```sh
ss2mp4 -n ~/"Screen Studio Projects"                # dry run: list what would be converted
ss2mp4 --older-than 30 ~/"Screen Studio Projects"   # convert projects older than 30 days
ss2mp4 --max-height 1080 --quality 0.45 path/to/Project.screenstudio
```

| Option | Default | Description |
|---|---|---|
| `-o, --output DIR` | `~/Movies/Screen Studio Exports` | Output folder |
| `--max-height N` | `1440` | Downscale so the height is at most N pixels; `0` keeps the original size |
| `--fps N` | `30` | Maximum output frame rate |
| `--quality Q` | `0.5` | Constant-quality level from 0.0 to 1.0 (higher means better quality and bigger files) |
| `--bitrate MBPS` | – | Use a fixed average bitrate instead of `--quality` |
| `--older-than D` | – | Only convert projects recorded more than D days ago |
| `--respect-mutes` | off | Leave out mic or system audio that is muted in the Screen Studio project |
| `-n, --dry-run` | – | List projects, lengths and sizes without converting anything |
| `--overwrite` | off | Re-convert even if the output file already exists |

Behavior:

- **Originals are never modified or deleted.** Once you've checked the exports, delete the projects yourself.
- Projects that already have an export are skipped, so you can safely re-run the same command.
- Each file is written under a hidden temporary name and renamed only after its duration and tracks are verified. Ctrl-C removes the unfinished file.
- Exported files get the original recording date as their creation and modification date.

## What's in the output

| Included | Not included yet |
|---|---|
| Screen recording, joined across paused and resumed sessions | Cuts and speed changes (`scenes[].slices`, `timeScale`) |
| Microphone and system audio, mixed | Webcam overlay |
| | Auto-zooms, cursor effects, backgrounds |

## Screen Studio project format (as observed)

```
Project.screenstudio/
  project.json                 # editor state: config, scenes[].slices, zoomRanges, ...
  recording/
    metadata.json              # recorders[] (display, microphone, systemAudio, webcam, ...) with sessions[]
    channel-2-display-0.mp4    # finished media, one file per recorder session (-0, -1, ...)
    channel-1-system-audio-0.m4a
    channel-3-microphone-0.m4a
    channel-4-webcam-0.mp4
    *.m3u8, *-0000.mp4, *.m4s  # HLS recording segments: a byte-for-byte duplicate of the finished media
    enhanced/*-enhanced.m4a    # often near-silent placeholders, so ss2mp4 uses the raw mic
```

- `metadata.json` points to the finished media through `recorders[].sessions[].outputFilename`.
- Sessions are sequential: a paused and resumed recording has one session per part.
- The recording start time is stored in `unixStartMs`.
- Renaming a project in Screen Studio can leave a tiny stub folder behind with only `recording/enhanced/`. `ss2mp4` skips these.

## Development

```sh
make && .build/ss2mp4 --help   # plain swiftc build (no SwiftPM or Xcode needed)
make app && open .build/ss2mp4.app
SS2MP4_DEBUG=1 ss2mp4 ...      # print reader/writer status after each conversion
```

The source is split by responsibility:

- `Sources/Core/` is the conversion engine shared by the tool and the app:
  - `Project.swift` discovers and loads Screen Studio projects.
  - `Composition.swift` joins recording sessions and prepares the video composition.
  - `Transcoder.swift` encodes and verifies the MP4.
  - `Export.swift` holds the export settings and converts one project: temporary file, verification, rename, and cancellation.
  - `Formatting.swift` formats errors, sizes and durations.
- `Sources/ss2mp4/` is the command-line tool: `CLI.swift` parses options, `Terminal.swift` prints progress, and `main.swift` runs the conversion loop.
- `Sources/App/` is the SwiftUI app: `ExportModel.swift` holds the project list, selection and export queue, `ContentView.swift` the window, `Thumbnails.swift` the previews, and `App.swift` the app lifecycle. `make app` bundles it with `Info.plist` and signs it ad hoc.

In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so the app keeps view state in `ObservableObject`s instead. That way it still builds with just the Command Line Tools.

Ideas for next steps:

- Apply cuts and speed changes from `project.json`
- Add the webcam as a picture-in-picture overlay
- Add a `--jobs N` option to run several conversions at once (M-series Max chips have two media engines)
- Add a `prune` command that removes the duplicate HLS segments and keeps projects editable
- Move to the macOS 27 `AVAssetReader`/`AVAssetWriter` output-provider and input-receiver APIs

## License

MIT. See [LICENSE](LICENSE).

`ss2mp4` isn't affiliated with Screen Studio. It reads the project files that Screen Studio writes and never changes them.
