import AVFoundation
import Foundation

public enum VideoRepairMedia {
    public static func inspect(_ url: URL) async throws -> VideoRepairMediaInfo {
        guard url.isFileURL,
              let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              ((values[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { throw VideoRepairError.invalidMedia }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoRepairError.invalidMedia }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let videoDuration = try await track.load(.timeRange).duration.seconds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2,
              bounds.width <= 8_192, bounds.height <= 8_192,
              videoDuration.isFinite, videoDuration > 0 else { throw VideoRepairError.invalidMedia }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count <= 32 else { throw VideoRepairError.invalidMedia }
        var audioDurations: [Double] = []
        for track in audio {
            let seconds = try await track.load(.timeRange).duration.seconds
            guard seconds.isFinite, seconds > 0 else { throw VideoRepairError.invalidMedia }
            audioDurations.append(seconds)
        }
        // Read compressed samples one at a time. This verifies complete container
        // coverage without decoding or retaining the full video in memory.
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        samples.alwaysCopiesSampleData = false
        guard reader.canAdd(samples) else { throw VideoRepairError.invalidMedia }
        reader.add(samples)
        guard reader.startReading() else { throw VideoRepairError.invalidMedia }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var frameCount = 0
        while reader.status == .reading {
            try Task.checkCancellation()
            let count: Int? = autoreleasepool {
                guard let buffer = samples.copyNextSampleBuffer() else { return nil }
                return CMSampleBufferGetNumSamples(buffer)
            }
            guard let count else { break }
            guard count >= 0, count <= Int.max - frameCount else { throw VideoRepairError.invalidMedia }
            frameCount += count
        }
        guard reader.status == .completed, frameCount > 0 else { throw VideoRepairError.invalidMedia }
        try Task.checkCancellation()
        return VideoRepairMediaInfo(duration: duration, videoDuration: videoDuration,
            width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()),
            // nominalFrameRate can differ from the container's actual average
            // even on CFR inputs; derive the rate from the complete sample scan.
            frameRate: Double(frameCount) / videoDuration, videoFrameCount: frameCount, audioDurations: audioDurations)
    }

    /// Reject a truncated export, an orientation/size mistake, or lost audio before commit.
    public static func validateOutput(_ output: VideoRepairMediaInfo, against input: VideoRepairMediaInfo) throws {
        let tolerance = max(0.15, 2 / max(1, input.frameRate))
        guard output.width == input.width, output.height == input.height,
              abs(output.duration - input.duration) <= tolerance,
              abs(output.videoDuration - input.videoDuration) <= tolerance,
              abs(Double(output.videoFrameCount) - (input.videoDuration * output.frameRate).rounded()) <= 2,
              output.audioDurations.count == input.audioDurations.count else { throw VideoRepairError.invalidWorkerOutput }
        for (original, repaired) in zip(input.audioDurations, output.audioDurations) {
            guard abs(original - repaired) <= tolerance else { throw VideoRepairError.invalidWorkerOutput }
        }
    }
}
