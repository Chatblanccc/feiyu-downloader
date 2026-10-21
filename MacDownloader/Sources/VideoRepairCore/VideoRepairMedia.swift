import AVFoundation
import Foundation

public enum VideoRepairMedia {
    /// Uses display-oriented dimensions and the same even-pixel rounding as the worker.
    /// Already larger sources are preserved rather than silently reduced to 1080P.
    public static func outputDimensions(width: Int, height: Int, outputSize: VideoRepairOutputSize) -> (width: Int, height: Int) {
        guard outputSize != .source, width > 0, height > 0 else { return (width, height) }
        let longEdge = outputSize == .hd720 ? 1280 : 1920
        let shortEdge = outputSize == .hd720 ? 720 : 1080
        let bounds = width >= height ? (width: longEdge, height: shortEdge) : (width: shortEdge, height: longEdge)
        guard width < bounds.width, height < bounds.height else { return (width, height) }
        // Integer ratios avoid losing two pixels when a mathematically exact
        // boundary becomes 1919.9999999999998 in floating-point arithmetic.
        let widthLimits = bounds.width * height <= bounds.height * width
        let numerator = widthLimits ? bounds.width : bounds.height
        let denominator = widthLimits ? width : height
        return (max(2, (width * numerator / (2 * denominator)) * 2),
                max(2, (height * numerator / (2 * denominator)) * 2))
    }

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
    public static func validateOutput(_ output: VideoRepairMediaInfo, against input: VideoRepairMediaInfo,
                                      outputSize: VideoRepairOutputSize = .source) throws {
        let tolerance = max(0.15, 2 / max(1, input.frameRate))
        let expected = outputDimensions(width: input.width, height: input.height, outputSize: outputSize)
        guard output.width == expected.width, output.height == expected.height,
              abs(output.duration - input.duration) <= tolerance,
              abs(output.videoDuration - input.videoDuration) <= tolerance,
              abs(output.videoFrameCount - input.videoFrameCount) <= 2,
              abs(Double(output.videoFrameCount) - (input.videoDuration * output.frameRate).rounded()) <= 2,
              output.audioDurations.count == input.audioDurations.count else { throw VideoRepairError.invalidWorkerOutput }
        for (original, repaired) in zip(input.audioDurations, output.audioDurations) {
            guard abs(original - repaired) <= tolerance else { throw VideoRepairError.invalidWorkerOutput }
        }
    }
}
