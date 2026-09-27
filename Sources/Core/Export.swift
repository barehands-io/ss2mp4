import Foundation

// MARK: - Export

/// Encoding and audio choices shared by the command-line tool and the app.
struct ExportSettings: Codable, Equatable {
    var maxHeight = 1440
    var fps = 30
    var quality = 0.5
    var bitrateMbps: Double?
    var includeMicrophone = true
    var includeSystemAudio = true
    var respectMutes = false

    /// Audio files to mix for one session, always in the same order (microphone, then system audio).
    func audio(for session: Session, in project: Project) -> [URL] {
        var files: [URL] = []
        if includeMicrophone, !(respectMutes && project.microphoneMuted), let mic = session.microphone {
            files.append(mic)
        }
        if includeSystemAudio, !(respectMutes && project.systemAudioMuted), let system = session.systemAudio {
            files.append(system)
        }
        return files
    }
}

struct ExportResult {
    let url: URL
    let bytes: Int64
    let renderSize: CGSize
}

func outputName(_ p: Project) -> String {
    p.name.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-") + ".mp4"
}

/// The finished export's location, and the hidden file it is written to until it has been verified.
func exportURLs(_ p: Project, in dir: URL) -> (final: URL, partial: URL) {
    let name = outputName(p)
    return (dir.appendingPathComponent(name), dir.appendingPathComponent(".\(name).partial.mp4"))
}

// AVAssetWriter also creates hidden "<name>.sb-*" temp files next to the output while finalizing.
func removePartial(_ url: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: url)
    let dir = url.deletingLastPathComponent()
    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(url.lastPathComponent + ".sb-") {
        try? fm.removeItem(at: dir.appendingPathComponent(f))
    }
}

/// Set when the export task is cancelled; checked by the reader/writer pumps on their own queues.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Runs `handler` on cancellation, or straight away if already cancelled.
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = handlers
        handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }
}

/// Converts one project into `dir`. The MP4 is written under a hidden temporary name, verified, then renamed
/// into place and given the recording date. An existing export is replaced only if `replaceExisting` is set.
/// Cancelling the calling task stops the export and removes the unfinished file. The project is only read.
func exportProject(_ p: Project, to dir: URL, settings: ExportSettings, replaceExisting: Bool,
                   progress: @escaping (Double) -> Void) async throws -> ExportResult {
    let fm = FileManager.default
    // Compared case-insensitively, as most Mac volumes are.
    let projectPath = p.url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    let outputPath = dir.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    guard outputPath != projectPath && !outputPath.hasPrefix(projectPath + "/") else {
        throw ConvertError.failed("the output folder is inside the project; choose a folder outside it")
    }
    let (finalURL, partialURL) = exportURLs(p, in: dir)
    if !replaceExisting && fm.fileExists(atPath: finalURL.path) {
        throw ConvertError.failed("\(finalURL.lastPathComponent) already exists")
    }
    removePartial(partialURL)
    let cancel = CancelFlag()
    do {
        return try await withTaskCancellationHandler {
            let plan = try await makePlan(p, settings)
            try Task.checkCancellation()
            try await transcode(plan, to: partialURL, title: p.name, date: p.recordedAt, settings,
                                cancel: cancel, progress: progress)
            try Task.checkCancellation()
            try await step("verifying output") {
                try await verify(partialURL, expected: plan.duration, hasAudio: !plan.audioTracks.isEmpty)
            }
            try Task.checkCancellation()
            if replaceExisting, let type = try? fm.attributesOfItem(atPath: finalURL.path)[.type] as? FileAttributeType {
                guard type != .typeDirectory else {
                    throw ConvertError.failed("\(finalURL.lastPathComponent) is a folder, not an earlier export")
                }
                try fm.removeItem(at: finalURL)
            }
            // Fails rather than overwrites if a file appeared at the destination in the meantime.
            try fm.moveItem(at: partialURL, to: finalURL)
            try? fm.setAttributes([.creationDate: p.recordedAt, .modificationDate: p.recordedAt], ofItemAtPath: finalURL.path)
            let bytes = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return ExportResult(url: finalURL, bytes: bytes, renderSize: plan.renderSize)
        } onCancel: {
            cancel.cancel()
        }
    } catch {
        removePartial(partialURL)
        throw error
    }
}
