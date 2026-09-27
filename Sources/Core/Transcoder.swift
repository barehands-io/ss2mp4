import AVFoundation
import Dispatch
import Foundation

// MARK: - Transcoding

/// Stops every pump of one transcode together. When the export is cancelled or one input fails, the other
/// input has to stop as well, even if the writer never asks it for more data again.
final class PumpGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var stops: [() -> Void] = []
    private var firstFailure: String?

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// The label of the first pump whose append failed, if any.
    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstFailure
    }

    func onStop(_ stop: @escaping () -> Void) {
        lock.lock()
        if stopped {
            lock.unlock()
            stop()
            return
        }
        stops.append(stop)
        lock.unlock()
    }

    func stop(failing label: String? = nil) {
        lock.lock()
        if firstFailure == nil { firstFailure = label }
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let pending = stops
        stops = []
        lock.unlock()
        pending.forEach { $0() }
    }
}

/// Copies samples until the reader runs out (true), or an append fails or the group is stopped (false).
/// Everything that touches `input` runs on one serial queue, so stopping never overlaps an append:
/// AVAssetWriter must not be cancelled while an append is in progress.
func pump(_ output: AVAssetReaderOutput?, into input: AVAssetWriterInput?, label: String, group: PumpGroup,
          onSample: ((CMSampleBuffer) -> Void)? = nil) async -> Bool {
    guard let output, let input else { return true }
    let queue = DispatchQueue(label: "ss2mp4.\(input.mediaType.rawValue)")
    return await withCheckedContinuation { cont in
        var done = false
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            input.markAsFinished()
            cont.resume(returning: ok)
        }
        input.requestMediaDataWhenReady(on: queue) {
            while !done && input.isReadyForMoreMediaData {
                if group.isStopped {
                    finish(false)
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    finish(true)
                    return
                }
                onSample?(sample)
                if !input.append(sample) {
                    group.stop(failing: label)
                    finish(false)
                    return
                }
            }
        }
        // Registered after the request so that markAsFinished() can't come before it.
        group.onStop { queue.async { finish(false) } }
    }
}

func metadataItem(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value as NSString
    item.extendedLanguageTag = "und"
    return item
}

func transcode(_ plan: Plan, to out: URL, title: String, date: Date, _ settings: ExportSettings,
               cancel: CancelFlag? = nil, progress: @escaping (Double) -> Void) async throws {
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
        AVVideoExpectedSourceFrameRateKey: settings.fps,
        AVVideoMaxKeyFrameIntervalDurationKey: 10,
        AVVideoAllowFrameReorderingKey: true,
    ]
    if let mbps = settings.bitrateMbps {
        compression[AVVideoAverageBitRateKey] = Int(mbps * 1_000_000)
    } else {
        compression[AVVideoQualityKey] = settings.quality
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

    let group = PumpGroup()
    cancel?.onCancel { group.stop() }
    let total = max(plan.duration.seconds, 0.001)
    var videoSamples = 0
    async let videoOK = pump(videoOut, into: videoIn, label: "video", group: group) {
        videoSamples += 1
        progress(CMSampleBufferGetPresentationTimeStamp($0).seconds / total)
    }
    async let audioOK = pump(audioOut, into: audioIn, label: "audio", group: group)
    let (v, a) = await (videoOK, audioOK)

    if cancel?.isCancelled == true {
        reader.cancelReading()
        writer.cancelWriting()
        throw CancellationError()
    }
    if reader.status == .failed {
        writer.cancelWriting()
        throw ConvertError.failed("reading failed: " + describe(reader.error ?? ConvertError.failed("unknown")))
    }
    if ProcessInfo.processInfo.environment["SS2MP4_DEBUG"] != nil {
        printErr("debug: video samples=\(videoSamples) reader=\(reader.status.rawValue) writer=\(writer.status.rawValue) v=\(v) a=\(a)")
    }
    if !v || !a {
        writer.cancelWriting()
        throw ConvertError.failed("writing \(group.failure ?? (v ? "audio" : "video")) failed: " + describe(writer.error ?? ConvertError.failed("unknown")))
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
