import AVFoundation
import CoreImage
import CoreText
import Foundation

public struct SubtitleMediaInfo: Sendable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public init(duration: Double, width: Int, height: Int) {
        self.duration = duration; self.width = width; self.height = height
    }
}

public enum SubtitleMedia {
    public static func inspect(_ url: URL) async throws -> SubtitleMediaInfo {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw SubtitleError.invalidMedia }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SubtitleError.invalidMedia }
        guard duration <= 7_200 else { throw SubtitleError.tooLong }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SubtitleError.invalidMedia }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2,
              bounds.width <= 8_192, bounds.height <= 8_192 else { throw SubtitleError.invalidMedia }
        try Task.checkCancellation()
        return SubtitleMediaInfo(duration: duration, width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()))
    }

    public static func burn(input: URL, output: URL, cues: [SubtitleCue], mode: SubtitleTextMode,
                            style: SubtitleStyle = .default,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let style = try style.validated()
        let info = try await inspect(input)
        try SubtitleDocument.validate(cues, duration: info.duration)
        // Validate all selected text before any expensive export work or file creation.
        for cue in cues { _ = try SubtitleDocument.displayText(cue, mode: mode) }
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL else { throw SubtitleError.invalidMedia }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw SubtitleError.outputExists }
        let directory = output.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw SubtitleError.operation("字幕视频的保存文件夹不可写，请更换位置。")
        }
        let temporary = directory.appendingPathComponent(".feather-subtitle-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: input)
        let scale = min(1, 1_920 / Double(max(info.width, info.height)))
        let size = CGSize(width: max(2, Int(Double(info.width) * scale / 2) * 2),
                          height: max(2, Int(Double(info.height) * scale / 2) * 2))
        let renderer = SubtitleOverlayRenderer(cues: cues, mode: mode, size: size, style: style)
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                autoreleasepool {
                    do {
                        let source = request.sourceImage
                        let image = try renderer.composite(source, at: request.compositionTime.seconds)
                        request.finish(with: image, context: renderer.context)
                    } catch { request.finish(with: error) }
                }
            }, completionHandler: { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else { continuation.resume(throwing: error ?? SubtitleError.invalidMedia) }
            })
        }
        // AVFoundation's filter composition applies the source track's preferred
        // transform before filtering. Keep display dimensions, including portrait.
        composition.renderSize = size
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let rate = try await video.load(.nominalFrameRate)
            let boundedRate = rate.isFinite && rate > 0 ? min(60, max(1, rate)) : 30
            composition.frameDuration = CMTime(value: 1, timescale: Int32(boundedRate.rounded()))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080),
              session.supportedFileTypes.contains(.mp4) else { throw SubtitleError.invalidMedia }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        session.canPerformMultiplePassesOverSourceMediaData = false
        let operation = SubtitleExportOperation(session: session, onProgress: onProgress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
        let exported = try await inspect(temporary)
        guard abs(exported.duration - info.duration) < max(0.25, info.duration * 0.001),
              let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber,
              bytes.int64Value > 0 else { throw SubtitleError.invalidMedia }
        // moveItem refuses to overwrite an output created while export was running.
        do { try FileManager.default.moveItem(at: temporary, to: output) }
        catch {
            if FileManager.default.fileExists(atPath: output.path) { throw SubtitleError.outputExists }
            throw error
        }
        onProgress(1)
    }
}

/// The filtering callback may run on several AVFoundation queues. Only two small
/// subtitle cards are retained; no per-cue layers or full-video frame cache exist.
private final class SubtitleOverlayRenderer: @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    private let cues: [SubtitleCue]
    private let mode: SubtitleTextMode
    private let size: CGSize
    private let style: SubtitleStyle
    private var intervalMaxEnds: [Double]
    private let lock = NSLock()
    private var cached: [(Int, CIImage)] = []

    init(cues: [SubtitleCue], mode: SubtitleTextMode, size: CGSize, style: SubtitleStyle = .default) {
        self.cues = cues; self.mode = mode; self.size = size; self.style = style
        intervalMaxEnds = Array(repeating: 0, count: max(1, cues.count * 4))
        if !cues.isEmpty { buildIntervals(node: 1, first: 0, last: cues.count - 1) }
    }

    func composite(_ source: CIImage, at seconds: Double) throws -> CIImage {
        let extent = source.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw SubtitleError.invalidMedia
        }
        // The factory respects preferredTransform. Normalize and scale its image
        // explicitly so 4K input is resized rather than cropped to the 1080p budget.
        let normalized = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
            .cropped(to: CGRect(origin: .zero, size: size))
        guard seconds.isFinite else { return normalized }
        // Upper-bound search avoids scanning all cues for every video frame.
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        guard low > 0, let index = activeInterval(node: 1, first: 0, last: cues.count - 1,
                                                 latest: low - 1, seconds: seconds) else { return normalized }
        lock.lock(); defer { lock.unlock() }
        let card: CIImage
        if let entry = cached.first(where: { $0.0 == index }) { card = entry.1 }
        else {
            card = try render(SubtitleDocument.displayText(cues[index], mode: mode))
            cached.append((index, card))
            if cached.count > 2 { cached.removeFirst(cached.count - 2) }
        }
        let bounds = normalized.extent
        let safeInset = max(12, bounds.height * 0.045)
        let proposedY: CGFloat
        switch style.position {
        case .bottom: proposedY = bounds.minY + safeInset
        case .center: proposedY = bounds.midY - card.extent.height / 2
        case .top: proposedY = bounds.maxY - safeInset - card.extent.height
        }
        let safeY = min(bounds.maxY - safeInset - card.extent.height, max(bounds.minY + safeInset, proposedY))
        let translated = card.transformed(by: CGAffineTransform(translationX: bounds.midX - card.extent.width / 2,
                                                                y: safeY))
        return translated.composited(over: normalized).cropped(to: bounds)
    }

    private func buildIntervals(node: Int, first: Int, last: Int) {
        if first == last { intervalMaxEnds[node] = cues[first].end; return }
        let middle = (first + last) / 2
        buildIntervals(node: node * 2, first: first, last: middle)
        buildIntervals(node: node * 2 + 1, first: middle + 1, last: last)
        intervalMaxEnds[node] = max(intervalMaxEnds[node * 2], intervalMaxEnds[node * 2 + 1])
    }

    private func activeInterval(node: Int, first: Int, last: Int, latest: Int, seconds: Double) -> Int? {
        guard first <= latest, intervalMaxEnds[node] > seconds else { return nil }
        if first == last { return first }
        let middle = (first + last) / 2
        return activeInterval(node: node * 2 + 1, first: middle + 1, last: last, latest: latest, seconds: seconds)
            ?? activeInterval(node: node * 2, first: first, last: middle, latest: latest, seconds: seconds)
    }

    private func render(_ text: String) throws -> CIImage {
        let width = floor(size.width * 0.9)
        let padding = max(8, floor(size.width * 0.009))
        let maximumHeight = floor(size.height * 0.38)
        var fontSize = max(16, min(54, size.width * 0.028)) * style.fontScale
        let minimumSize = max(12, min(24, size.width * 0.016)) * style.fontScale
        guard let rgb = UInt32(style.colorHex, radix: 16) else { throw SubtitleError.invalidSubtitles }
        let fill = CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        var attributed: NSAttributedString!
        var framesetter: CTFramesetter!
        var textHeight: CGFloat = 0
        while true {
            let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
            var alignment = CTTextAlignment.center
            let paragraph = withUnsafePointer(to: &alignment) {
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)
                return CTParagraphStyleCreate(&setting, 1)
            }
            attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 0.95),
                // Core Text uses a percentage of font size. A negative width
                // draws the selected fill as well as a fine black glyph outline.
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -3.0,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ])
            framesetter = CTFramesetterCreateWithAttributedString(attributed)
            textHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                         CGSize(width: width - padding * 2, height: 100_000), nil).height)
            if textHeight + padding * 2 <= maximumHeight { break }
            guard fontSize > minimumSize else {
                throw SubtitleError.operation("这段字幕文字过长，无法在画面内清晰显示。请改为导出字幕文件或可开关字幕的视频。")
            }
            fontSize = max(minimumSize, fontSize - 2)
        }
        let height = max(1, textHeight + padding * 2 + 3)
        guard width > 0, height > 0, width * height <= 8_000_000,
              let bitmap = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SubtitleError.invalidSubtitles }
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        guard CTFrameGetVisibleStringRange(frame).length == attributed.length else { throw SubtitleError.invalidSubtitles }
        CTFrameDraw(frame, bitmap)
        guard let image = bitmap.makeImage() else { throw SubtitleError.invalidSubtitles }
        return CIImage(cgImage: image)
    }
}

private final class SubtitleExportOperation: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let onProgress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "io.feather.subtitle-export")
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var terminal = false
    private var lastProgress: Double = -1
    private var startedAt: TimeInterval = 0
    private var forcedError: Error?

    init(session: AVAssetExportSession, onProgress: @escaping @Sendable (Double) -> Void) {
        self.session = session; self.onProgress = onProgress
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            startedAt = ProcessInfo.processInfo.systemUptime
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source; source.resume()
            session.exportAsynchronously { [self] in queue.async { [self] in complete() } }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            guard !terminal else { return }
            session.cancelExport()
            forceFinish(after: CancellationError())
        }
    }

    private func sample() {
        guard !terminal else { return }
        let value = min(0.99, max(0, Double(session.progress)))
        if value.isFinite, value - lastProgress >= 0.005 { lastProgress = value; onProgress(value) }
        if ProcessInfo.processInfo.systemUptime - startedAt >= 1_800, forcedError == nil {
            session.cancelExport()
            forceFinish(after: SubtitleError.operation("字幕视频导出等待过久，已停止。请改用较短的视频后重试。"))
        }
    }

    private func forceFinish(after error: Error) {
        guard forcedError == nil else { return }
        forcedError = error
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            if !terminal, continuation != nil { finish(.failure(error)) }
        }
    }

    private func complete() {
        switch session.status {
        case .completed: finish(.success(()))
        case .cancelled: finish(.failure(forcedError ?? CancellationError()))
        default: finish(.failure(forcedError ?? SubtitleError.operation("字幕视频导出失败，请确认原视频能够正常播放。")))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !terminal, let continuation else { return }
        terminal = true; self.continuation = nil
        timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}
