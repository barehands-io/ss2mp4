import AppKit
import Foundation

enum ExportStatus: Equatable {
    case idle
    case queued
    case exporting
    case done(bytes: Int64)
    case failed(String)
}

struct ProjectRow: Identifiable {
    let project: Project
    var bytes: Int64?          // size on disk; nil until measured
    var exported: Bool         // an export already exists in the output folder
    var status: ExportStatus = .idle
    var id: URL { project.url }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest First"
    case oldest = "Oldest First"
    case largest = "Largest First"
    case longest = "Longest First"
    case name = "Name"

    var id: Self { self }
}

/// Progress of one press of the Export button.
struct ExportRun {
    let total: Int
    let totalSeconds: Double
    let started = Date()
    var index = 0
    var currentName = ""
    var currentSeconds = 0.0
    var fraction = 0.0
    var finishedSeconds = 0.0
    var exported = 0
    var failed = 0
    var skipped = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var finishedAt: Date?
    var cancelled = false

    var finished: Bool { finishedAt != nil }
    /// Recording time encoded so far across the whole run.
    var doneSeconds: Double { finishedSeconds + fraction * currentSeconds }
    var overallFraction: Double { totalSeconds > 0 ? min(1, doneSeconds / totalSeconds) : 0 }
    /// Seconds of recording encoded per second of wall-clock time.
    var speed: Double {
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(started)
        return elapsed > 0 ? doneSeconds / elapsed : 0
    }
    var remainingSeconds: Double? {
        guard speed > 0, Date().timeIntervalSince(started) > 3 else { return nil }
        return max(0, totalSeconds - doneSeconds) / speed
    }
}

/// Receives progress on the encoder's queue for every frame and forwards it to the main actor about five times a second.
final class ProgressReporter: @unchecked Sendable {
    private let handler: @MainActor (Double) -> Void
    private var lastReport = Date.distantPast

    init(_ handler: @escaping @MainActor (Double) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.2 else { return }
        lastReport = now
        let handler = handler
        Task { @MainActor in handler(fraction) }
    }
}

@MainActor
final class ExportModel: ObservableObject {
    @Published var sourceFolder: URL {
        didSet {
            UserDefaults.standard.set(sourceFolder.path, forKey: Keys.sourceFolder)
            reload()
        }
    }
    @Published var outputFolder: URL {
        didSet {
            UserDefaults.standard.set(outputFolder.path, forKey: Keys.outputFolder)
            // Results from an earlier run refer to the old folder.
            if !isExporting {
                run = nil
                rows = rows.map { row in
                    var row = row
                    row.status = .idle
                    return row
                }
            }
            refreshExported()
        }
    }
    @Published var settings: ExportSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Keys.settings)
            }
        }
    }
    @Published var replaceExisting = false
    @Published var search = ""
    @Published var sortOrder: SortOrder = .newest
    @Published var checked: Set<URL> = []
    @Published var errorMessage: String?

    @Published private(set) var rows: [ProjectRow] = []
    @Published private(set) var skipped: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var folderMissing = false
    @Published private(set) var run: ExportRun?

    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var currentPartial: URL?

    private enum Keys {
        static let sourceFolder = "sourceFolder"
        static let outputFolder = "outputFolder"
        static let settings = "exportSettings"
    }

    init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        sourceFolder = defaults.string(forKey: Keys.sourceFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Screen Studio Projects", isDirectory: true)
        outputFolder = defaults.string(forKey: Keys.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Movies/Screen Studio Exports", isDirectory: true)
        settings = defaults.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) }
            ?? ExportSettings()
        reload()
    }

    var isExporting: Bool { run.map { !$0.finished } ?? false }

    // MARK: Library

    func reload() {
        guard !isExporting else { return }
        loadTask?.cancel()
        let folder = sourceFolder
        var isDir: ObjCBool = false
        folderMissing = !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
        guard !folderMissing else {
            rows = []
            skipped = []
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task {
            let (projects, skipped) = await Task.detached(priority: .userInitiated) { () -> ([Project], [String]) in
                var projects: [Project] = []
                var skipped: [String] = []
                for url in discoverProjects([folder.path]) {
                    do {
                        projects.append(try loadProject(url))
                    } catch {
                        skipped.append("\(url.deletingPathExtension().lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                return (projects, skipped)
            }.value
            guard !Task.isCancelled else { return }
            let output = outputFolder
            let knownBytes = Dictionary(rows.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first })
            rows = projects.map { p in
                ProjectRow(project: p, bytes: knownBytes[p.url] ?? nil,
                           exported: FileManager.default.fileExists(atPath: exportURLs(p, in: output).final.path))
            }
            self.skipped = skipped
            checked.formIntersection(rows.map(\.id))
            isLoading = false
            await measureSizes()
        }
    }

    /// Measures project sizes in the background, publishing a batch at a time so the list stays responsive.
    private func measureSizes() async {
        let urls = rows.map(\.id)
        var start = 0
        while start < urls.count {
            let batch = Array(urls[start..<min(start + 16, urls.count)])
            start += batch.count
            let sizes = await Task.detached(priority: .utility) { batch.map { ($0, allocatedSize($0)) } }.value
            guard !Task.isCancelled else { return }
            let lookup = Dictionary(sizes, uniquingKeysWith: { first, _ in first })
            rows = rows.map { row in
                var row = row
                if let bytes = lookup[row.id] { row.bytes = bytes }
                return row
            }
        }
    }

    func refreshExported() {
        let fm = FileManager.default
        let output = outputFolder
        rows = rows.map { row in
            var row = row
            row.exported = fm.fileExists(atPath: exportURLs(row.project, in: output).final.path)
            return row
        }
    }

    var visibleRows: [ProjectRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return sorted(query.isEmpty ? rows : rows.filter { $0.project.name.localizedCaseInsensitiveContains(query) })
    }

    private func sorted(_ list: [ProjectRow]) -> [ProjectRow] {
        switch sortOrder {
        case .newest: return list.sorted { $0.project.recordedAt > $1.project.recordedAt }
        case .oldest: return list.sorted { $0.project.recordedAt < $1.project.recordedAt }
        case .largest: return list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        case .longest: return list.sorted { $0.project.durationHint > $1.project.durationHint }
        case .name: return list.sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
        }
    }

    var librarySummary: String {
        guard !rows.isEmpty else { return isLoading ? "" : "No projects" }
        let sizes = rows.compactMap(\.bytes)
        let size = sizes.count == rows.count ? formatBytes(sizes.reduce(0, +)) : "measuring…"
        let seconds = rows.reduce(0) { $0 + $1.project.durationHint }
        return "\(rows.count) project\(rows.count == 1 ? "" : "s") · \(size) · \(formatDuration(seconds))"
    }

    // MARK: Selection

    var checkedRows: [ProjectRow] { rows.filter { checked.contains($0.id) } }

    /// Ticked projects that will be exported. Existing exports are kept unless "Replace existing exports" is on.
    var queue: [Project] {
        sorted(rows).filter { checked.contains($0.id) && (replaceExisting || !$0.exported) }.map(\.project)
    }

    var skippedExistingCount: Int { replaceExisting ? 0 : checkedRows.filter(\.exported).count }

    var selectionSummary: String {
        let list = checkedRows
        guard !list.isEmpty else { return "None selected" }
        let bytes = list.compactMap(\.bytes).reduce(0, +)
        let seconds = list.reduce(0) { $0 + $1.project.durationHint }
        return "\(list.count) selected · \(formatBytes(bytes)) · \(formatDuration(seconds))"
    }

    func selectAll() { checked.formUnion(visibleRows.map(\.id)) }

    func selectNone() { checked.removeAll() }

    func selectNotExported() { checked = Set(visibleRows.filter { !$0.exported }.map(\.id)) }

    func selectOlder(than days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        checked = Set(visibleRows.filter { $0.project.recordedAt < cutoff }.map(\.id))
    }

    // MARK: Exporting

    func startExport() {
        guard !isExporting else { return }
        let queue = self.queue
        guard !queue.isEmpty else { return }
        let output = outputFolder
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the folder \(output.path): \(error.localizedDescription)"
            return
        }
        let queued = Set(queue.map(\.url))
        rows = rows.map { row in
            var row = row
            row.status = queued.contains(row.id) ? .queued : .idle
            return row
        }
        run = ExportRun(total: queue.count, totalSeconds: queue.reduce(0) { $0 + $1.durationHint })
        let settings = self.settings
        let replace = replaceExisting
        exportTask = Task { await self.runExport(queue, to: output, settings: settings, replace: replace) }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissRun() {
        guard !isExporting else { return }
        run = nil
    }

    /// Called when the app quits: stop the export and remove its unfinished file straight away.
    func stopForQuit() {
        exportTask?.cancel()
        if let partial = currentPartial { removePartial(partial) }
    }

    private func runExport(_ queue: [Project], to output: URL, settings: ExportSettings, replace: Bool) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Exporting Screen Studio projects")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        for (i, p) in queue.enumerated() {
            if Task.isCancelled { break }
            run?.index = i
            run?.currentName = p.name
            run?.currentSeconds = p.durationHint
            run?.fraction = 0
            // Checked again here: the file may have appeared since the list was refreshed, for example
            // from an earlier project in this run whose name maps to the same file name.
            if !replace && FileManager.default.fileExists(atPath: exportURLs(p, in: output).final.path) {
                if let index = rows.firstIndex(where: { $0.id == p.url }) {
                    rows[index].exported = true
                    rows[index].status = .idle
                }
                run?.skipped += 1
                run?.finishedSeconds += p.durationHint
                continue
            }
            setStatus(.exporting, for: p.url)
            NSApp.dockTile.badgeLabel = "\(i + 1)/\(queue.count)"
            currentPartial = exportURLs(p, in: output).partial

            let reporter = ProgressReporter { [weak self] fraction in self?.progressed(fraction, index: i) }
            do {
                let result = try await exportProject(p, to: output, settings: settings, replaceExisting: replace,
                                                     progress: reporter.report)
                currentPartial = nil
                let bytesIn: Int64
                if let known = rows.first(where: { $0.id == p.url })?.bytes {
                    bytesIn = known
                } else {
                    bytesIn = await Task.detached(priority: .utility) { allocatedSize(p.url) }.value
                }
                run?.exported += 1
                run?.bytesIn += bytesIn
                run?.bytesOut += result.bytes
                setStatus(.done(bytes: result.bytes), for: p.url)
                if let index = rows.firstIndex(where: { $0.id == p.url }) { rows[index].exported = true }
            } catch {
                currentPartial = nil
                if Task.isCancelled || error is CancellationError {
                    setStatus(.idle, for: p.url)
                    break
                }
                run?.failed += 1
                setStatus(.failed(describe(error)), for: p.url)
            }
            run?.finishedSeconds += p.durationHint
            run?.fraction = 0
        }

        rows = rows.map { row in
            var row = row
            if row.status == .queued { row.status = .idle }
            return row
        }
        run?.cancelled = Task.isCancelled
        run?.finishedAt = Date()
        exportTask = nil
        NSApp.dockTile.badgeLabel = nil
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func progressed(_ fraction: Double, index: Int) {
        guard var current = run, !current.finished, current.index == index else { return }
        current.fraction = max(current.fraction, min(fraction, 1))
        run = current
    }

    private func setStatus(_ status: ExportStatus, for url: URL) {
        if let i = rows.firstIndex(where: { $0.id == url }) { rows[i].status = status }
    }

    // MARK: Folders and Finder

    func chooseSourceFolder() {
        if let url = pickFolder(message: "Choose the folder that contains your Screen Studio projects.", startingAt: sourceFolder) {
            sourceFolder = url
        }
    }

    func chooseOutputFolder() {
        if let url = pickFolder(message: "Choose where the exported MP4 files are saved.", startingAt: outputFolder) {
            outputFolder = url
        }
    }

    private func pickFolder(message: String, startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = url
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func exportURL(for row: ProjectRow) -> URL { exportURLs(row.project, in: outputFolder).final }

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func showOutputFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputFolder)
    }
}
