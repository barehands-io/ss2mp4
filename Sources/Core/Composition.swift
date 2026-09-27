import AVFoundation
import Foundation

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
    do { return try await body() } catch let e as ConvertError { throw e } catch let e as CancellationError { throw e } catch {
        throw ConvertError.failed("\(label): " + describe(error))
    }
}

func makePlan(_ p: Project, _ settings: ExportSettings) async throws -> Plan {
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
        for (slot, audioURL) in settings.audio(for: s, in: p).enumerated() {
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
    if settings.maxHeight > 0 && height > CGFloat(settings.maxHeight) {
        width = width * CGFloat(settings.maxHeight) / height
        height = CGFloat(settings.maxHeight)
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
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
    videoComposition.instructions = [instruction]
    videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    return Plan(composition: comp, videoComposition: videoComposition, videoTrack: videoTrack, audioTracks: audioTracks,
                renderSize: renderSize, duration: cursor)
}

