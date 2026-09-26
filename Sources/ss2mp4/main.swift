// ss2mp4 — convert Screen Studio projects into compact HEVC MP4 files.
// Output contains the screen recording plus mixed microphone and system audio.
// Original projects are never modified; files are written to a separate folder.

import AVFoundation
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
    var maxHeight = 1440
    var fps = 30
    var quality = 0.5
    var bitrateMbps: Double?
    var olderThanDays: Double?
    var respectMutes = false
    var dryRun = false
    var overwrite = false
}

func printErr(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
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
            o.maxHeight = v
        case "--fps":
            guard let v = Int(value(a)), (1...120).contains(v) else { fail("--fps expects a number from 1 to 120") }
            o.fps = v
        case "--quality":
            guard let v = Double(value(a)), (0...1).contains(v) else { fail("--quality expects a number from 0.0 to 1.0") }
            o.quality = v
        case "--bitrate":
            guard let v = Double(value(a)), v > 0 else { fail("--bitrate expects megabits per second, e.g. 2.5") }
            o.bitrateMbps = v
        case "--older-than":
            guard let v = Double(value(a)), v >= 0 else { fail("--older-than expects a number of days") }
            o.olderThanDays = v
        case "-n", "--dry-run":
            o.dryRun = true
        case "--overwrite":
            o.overwrite = true
        case "--respect-mutes":
            o.respectMutes = true
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

// MARK: - Project model

struct Session {
    var display: URL
    var audio: [URL]
}

struct Project {
    let url: URL
    let name: String
    let recordedAt: Date
    let sessions: [Session]
    let durationHint: Double
}

enum ConvertError: LocalizedError {
    case noRecording
    case missingFile(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: return "no recording found (empty or leftover project folder)"
        case .missingFile(let f): return "missing \(f)"
        case .failed(let m): return m
        }
    }
}

func loadProject(_ url: URL, respectMutes: Bool) throws -> Project {
    let rec = url.appendingPathComponent("recording", isDirectory: true)
    guard let data = try? Data(contentsOf: rec.appendingPathComponent("metadata.json")),
          let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let recorders = meta["recorders"] as? [[String: Any]]
    else { throw ConvertError.noRecording }

    var config: [String: Any] = [:]
    if respectMutes, let d = try? Data(contentsOf: url.appendingPathComponent("project.json")),
       let pj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let root = (pj["json"] as? [String: Any]) ?? pj
        config = root["config"] as? [String: Any] ?? [:]
    }
    let muteMic = config["muteMicrophone"] as? Bool ?? false
    let muteSystem = config["muteSystemAudio"] as? Bool ?? false

    func sessions(of type: String) -> [[String: Any]] {
        recorders.first { $0["type"] as? String == type }?["sessions"] as? [[String: Any]] ?? []
    }
    func file(_ list: [[String: Any]], _ i: Int) -> URL? {
        guard i < list.count, let name = list[i]["outputFilename"] as? String else { return nil }
        return rec.appendingPathComponent(name)
    }

    let displays = sessions(of: "display")
    guard !displays.isEmpty else { throw ConvertError.noRecording }
    let mics = muteMic ? [] : sessions(of: "microphone")
    let systems = muteSystem ? [] : sessions(of: "systemAudio")

    let fm = FileManager.default
    var result: [Session] = []
    // Sessions are sequential segments (recording paused and resumed), played back to back.
    for i in displays.indices {
        guard let display = file(displays, i), fm.fileExists(atPath: display.path) else {
            throw ConvertError.missingFile(displays[i]["outputFilename"] as? String ?? "display recording \(i)")
        }
        var audio: [URL] = []
        // The raw mic is used on purpose: recording/enhanced/*-enhanced.m4a files are often near-silent placeholders.
        if let mic = file(mics, i), fm.fileExists(atPath: mic.path) { audio.append(mic) }
        if let system = file(systems, i), fm.fileExists(atPath: system.path) { audio.append(system) }
        result.append(Session(display: display, audio: audio))
    }

    let recordedAt = (displays.first?["unixStartMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let duration = displays.reduce(0.0) { $0 + (($1["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000 }
    return Project(url: url, name: url.deletingPathExtension().lastPathComponent, recordedAt: recordedAt,
                   sessions: result, durationHint: duration)
}

func discoverProjects(_ inputs: [String]) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []
    for path in inputs {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            printErr("ss2mp4: not found: \(path)")
            continue
        }
        if url.pathExtension == "screenstudio" {
            result.append(url)
        } else {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            result += items.filter { $0.pathExtension == "screenstudio" }
        }
    }
    return result
}

func allocatedSize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
        return Int64(v.totalFileAllocatedSize ?? 0)
    }
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
    }
    return total
}

// MARK: - Composition

struct Plan {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let videoTrack: AVMutableCompositionTrack
    let audioTracks: [AVMutableCompositionTrack]
    let renderSize: CGSize
    let duration: CMTime
}

func step<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let e as ConvertError { throw e } catch {
        throw ConvertError.failed("\(label): " + describe(error))
    }
}

func makePlan(_ p: Project, _ opts: Options) async throws -> Plan {
    let comp = AVMutableComposition()
    guard let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw ConvertError.failed("could not create video track")
    }
    var audioTracks: [AVMutableCompositionTrack] = []
    var segments: [(start: CMTime, size: CGSize, transform: CGAffineTransform)] = []
    var cursor = CMTime.zero

    for s in p.sessions {
        let asset = AVURLAsset(url: s.display)
        guard let src = try await step("loading \(s.display.lastPathComponent)", { try await asset.loadTracks(withMediaType: .video).first }) else {
            throw ConvertError.missingFile("video track in \(s.display.lastPathComponent)")
        }
        let (range, size, transform) = try await step("reading video info") { try await src.load(.timeRange, .naturalSize, .preferredTransform) }
        try await step("adding video") { try videoTrack.insertTimeRange(range, of: src, at: cursor) }
        segments.append((cursor, size, transform))

        // Audio files share the session's time origin; keep their offset relative to the video and clip to it.
        for (slot, audioURL) in s.audio.enumerated() {
            let audioAsset = AVURLAsset(url: audioURL)
            guard let track = try await step("loading \(audioURL.lastPathComponent)", { try await audioAsset.loadTracks(withMediaType: .audio).first }) else { continue }
            let audioRange = try await step("reading audio info") { try await track.load(.timeRange) }
            let start = CMTimeMaximum(audioRange.start, range.start)
            let end = CMTimeMinimum(audioRange.end, range.end)
            guard end > start else { continue }
            while audioTracks.count <= slot {
                guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ConvertError.failed("could not create audio track")
                }
                audioTracks.append(t)
            }
            try await step("adding audio") { try audioTracks[slot].insertTimeRange(CMTimeRange(start: start, end: end), of: track, at: cursor + (start - range.start)) }
        }
        cursor = cursor + range.duration
    }

    let first = CGRect(origin: .zero, size: segments[0].size).applying(segments[0].transform)
    var width = abs(first.width), height = abs(first.height)
    if opts.maxHeight > 0 && height > CGFloat(opts.maxHeight) {
        width = width * CGFloat(opts.maxHeight) / height
        height = CGFloat(opts.maxHeight)
    }
    let renderSize = CGSize(width: max(2, (width / 2).rounded() * 2), height: max(2, (height / 2).rounded() * 2))

    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    for seg in segments {
        let oriented = CGRect(origin: .zero, size: seg.size).applying(seg.transform)
        let scale = min(renderSize.width / abs(oriented.width), renderSize.height / abs(oriented.height))
        let dx = (renderSize.width - abs(oriented.width) * scale) / 2
        let dy = (renderSize.height - abs(oriented.height) * scale) / 2
        let t = seg.transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        layer.setTransform(t, at: seg.start)
    }
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
    instruction.layerInstructions = [layer]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
    videoComposition.instructions = [instruction]
    videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    return Plan(composition: comp, videoComposition: videoComposition, videoTrack: videoTrack, audioTracks: audioTracks,
                renderSize: renderSize, duration: cursor)
}

// MARK: - Transcoding

func pump(_ output: AVAssetReaderOutput?, into input: AVAssetWriterInput?,
          onSample: ((CMSampleBuffer) -> Void)? = nil) async -> Bool {
    guard let output, let input else { return true }
    let queue = DispatchQueue(label: "ss2mp4.\(input.mediaType.rawValue)")
    return await withCheckedContinuation { cont in
        var done = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    done = true
                    input.markAsFinished()
                    cont.resume(returning: true)
                    return
                }
                onSample?(sample)
                if !input.append(sample) {
                    done = true
                    input.markAsFinished()
                    cont.resume(returning: false)
                    return
                }
            }
        }
    }
}

func metadataItem(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value as NSString
    item.extendedLanguageTag = "und"
    return item
}

func transcode(_ plan: Plan, to out: URL, title: String, date: Date, _ opts: Options,
               progress: @escaping (Double) -> Void) async throws {
    let reader = try await step("creating reader") { try AVAssetReader(asset: plan.composition) }
    let videoOut = AVAssetReaderVideoCompositionOutput(
        videoTracks: [plan.videoTrack],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    videoOut.videoComposition = plan.videoComposition
    videoOut.alwaysCopiesSampleData = false
    reader.add(videoOut)

    var audioOut: AVAssetReaderAudioMixOutput?
    if !plan.audioTracks.isEmpty {
        let o = AVAssetReaderAudioMixOutput(audioTracks: plan.audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        o.alwaysCopiesSampleData = false
        reader.add(o)
        audioOut = o
    }

    let writer = try await step("creating writer") { try AVAssetWriter(outputURL: out, fileType: .mp4) }
    writer.shouldOptimizeForNetworkUse = true
    writer.metadata = [
        metadataItem(.commonIdentifierTitle, title),
        metadataItem(.commonIdentifierCreationDate, ISO8601DateFormatter().string(from: date)),
    ]

    var compression: [String: Any] = [
        AVVideoExpectedSourceFrameRateKey: opts.fps,
        AVVideoMaxKeyFrameIntervalDurationKey: 10,
        AVVideoAllowFrameReorderingKey: true,
    ]
    if let mbps = opts.bitrateMbps {
        compression[AVVideoAverageBitRateKey] = Int(mbps * 1_000_000)
    } else {
        compression[AVVideoQualityKey] = opts.quality
    }
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(plan.renderSize.width),
        AVVideoHeightKey: Int(plan.renderSize.height),
        AVVideoCompressionPropertiesKey: compression,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    videoIn.expectsMediaDataInRealTime = false
    writer.add(videoIn)

    var audioIn: AVAssetWriterInput?
    if audioOut != nil {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        i.expectsMediaDataInRealTime = false
        writer.add(i)
        audioIn = i
    }

    guard reader.startReading() else {
        throw ConvertError.failed("could not start reading: " + describe(reader.error ?? ConvertError.failed("unknown")))
    }
    guard writer.startWriting() else {
        throw ConvertError.failed("could not start writing: " + describe(writer.error ?? ConvertError.failed("unknown")))
    }
    writer.startSession(atSourceTime: .zero)

    let total = max(plan.duration.seconds, 0.001)
    var videoSamples = 0
    async let videoOK = pump(videoOut, into: videoIn) {
        videoSamples += 1
        progress(CMSampleBufferGetPresentationTimeStamp($0).seconds / total)
    }
    async let audioOK = pump(audioOut, into: audioIn)
    let (v, a) = await (videoOK, audioOK)

    if reader.status == .failed {
        writer.cancelWriting()
        throw ConvertError.failed("reading failed: " + describe(reader.error ?? ConvertError.failed("unknown")))
    }
    if ProcessInfo.processInfo.environment["SS2MP4_DEBUG"] != nil {
        printErr("debug: video samples=\(videoSamples) reader=\(reader.status.rawValue) writer=\(writer.status.rawValue) v=\(v) a=\(a)")
    }
    if !v || !a {
        writer.cancelWriting()
        throw ConvertError.failed("writing \(v ? "audio" : "video") failed: " + describe(writer.error ?? ConvertError.failed("unknown")))
    }
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw ConvertError.failed("could not finish writing: " + describe(writer.error ?? ConvertError.failed("unknown")))
    }
}

func verify(_ url: URL, expected: CMTime, hasAudio: Bool) async throws {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let tolerance = max(2, expected.seconds * 0.01)
    guard !video.isEmpty, !hasAudio || !audio.isEmpty, abs(duration - expected.seconds) <= tolerance else {
        throw ConvertError.failed(String(format: "verification failed (output %.1fs, expected %.1fs)", duration, expected.seconds))
    }
}

// MARK: - Formatting

func describe(_ error: Error) -> String {
    if error is ConvertError { return error.localizedDescription }
    let ns = error as NSError
    var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    if let reason = ns.localizedFailureReason { text += " \(reason)" }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { text += " ← " + describe(underlying) }
    return text
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    if t >= 3600 { return "\(t / 3600)h \(String(format: "%02d", t % 3600 / 60))m" }
    if t >= 60 { return "\(t / 60)m \(String(format: "%02d", t % 60))s" }
    return "\(t)s"
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

final class ProgressLine {
    let label: String
    let isTTY = isatty(STDOUT_FILENO) != 0
    let started = Date()
    let mediaSeconds: Double
    var lastPrint = Date.distantPast
    var lastBucket = -1

    init(label: String, mediaSeconds: Double) {
        self.label = label
        self.mediaSeconds = mediaSeconds
    }

    func update(_ fraction: Double) {
        let f = min(max(fraction, 0), 1)
        let elapsed = Date().timeIntervalSince(started)
        let speed = elapsed > 0 ? f * mediaSeconds / elapsed : 0
        let eta = f > 0.01 ? elapsed * (1 - f) / f : 0
        if isTTY {
            guard Date().timeIntervalSince(lastPrint) > 0.25 else { return }
            lastPrint = Date()
            let filled = Int(f * 24)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 24 - filled)
            print(String(format: "\r  %@ %3.0f%%  %4.1fx  ETA %@   ", bar, f * 100, speed, formatDuration(eta)), terminator: "")
            fflush(stdout)
        } else {
            let bucket = Int(f * 10)
            guard bucket > lastBucket else { return }
            lastBucket = bucket
            print(String(format: "  %3.0f%%  %4.1fx", f * 100, speed))
        }
    }

    func clear() {
        if isTTY {
            print("\r" + String(repeating: " ", count: 60) + "\r", terminator: "")
            fflush(stdout)
        }
    }
}

// MARK: - Main

var currentPartial: URL?

// AVAssetWriter also creates hidden "<name>.sb-*" temp files next to the output while finalizing.
func removePartial(_ url: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: url)
    let dir = url.deletingLastPathComponent()
    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(url.lastPathComponent + ".sb-") {
        try? fm.removeItem(at: dir.appendingPathComponent(f))
    }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler {
    if let p = currentPartial { removePartial(p) }
    print("\nInterrupted. Removed the unfinished file; finished exports are kept.")
    exit(130)
}
interrupt.resume()

let opts = parseOptions()
let fm = FileManager.default

var projects: [Project] = []
var skipped: [(String, String)] = []
for url in discoverProjects(opts.inputs) {
    do {
        projects.append(try loadProject(url, respectMutes: opts.respectMutes))
    } catch {
        skipped.append((url.deletingPathExtension().lastPathComponent, error.localizedDescription))
    }
}
if let days = opts.olderThanDays {
    let cutoff = Date().addingTimeInterval(-days * 86_400)
    projects = projects.filter { $0.recordedAt < cutoff }
}
projects.sort { $0.recordedAt < $1.recordedAt }

func outputName(_ p: Project) -> String {
    p.name.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-") + ".mp4"
}

if opts.dryRun {
    var totalBytes: Int64 = 0, totalSeconds = 0.0
    print("  Recorded          Length   Project   Name")
    for p in projects {
        let size = allocatedSize(p.url)
        totalBytes += size
        totalSeconds += p.durationHint
        let exists = fm.fileExists(atPath: opts.outputDir.appendingPathComponent(outputName(p)).path)
        let sizeStr = formatBytes(size).padding(toLength: 9, withPad: " ", startingAt: 0)
        let lenStr = formatDuration(p.durationHint).padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(dateFormatter.string(from: p.recordedAt))  \(lenStr) \(sizeStr) \(p.name)\(exists && !opts.overwrite ? "  (already converted)" : "")")
    }
    for (name, reason) in skipped { print("  skip: \(name) — \(reason)") }
    print("\nWould convert \(projects.count) project(s): \(formatDuration(totalSeconds)) of recordings, \(formatBytes(totalBytes)) on disk")
    print("Output folder: \(opts.outputDir.path)")
    exit(0)
}

do {
    try fm.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)
} catch {
    fail("cannot create output folder \(opts.outputDir.path): \(error.localizedDescription)")
}

var converted = 0, failed = 0, alreadyDone = 0
var bytesBefore: Int64 = 0, bytesAfter: Int64 = 0
let runStarted = Date()

for (index, p) in projects.enumerated() {
    let name = outputName(p)
    let finalURL = opts.outputDir.appendingPathComponent(name)
    let partialURL = opts.outputDir.appendingPathComponent(".\(name).partial.mp4")
    let header = "[\(index + 1)/\(projects.count)] \(p.name)"

    if fm.fileExists(atPath: finalURL.path) && !opts.overwrite {
        print("\(header) — already converted, skipping")
        alreadyDone += 1
        continue
    }

    let projectBytes = allocatedSize(p.url)
    print("\(header)  (\(formatDuration(p.durationHint)), \(formatBytes(projectBytes)))")
    removePartial(partialURL)
    currentPartial = partialURL
    let started = Date()
    let line = ProgressLine(label: p.name, mediaSeconds: p.durationHint)

    do {
        let plan = try await makePlan(p, opts)
        try await transcode(plan, to: partialURL, title: p.name, date: p.recordedAt, opts) { line.update($0) }
        line.clear()
        try await step("verifying output") { try await verify(partialURL, expected: plan.duration, hasAudio: !plan.audioTracks.isEmpty) }
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: partialURL, to: finalURL)
        try? fm.setAttributes([.creationDate: p.recordedAt, .modificationDate: p.recordedAt], ofItemAtPath: finalURL.path)

        let outBytes = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        bytesBefore += projectBytes
        bytesAfter += outBytes
        converted += 1
        let saved = projectBytes > 0 ? 100 * (1 - Double(outBytes) / Double(projectBytes)) : 0
        print(String(format: "  ✓ %@ → %@ (%.0f%% smaller, %dx%d) in %@",
                     formatBytes(projectBytes), formatBytes(outBytes), saved,
                     Int(plan.renderSize.width), Int(plan.renderSize.height),
                     formatDuration(Date().timeIntervalSince(started))))
    } catch {
        line.clear()
        removePartial(partialURL)
        failed += 1
        print("  ✗ failed: \(describe(error))")
    }
    currentPartial = nil
}

for (name, reason) in skipped { print("skipped: \(name) — \(reason)") }
print("\nDone in \(formatDuration(Date().timeIntervalSince(runStarted))): \(converted) converted, \(alreadyDone) already done, \(failed) failed, \(skipped.count) skipped.")
if converted > 0 {
    print("Projects \(formatBytes(bytesBefore)) → exports \(formatBytes(bytesAfter)) in \(opts.outputDir.path)")
    print("Originals were not modified. Delete projects yourself once you've checked the exports.")
}
exit(failed > 0 ? 1 : 0)
