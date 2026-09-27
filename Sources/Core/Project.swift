import Foundation

// MARK: - Project model

struct Session {
    var display: URL
    var microphone: URL?
    var systemAudio: URL?
}

struct Project {
    let url: URL
    let name: String
    let recordedAt: Date
    let sessions: [Session]
    let durationHint: Double
    // Mute switches from the Screen Studio editor; applied only when ExportSettings.respectMutes is set.
    let microphoneMuted: Bool
    let systemAudioMuted: Bool
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

func loadProject(_ url: URL) throws -> Project {
    let rec = url.appendingPathComponent("recording", isDirectory: true)
    guard let data = try? Data(contentsOf: rec.appendingPathComponent("metadata.json")),
          let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let recorders = meta["recorders"] as? [[String: Any]]
    else { throw ConvertError.noRecording }

    var config: [String: Any] = [:]
    if let d = try? Data(contentsOf: url.appendingPathComponent("project.json")),
       let pj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let root = (pj["json"] as? [String: Any]) ?? pj
        config = root["config"] as? [String: Any] ?? [:]
    }

    func sessions(of type: String) -> [[String: Any]] {
        recorders.first { $0["type"] as? String == type }?["sessions"] as? [[String: Any]] ?? []
    }
    func file(_ list: [[String: Any]], _ i: Int) -> URL? {
        guard i < list.count, let name = list[i]["outputFilename"] as? String else { return nil }
        return rec.appendingPathComponent(name)
    }

    let fm = FileManager.default
    func existingFile(_ list: [[String: Any]], _ i: Int) -> URL? {
        file(list, i).flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
    }

    let displays = sessions(of: "display")
    guard !displays.isEmpty else { throw ConvertError.noRecording }
    let mics = sessions(of: "microphone")
    let systems = sessions(of: "systemAudio")

    var result: [Session] = []
    // Sessions are sequential segments (recording paused and resumed), played back to back.
    for i in displays.indices {
        guard let display = file(displays, i), fm.fileExists(atPath: display.path) else {
            throw ConvertError.missingFile(displays[i]["outputFilename"] as? String ?? "display recording \(i)")
        }
        // The raw mic is used on purpose: recording/enhanced/*-enhanced.m4a files are often near-silent placeholders.
        result.append(Session(display: display, microphone: existingFile(mics, i), systemAudio: existingFile(systems, i)))
    }

    let recordedAt = (displays.first?["unixStartMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let duration = displays.reduce(0.0) { $0 + (($1["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000 }
    return Project(url: url, name: url.deletingPathExtension().lastPathComponent, recordedAt: recordedAt,
                   sessions: result, durationHint: duration,
                   microphoneMuted: config["muteMicrophone"] as? Bool ?? false,
                   systemAudioMuted: config["muteSystemAudio"] as? Bool ?? false)
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
    // Resolve a symlinked project folder so its contents are measured rather than the link itself.
    let url = url.resolvingSymlinksInPath()
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

