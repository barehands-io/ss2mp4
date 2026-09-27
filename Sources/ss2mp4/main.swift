import Darwin
import Dispatch
import Foundation

// MARK: - Main

var currentPartial: URL?

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
        projects.append(try loadProject(url))
    } catch {
        skipped.append((url.deletingPathExtension().lastPathComponent, error.localizedDescription))
    }
}
if let days = opts.olderThanDays {
    let cutoff = Date().addingTimeInterval(-days * 86_400)
    projects = projects.filter { $0.recordedAt < cutoff }
}
projects.sort { $0.recordedAt < $1.recordedAt }

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
    let (finalURL, partialURL) = exportURLs(p, in: opts.outputDir)
    let header = "[\(index + 1)/\(projects.count)] \(p.name)"

    if fm.fileExists(atPath: finalURL.path) && !opts.overwrite {
        print("\(header) — already converted, skipping")
        alreadyDone += 1
        continue
    }

    let projectBytes = allocatedSize(p.url)
    print("\(header)  (\(formatDuration(p.durationHint)), \(formatBytes(projectBytes)))")
    currentPartial = partialURL
    let started = Date()
    let line = ProgressLine(label: p.name, mediaSeconds: p.durationHint)

    do {
        let result = try await exportProject(p, to: opts.outputDir, settings: opts.settings,
                                             replaceExisting: opts.overwrite) { line.update($0) }
        line.clear()
        bytesBefore += projectBytes
        bytesAfter += result.bytes
        converted += 1
        let saved = projectBytes > 0 ? 100 * (1 - Double(result.bytes) / Double(projectBytes)) : 0
        print(String(format: "  ✓ %@ → %@ (%.0f%% smaller, %dx%d) in %@",
                     formatBytes(projectBytes), formatBytes(result.bytes), saved,
                     Int(result.renderSize.width), Int(result.renderSize.height),
                     formatDuration(Date().timeIntervalSince(started))))
    } catch {
        line.clear()
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
