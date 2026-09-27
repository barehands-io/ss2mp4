import AVFoundation
import AppKit
import SwiftUI

/// Generates small preview frames from each project's screen recording and keeps them for the session.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [URL: NSImage] = [:]
    private var pending: [URL: Task<CGImage?, Never>] = [:]

    func image(for project: Project) async -> NSImage? {
        let key = project.url
        if let image = images[key] { return image }
        let task = pending[key] ?? Task.detached(priority: .utility) {
            await makeThumbnail(project.sessions[0].display, duration: project.durationHint)
        }
        pending[key] = task
        let cgImage = await task.value
        pending[key] = nil
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images[key] = image
        return image
    }
}

private func makeThumbnail(_ url: URL, duration: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 200)
    let tolerance = CMTime(seconds: 5, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    // A little way in, because recordings often start on a blank or unrelated frame.
    let preferred = CMTime(seconds: min(max(duration * 0.1, 1), 60), preferredTimescale: 600)
    for time in [preferred, .zero] {
        if let image = try? await generator.image(at: time).image { return image }
    }
    return nil
}

/// Per-row holder for the thumbnail. (`@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode,
/// so views here keep their state in small observable objects instead, keeping the build Command Line Tools-only.)
@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    func load(_ project: Project) async {
        image = await ThumbnailCache.shared.image(for: project)
    }
}

struct ThumbnailView: View {
    let project: Project
    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        Color.secondary.opacity(0.12)
            .overlay {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .task(id: project.url) {
                await loader.load(project)
            }
    }
}
