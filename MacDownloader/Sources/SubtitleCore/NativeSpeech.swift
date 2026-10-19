import Foundation
import AVFoundation
import CoreMedia
import Speech

@available(macOS 26.0, *)
public enum NativeSpeech {
    public static func languages() async -> [SubtitleLanguage] {
        var byID: [String: Locale] = [:]
        for locale in await DictationTranscriber.supportedLocales {
            byID[locale.identifier(.bcp47)] = locale
        }
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                byID[locale.identifier(.bcp47)] = locale
            }
        }
        let display = Locale(identifier: "zh-Hans")
        return byID.map { id, locale in
            SubtitleLanguage(id: id, name: display.localizedString(forIdentifier: locale.identifier) ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func transcribe(
        audioFile: URL,
        localeIdentifier: String,
        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard !localeIdentifier.isEmpty, localeIdentifier.utf8.count <= 100 else {
            throw SubtitleError.unsupportedLanguage
        }
        // AVAudioFile reads the header here and streams audio through the analyzer below.
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audioFile) }
        catch { throw SubtitleError.invalidMedia }
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0 else { throw SubtitleError.noAudio }
        let duration = Double(file.length) / rate
        guard duration.isFinite, duration > 0 else { throw SubtitleError.invalidMedia }
        guard duration <= 2 * 60 * 60 + 1 else { throw SubtitleError.tooLong }

        let requested = Locale(identifier: localeIdentifier)
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            return try await run(file: file, duration: duration, module: module, locale: locale, onProgress: onProgress) { $0.text }
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw SubtitleError.unsupportedLanguage
        }
        let module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        return try await run(file: file, duration: duration, module: module, locale: locale, onProgress: onProgress) { $0.text }
    }

    private static func run<M: LocaleDependentSpeechModule>(
        file: AVAudioFile,
        duration: Double,
        module: M,
        locale: Locale,
        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void,
        text: @escaping @Sendable (M.Result) -> AttributedString
    ) async throws -> [SubtitleCue] {
        // reserve returns false for an existing reservation, which must remain untouched.
        let ownsReservation = try await AssetInventory.reserve(locale: locale)
        do {
            try Task.checkCancellation()
            try await prepare(module: module, onProgress: onProgress)
            try Task.checkCancellation()
            let result = try await analyze(file: file, duration: duration, module: module, onProgress: onProgress, text: text)
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            return result
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func prepare<M: SpeechModule>(
        module: M,
        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void
    ) async throws {
        onProgress(.init(stage: "speechAssets", detail: "正在检查识别语言资源，首次使用可能需要联网下载"))
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let progress = request.progress
        let monitor = Task {
            while !Task.isCancelled {
                let value = progress.fractionCompleted
                onProgress(.init(stage: "speechAssets", fraction: value.isFinite ? min(1, max(0, value)) : nil, detail: "正在准备本机识别语言资源"))
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
            try Task.checkCancellation()
        } onCancel: {
            // The system owns shared downloads; cancellation ends our request and interest.
            progress.cancel()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw SubtitleError.operation("识别语言资源尚未准备完成，请联网后重试。")
        }
    }

    private static func analyze<M: SpeechModule>(
        file: AVAudioFile,
        duration: Double,
        module: M,
        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void,
        text: @escaping @Sendable (M.Result) -> AttributedString
    ) async throws -> [SubtitleCue] {
        let reporter = NativeSpeechProgress(onProgress)
        reporter.send(.init(stage: "recognizing", fraction: 0, detail: "正在本机识别人声"), force: true)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .whileInUse))
        await analyzer.setVolatileRangeChangedHandler { range, _, _ in
            let seconds = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard seconds.isFinite else { return }
            reporter.send(.init(stage: "recognizing", fraction: min(0.99, max(0, seconds / duration)), detail: "正在本机识别人声"))
        }
        let collector = Task<[SubtitleCue], Error> {
            var builder = NativeSpeechCueBuilder(duration: duration)
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    try builder.append(text(result), fallback: result.range)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    if end.isFinite {
                        reporter.send(.init(stage: "recognizing", fraction: min(0.99, max(0, end / duration)), detail: "已识别 \(builder.count) 条字幕"))
                    }
                }
                return try builder.finish()
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let cues = try await collector.value
                try Task.checkCancellation()
                guard !cues.isEmpty else { throw SubtitleError.noSpeech }
                reporter.send(.init(stage: "recognizing", fraction: 1, detail: "已识别 \(cues.count) 条字幕"), force: true)
                return cues
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                do { _ = try await collector.value }
                catch let resultError {
                    if !(resultError is CancellationError) { throw resultError }
                }
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

@available(macOS 26.0, *)
private final class NativeSpeechProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.infinity
    private let callback: @Sendable (SubtitleWorkerEvent) -> Void
    init(_ callback: @escaping @Sendable (SubtitleWorkerEvent) -> Void) { self.callback = callback }
    func send(_ event: SubtitleWorkerEvent, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let allowed = force || now - last >= 0.2
        if allowed { last = now }
        lock.unlock()
        if allowed { callback(event) }
    }
}

@available(macOS 26.0, *)
private struct NativeSpeechCueBuilder {
    private let duration: Double
    private var cues: [SubtitleCue] = []
    private var currentText = ""
    private var currentStart = 0.0
    private var currentEnd = 0.0
    private var bytes = 0
    private static let byteLimit = 2 * 1024 * 1024
    private static let cueLimit = 10_000
    var count: Int { cues.count + (currentText.isEmpty ? 0 : 1) }
    init(duration: Double) { self.duration = duration }

    mutating func append(_ text: AttributedString, fallback: CMTimeRange) throws {
        // Do not synthesize evenly-spaced timestamps: split only at real model time boundaries.
        guard String(text.characters).utf8.count <= Self.byteLimit - bytes else { throw SubtitleError.tooManyCues }
        let hasTimedRuns = text.runs.contains { run in
            guard let time = run.audioTimeRange else { return false }
            return valid(time) != nil
        }
        if !hasTimedRuns {
            guard let range = valid(fallback) else { return }
            try appendPiece(Self.clean(String(text.characters)), start: range.0, end: range.1)
            return
        }
        var prefix = ""
        for run in text.runs {
            let value = Self.clean(String(text[run.range].characters))
            guard !value.isEmpty else { continue }
            if let time = run.audioTimeRange, let range = valid(time) {
                try appendPiece(prefix + value, start: range.0, end: range.1)
                prefix = ""
            } else if !currentText.isEmpty {
                // Spaces and punctuation often have no timing attribute; they must not extend a cue to the full result range.
                guard value.utf8.count <= Self.byteLimit - bytes else { throw SubtitleError.tooManyCues }
                bytes += value.utf8.count
                currentText += value
            } else {
                prefix += value
            }
        }
    }

    private func valid(_ time: CMTimeRange) -> (Double, Double)? {
        let start = CMTimeGetSeconds(time.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(time))
        guard start.isFinite, end.isFinite, end > start, start >= -0.01, start < duration else { return nil }
        return (max(0, start), min(duration, end))
    }

    private static func clean(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        cleaned.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            // Preserve Unicode shaping, RTL marks, joiners and emoji sequences.
            let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            cleaned.append(isControl ? UnicodeScalar(32)! : scalar)
        }
        return String(cleaned)
    }

    private mutating func appendPiece(_ text: String, start: Double, end: Double) throws {
        let addition = text.utf8.count
        guard addition <= Self.byteLimit - bytes else { throw SubtitleError.tooManyCues }
        bytes += addition
        let trimmedCurrent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = trimmedCurrent.last.map { ".!?。！？；;".contains($0) } ?? false
        let pause = start - currentEnd
        let canSplit = !trimmedCurrent.isEmpty && start >= currentEnd - 0.03 && start > currentStart
        if canSplit && (start - currentStart >= 7 || currentText.count + text.count > 84 || pause >= 0.8 || (terminal && currentEnd - currentStart >= 1)) {
            try flush()
        }
        if currentText.isEmpty { currentStart = start; currentEnd = end }
        else { currentEnd = max(currentEnd, end) }
        currentText += text
        // Whitespace is carried through to preserve word separation; it is trimmed at the cue boundary.
    }

    private mutating func flush() throws {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentText = "" }
        guard !value.isEmpty, currentEnd > currentStart else { return }
        guard cues.count < Self.cueLimit else { throw SubtitleError.tooManyCues }
        // Final Speech results are ordered and non-overlapping. Attribute boundaries may differ by a few samples.
        let start = max(currentStart, cues.last?.end ?? 0)
        guard currentEnd > start else { return }
        cues.append(SubtitleCue(id: cues.count + 1, start: start, end: currentEnd, sourceText: value))
    }

    private static func needsWordSpace(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first, last.isLetter || last.isNumber, first.isLetter || first.isNumber else { return false }
        func cjk(_ char: Character) -> Bool {
            char.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }
        }
        return !cjk(last) && !cjk(first)
    }

    mutating func finish() throws -> [SubtitleCue] {
        try flush()
        // A final syllable or punctuation-sized tail is easier to read with the preceding cue.
        if cues.count >= 2, let tail = cues.last, tail.end - tail.start < 0.8, tail.sourceText.count <= 5 {
            let previous = cues[cues.count - 2]
            if previous.sourceText.count + tail.sourceText.count <= 100, tail.start - previous.end < 0.2 {
                let boundary = Self.needsWordSpace(previous.sourceText, tail.sourceText) ? " " : ""
                cues[cues.count - 2].sourceText += boundary + tail.sourceText
                cues[cues.count - 2].end = tail.end
                cues.removeLast()
            }
        }
        return cues
    }
}
