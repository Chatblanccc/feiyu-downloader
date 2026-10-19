import Foundation
import Translation

@available(macOS 26.0, *)
public enum NativeTranslation {
    private static let maximumCues = 10_000
    private static let maximumTextBytes = 2 * 1_024 * 1_024
    private static let maximumBatchBytes = 8 * 1_024
    private static let maximumBatchCues = 24
    private static let batchTimeout: TimeInterval = 120
    private static let totalTimeout: TimeInterval = 30 * 60

    /// Region variants share subtitles, while different scripts remain distinct.
    public static func sameLanguage(_ source: String, _ target: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let source = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: target)
        guard let sourceCode = source.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier,
              let sourceScript = source.script?.identifier,
              let targetScript = target.script?.identifier else { return false }
        return sourceCode == targetCode && sourceScript == targetScript
    }

    public static func languages() async -> [SubtitleLanguage] {
        let availability = makeAvailability()
        let languages = await availability.supportedLanguages
        let displayLocale = Locale(identifier: "zh-Hans")
        var identifiers = Set<String>()
        return languages.compactMap { language in
            let identifier = language.minimalIdentifier
            guard identifiers.insert(identifier).inserted else { return nil }
            return SubtitleLanguage(id: identifier, name: displayLocale.localizedString(forIdentifier: identifier) ?? identifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func translate(
        cues: [SubtitleCue],
        source: String,
        target: String,
        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        let inputBytes = try validate(cues: cues)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleError.unsupportedLanguage
        }
        if sameLanguage(source, target) {
            let result = cues.map { cue -> SubtitleCue in
                var cue = cue
                cue.translatedText = cue.sourceText
                return cue
            }
            onProgress(SubtitleWorkerEvent(stage: "translating", fraction: 1, detail: "源语言与目标语言相同，已保留原文字幕。"))
            return result
        }

        let sourceLanguage = Locale.Language(identifier: Locale.Language(identifier: source).minimalIdentifier)
        let targetLanguage = Locale.Language(identifier: Locale.Language(identifier: target).minimalIdentifier)
        let availability = makeAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        try Task.checkCancellation()
        switch status {
        case .installed: break
        case .supported:
            throw SubtitleError.operation("翻译语言尚未准备好，请先在飞羽下载中准备所选语言，再开始处理。")
        case .unsupported: throw SubtitleError.unsupportedLanguage
        @unknown default: throw SubtitleError.unsupportedLanguage
        }

        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        }
        let cancellation = TranslationCancellation(session: session)
        let deadline = TranslationDeadline(after: totalTimeout) {
            cancellation.stop(reason: "翻译超过 30 分钟，任务已停止。已完成的识别字幕仍可保留，请分段重试。")
        }
        defer {
            deadline.cancel()
            cancellation.finish()
        }

        return try await withTaskCancellationHandler {
            var result = cues
            var offset = 0
            var outputBytes = 0
            while offset < cues.count {
                try Task.checkCancellation()
                try cancellation.check()
                var upperBound = offset
                var batchBytes = 0
                while upperBound < cues.count, upperBound - offset < maximumBatchCues {
                    let bytes = cues[upperBound].sourceText.utf8.count
                    guard batchBytes + bytes <= maximumBatchBytes else { break }
                    batchBytes += bytes
                    upperBound += 1
                }
                guard upperBound > offset else { throw SubtitleError.tooManyCues }
                let batch = cues[offset..<upperBound]
                let requests = batch.map {
                    TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: String($0.id))
                }
                onProgress(SubtitleWorkerEvent(stage: "translating", fraction: Double(offset) / Double(cues.count), detail: "正在翻译第 \(offset + 1)–\(upperBound) 条，共 \(cues.count) 条。"))
                let batchDeadline = TranslationDeadline(after: batchTimeout) {
                    cancellation.stop(reason: "这一批字幕翻译超过 2 分钟，任务已停止，请稍后重试或分段处理。")
                }
                let responses: [TranslationSession.Response]
                do {
                    responses = try await session.translations(from: requests)
                    batchDeadline.cancel()
                } catch {
                    batchDeadline.cancel()
                    try cancellation.check()
                    try Task.checkCancellation()
                    throw error
                }
                try cancellation.check()
                try Task.checkCancellation()
                guard responses.count == batch.count else { throw SubtitleError.invalidSubtitles }
                let expected = Dictionary(uniqueKeysWithValues: batch.map { (String($0.id), $0) })
                var translated: [Int: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let cue = expected[identifier],
                          response.sourceText == cue.sourceText,
                          translated[cue.id] == nil else { throw SubtitleError.invalidSubtitles }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !text.contains("\0") else { throw SubtitleError.invalidSubtitles }
                    let bytes = text.utf8.count
                    guard bytes <= maximumBatchBytes * 8,
                          inputBytes + outputBytes + bytes <= maximumTextBytes else { throw SubtitleError.tooManyCues }
                    outputBytes += bytes
                    translated[cue.id] = text
                }
                for index in offset..<upperBound {
                    guard let text = translated[cues[index].id] else { throw SubtitleError.invalidSubtitles }
                    result[index].translatedText = text
                }
                offset = upperBound
                onProgress(SubtitleWorkerEvent(stage: "translating", fraction: Double(offset) / Double(cues.count), detail: "已翻译 \(offset)/\(cues.count) 条字幕。"))
            }
            return result
        } onCancel: {
            cancellation.stop(reason: nil)
        }
    }

    private static func makeAvailability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    private static func validate(cues: [SubtitleCue]) throws -> Int {
        guard !cues.isEmpty else { throw SubtitleError.noSpeech }
        guard cues.count <= maximumCues else { throw SubtitleError.tooManyCues }
        var identifiers = Set<Int>()
        var bytes = 0
        for cue in cues {
            guard identifiers.insert(cue.id).inserted,
                  cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                  !cue.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cue.sourceText.contains("\0") else { throw SubtitleError.invalidSubtitles }
            let cueBytes = cue.sourceText.utf8.count
            guard cueBytes <= maximumBatchBytes else { throw SubtitleError.tooManyCues }
            bytes += cueBytes
            guard bytes <= maximumTextBytes else { throw SubtitleError.tooManyCues }
        }
        return bytes
    }
}

/// The timer must be able to cancel a blocked framework request without waiting
/// for its Swift task or actor. All mutable state is protected by the lock.
@available(macOS 26.0, *)
private final class TranslationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var session: TranslationSession?
    private var stopped = false
    private var reason: String?

    init(session: TranslationSession) { self.session = session }

    func stop(reason: String?) {
        lock.lock()
        guard !stopped, let session else { lock.unlock(); return }
        stopped = true
        self.reason = reason
        lock.unlock()
        session.cancel()
    }

    func check() throws {
        lock.lock()
        let stopped = stopped
        let reason = reason
        lock.unlock()
        guard stopped else { return }
        if let reason { throw SubtitleError.operation(reason) }
        throw CancellationError()
    }

    func finish() {
        lock.lock()
        let session = session
        self.session = nil
        lock.unlock()
        session?.cancel()
    }
}

private final class TranslationDeadline: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
    }

    func cancel() { timer.cancel() }
    deinit { timer.cancel() }
}
