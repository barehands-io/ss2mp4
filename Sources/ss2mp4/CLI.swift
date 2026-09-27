// ss2mp4 — convert Screen Studio projects into compact HEVC MP4 files.
// Output contains the screen recording plus mixed microphone and system audio.
// Original projects are never modified; files are written to a separate folder.

import Darwin
import Foundation

let usage = """
Usage: ss2mp4 [options] <project.screenstudio | folder>...

Converts Screen Studio projects into compact HEVC MP4 files (screen + mixed
microphone/system audio). Folders are scanned for *.screenstudio projects.
Original projects are never modified.

Options:
  -o, --output DIR      Output folder (default: ~/Movies/Screen Studio Exports)
      --max-height N    Downscale so height is at most N pixels; 0 keeps original (default: 1440)
      --fps N           Output frame rate (default: 30)
      --quality Q       Constant-quality level 0.0-1.0, higher is better/larger (default: 0.5)
      --bitrate MBPS    Use a fixed average video bitrate instead of --quality
      --older-than D    Only convert projects recorded more than D days ago
      --respect-mutes   Leave out mic/system audio that is muted in the Screen Studio project
                        (by default all recorded audio is kept)
  -n, --dry-run         List what would be converted without writing anything
      --overwrite       Re-convert even if the output file already exists
  -h, --help            Show this help

Examples:
  ss2mp4 -n ~/"Screen Studio Projects"
  ss2mp4 --older-than 30 ~/"Screen Studio Projects"
  ss2mp4 --max-height 1080 --quality 0.45 "~/Screen Studio Projects/Team sync.screenstudio"
"""

// MARK: - Options

struct Options {
    var inputs: [String] = []
    var outputDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Screen Studio Exports", isDirectory: true)
    var settings = ExportSettings()
    var olderThanDays: Double?
    var dryRun = false
    var overwrite = false
}

func fail(_ msg: String) -> Never {
    printErr("ss2mp4: \(msg)")
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("missing value for \(flag)") }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "-o", "--output":
            o.outputDir = URL(fileURLWithPath: (value(a) as NSString).expandingTildeInPath, isDirectory: true)
        case "--max-height":
            guard let v = Int(value(a)), v >= 0 else { fail("--max-height expects a whole number >= 0") }
            o.settings.maxHeight = v
        case "--fps":
            guard let v = Int(value(a)), (1...120).contains(v) else { fail("--fps expects a number from 1 to 120") }
            o.settings.fps = v
        case "--quality":
            guard let v = Double(value(a)), (0...1).contains(v) else { fail("--quality expects a number from 0.0 to 1.0") }
            o.settings.quality = v
        case "--bitrate":
            guard let v = Double(value(a)), v > 0 else { fail("--bitrate expects megabits per second, e.g. 2.5") }
            o.settings.bitrateMbps = v
        case "--older-than":
            guard let v = Double(value(a)), v >= 0 else { fail("--older-than expects a number of days") }
            o.olderThanDays = v
        case "-n", "--dry-run":
            o.dryRun = true
        case "--overwrite":
            o.overwrite = true
        case "--respect-mutes":
            o.settings.respectMutes = true
        default:
            if a.hasPrefix("-") { fail("unknown option \(a) (see --help)") }
            o.inputs.append((a as NSString).expandingTildeInPath)
        }
    }
    if o.inputs.isEmpty {
        print(usage)
        exit(2)
    }
    return o
}
