import AppKit
import SwiftUI

func abbreviate(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

struct ContentView: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        HStack(spacing: 0) {
            ProjectList()
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        SourceBar()
                        Divider()
                    }
                    .background(.bar)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        SelectionBar()
                    }
                    .background(.bar)
                }
                .frame(minWidth: 580, maxWidth: .infinity)
            Divider()
            OptionsPanel()
                .frame(width: 310)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.run != nil {
                RunBar()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort projects")
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Look for new projects")
                .disabled(model.isExporting || model.isLoading)
            }
        }
        .alert("Can't Export", isPresented: Binding(get: { model.errorMessage != nil },
                                                   set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Project list

private struct SourceBar: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(abbreviate(model.sourceFolder))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.sourceFolder.path)
            Button("Change…") { model.chooseSourceFolder() }
                .controlSize(.small)
                .disabled(model.isExporting)
            Spacer(minLength: 12)
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(model.librarySummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !model.skipped.isEmpty {
                Text("· \(model.skipped.count) skipped")
                    .foregroundStyle(.secondary)
                    .help(model.skipped.joined(separator: "\n"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ProjectList: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        let rows = model.visibleRows
        List {
            ForEach(rows) { row in
                ProjectRowView(row: row,
                               isChecked: checkedBinding(row.id),
                               fraction: row.status == .exporting ? model.run?.fraction : nil,
                               locked: model.isExporting)
                    .contextMenu { RowMenu(row: row, model: model) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { emptyState(visibleCount: rows.count) }
    }

    private func checkedBinding(_ id: URL) -> Binding<Bool> {
        Binding(get: { model.checked.contains(id) },
                set: { isOn in
                    if isOn { model.checked.insert(id) } else { model.checked.remove(id) }
                })
    }

    @ViewBuilder
    private func emptyState(visibleCount: Int) -> some View {
        if model.folderMissing {
            EmptyState(symbol: "folder.badge.questionmark", title: "Folder Not Found",
                       message: "\(abbreviate(model.sourceFolder)) doesn't exist.") {
                Button("Choose Folder…") { model.chooseSourceFolder() }
            }
        } else if model.isLoading && model.rows.isEmpty {
            ProgressView("Looking for projects…")
        } else if model.rows.isEmpty {
            EmptyState(symbol: "film.stack", title: "No Screen Studio Projects",
                       message: "There are no .screenstudio projects in \(abbreviate(model.sourceFolder)).") {
                Button("Choose Folder…") { model.chooseSourceFolder() }
            }
        } else if visibleCount == 0 {
            EmptyState(symbol: "magnifyingglass", title: "No Results",
                       message: "No projects match “\(model.search)”.") { EmptyView() }
        }
    }
}

private struct ProjectRowView: View {
    let row: ProjectRow
    @Binding var isChecked: Bool
    let fraction: Double?
    let locked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Include \(row.project.name)", isOn: $isChecked)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(locked)
            HStack(spacing: 12) {
                ThumbnailView(project: row.project)
                    .frame(width: 96, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.project.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(formatDuration(row.project.durationHint))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Text(row.bytes.map(formatBytes) ?? "–")
                    .frame(width: 72, alignment: .trailing)
                StatusView(row: row, fraction: fraction)
                    .frame(width: 104, alignment: .trailing)
            }
            .monospacedDigit()
            .contentShape(Rectangle())
            .onTapGesture {
                if !locked { isChecked.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = [row.project.recordedAt.formatted(date: .abbreviated, time: .shortened)]
        if row.project.sessions.count > 1 { parts.append("\(row.project.sessions.count) parts") }
        return parts.joined(separator: " · ")
    }
}

private struct StatusView: View {
    let row: ProjectRow
    let fraction: Double?

    var body: some View {
        switch row.status {
        case .exporting:
            ProgressView(value: fraction ?? 0)
                .frame(width: 90)
        case .queued:
            Text("Waiting")
                .foregroundStyle(.secondary)
        case .done(let bytes):
            Label(formatBytes(bytes), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        case .idle:
            if row.exported {
                Label("Exported", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                // Keeps the column's width; SwiftUI drops frames applied to empty views.
                Color.clear
            }
        }
    }
}

private struct RowMenu: View {
    let row: ProjectRow
    let model: ExportModel

    var body: some View {
        if row.exported {
            Button("Open Export") { model.open(model.exportURL(for: row)) }
            Button("Show Export in Finder") { model.showInFinder(model.exportURL(for: row)) }
            Divider()
        }
        Button("Show Project in Finder") { model.showInFinder(row.project.url) }
        if case .failed(let message) = row.status {
            Divider()
            Button("Copy Error Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }
}

private struct SelectionBar: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Select:")
                .foregroundStyle(.secondary)
            Button("All") { model.selectAll() }
            Button("None") { model.selectNone() }
            Button("Not Exported") { model.selectNotExported() }
            Menu("Older Than") {
                ForEach([7, 30, 90, 180, 365], id: \.self) { days in
                    Button("\(days) Days") { model.selectOlder(than: days) }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 12)
            Text(model.selectionSummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.link)
        .font(.callout)
        .disabled(model.isExporting || model.rows.isEmpty)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions
                .padding(.top, 4)
        }
        .padding(40)
    }
}

// MARK: - Options

private struct OptionsPanel: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $model.settings.maxHeight) {
                        Text("Original").tag(0)
                        Text("2160p").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    }
                    Picker("Frame rate", selection: $model.settings.fps) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text(model.settings.quality, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.quality, in: 0.2...0.9, step: 0.05) {
                            Text("Quality")
                        } minimumValueLabel: {
                            Text("Smaller").font(.caption)
                        } maximumValueLabel: {
                            Text("Sharper").font(.caption)
                        }
                        .labelsHidden()
                    }
                }
                Section("Audio") {
                    Toggle("Microphone", isOn: $model.settings.includeMicrophone)
                    Toggle("System audio", isOn: $model.settings.includeSystemAudio)
                    Toggle("Leave out audio muted in Screen Studio", isOn: $model.settings.respectMutes)
                        .disabled(!model.settings.includeMicrophone && !model.settings.includeSystemAudio)
                }
                Section("Save To") {
                    HStack {
                        Text(abbreviate(model.outputFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.outputFolder.path)
                        Spacer()
                        Button("Choose…") { model.chooseOutputFolder() }
                    }
                    Toggle("Replace existing exports", isOn: $model.replaceExisting)
                }
            }
            .formStyle(.grouped)
            .disabled(model.isExporting)

            Divider()
            VStack(spacing: 8) {
                Button {
                    model.startExport()
                } label: {
                    Text(exportTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("e")
                .disabled(model.isExporting || model.queue.isEmpty)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var exportTitle: String {
        if model.isExporting { return "Exporting…" }
        let count = model.queue.count
        return count == 0 ? "Export" : "Export \(count) Project\(count == 1 ? "" : "s")"
    }

    private var note: String {
        if model.checked.isEmpty { return "Tick the projects you want to export." }
        let skipped = model.skippedExistingCount
        if skipped > 0 {
            return "\(skipped) already exported and will be skipped. Your Screen Studio projects are never changed."
        }
        return "Your Screen Studio projects are never changed."
    }
}

// MARK: - Progress

private struct RunBar: View {
    @EnvironmentObject private var model: ExportModel

    var body: some View {
        if let run = model.run {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    if run.finished {
                        Image(systemName: symbol(run))
                            .font(.title2)
                            .foregroundStyle(color(run))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(run))
                                .font(.headline)
                            Text(detail(run))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Show in Finder") { model.showOutputFolder() }
                        Button("Done") { model.dismissRun() }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("Exporting \(run.index + 1) of \(run.total)")
                                    .font(.headline)
                                Text(run.currentName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(stats(run))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: run.overallFraction)
                        }
                        Button("Stop") { model.cancelExport() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.bar)
        }
    }

    private func stats(_ run: ExportRun) -> String {
        var parts = [String(format: "%.0f%%", run.overallFraction * 100)]
        if run.speed > 0 { parts.append(String(format: "%.1f× real time", run.speed)) }
        if let left = run.remainingSeconds { parts.append("about \(formatDuration(left)) left") }
        return parts.joined(separator: " · ")
    }

    private func symbol(_ run: ExportRun) -> String {
        if run.cancelled { return "stop.circle.fill" }
        return run.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private func color(_ run: ExportRun) -> Color {
        if run.cancelled { return .secondary }
        return run.failed > 0 ? .orange : .green
    }

    private func title(_ run: ExportRun) -> String {
        if run.cancelled { return "Export stopped after \(run.exported) of \(run.total)" }
        if run.failed > 0 { return "Exported \(run.exported) of \(run.total) · \(run.failed) failed" }
        return "Exported \(run.exported) project\(run.exported == 1 ? "" : "s")"
    }

    private func detail(_ run: ExportRun) -> String {
        var parts: [String] = []
        if run.exported > 0 {
            if run.bytesIn > 0 {
                let saved = 100 * (1 - Double(run.bytesOut) / Double(run.bytesIn))
                parts.append("\(formatBytes(run.bytesIn)) → \(formatBytes(run.bytesOut)) (\(Int(saved.rounded()))% smaller)")
            } else {
                parts.append("\(formatBytes(run.bytesOut)) of MP4s")
            }
        }
        if let end = run.finishedAt { parts.append("took \(formatDuration(end.timeIntervalSince(run.started)))") }
        if run.skipped > 0 { parts.append("\(run.skipped) already exported, skipped") }
        if run.failed > 0 { parts.append("hover over a failed project to see why") }
        return parts.joined(separator: " · ")
    }
}
