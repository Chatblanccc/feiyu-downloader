import SwiftUI
import Translation
import SubtitleCore

@available(macOS 26.0, *)
@MainActor
final class TranslationPreparationCoordinator: ObservableObject {
    @Published fileprivate var configuration: TranslationSession.Configuration?
    fileprivate var requestID: UUID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: TranslationSession?
    private var availabilityTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Error>?
    private var deadlineTask: Task<Void, Never>?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 600) {
        self.timeout = timeout.isFinite ? min(600, max(0.01, timeout)) : 600
    }

    func prepare(source: String, target: String) async throws {
        try Task.checkCancellation()
        guard requestID == nil else { throw SubtitleError.operation("正在准备另一组翻译语言，请等待完成或先取消。") }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SubtitleError.unsupportedLanguage }
        if NativeTranslation.sameLanguage(source, target) { return }
        let identifier = UUID()
        requestID = identifier
        defer {
            if requestID == identifier { finish(identifier, result: .failure(CancellationError())) }
        }
        let sourceLanguage = Locale.Language(identifier: Locale.Language(identifier: source).minimalIdentifier)
        let targetLanguage = Locale.Language(identifier: Locale.Language(identifier: target).minimalIdentifier)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, requestID == identifier else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.finish(identifier, result: .failure(SubtitleError.operation("翻译语言准备超过 10 分钟，已停止等待。请检查网络后重试。")))
                }
                availabilityTask = Task { @MainActor [weak self] in
                    let availability: LanguageAvailability
                    if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
                    else { availability = LanguageAvailability() }
                    let status = await availability.status(from: sourceLanguage, to: targetLanguage)
                    guard let self, self.requestID == identifier else { return }
                    guard !Task.isCancelled else { self.cancel(identifier); return }
                    switch status {
                    case .installed, .supported:
                        if #available(macOS 26.4, *) {
                            self.configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
                        } else {
                            self.configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
                        }
                    case .unsupported:
                        self.finish(identifier, result: .failure(SubtitleError.unsupportedLanguage))
                    @unknown default:
                        self.finish(identifier, result: .failure(SubtitleError.unsupportedLanguage))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(identifier) }
        }
    }

    func cancel() {
        guard let requestID else { return }
        cancel(requestID)
    }

    fileprivate func performPreparation(_ session: TranslationSession, requestID: UUID?) async {
        guard let requestID, self.requestID == requestID, continuation != nil, preparationTask == nil else {
            session.cancel()
            return
        }
        self.session = session
        let task = Task { @MainActor in
            try await session.prepareTranslation()
            // prepareTranslation can return while a shared language download is
            // still in progress. Do not release the worker until assets are usable.
            try await Self.waitUntilReady(session)
        }
        preparationTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(requestID) }
            }
            try Task.checkCancellation()
            finish(requestID, result: .success(()))
        } catch {
            finish(requestID, result: .failure(error))
        }
    }

    private func cancel(_ identifier: UUID) {
        finish(identifier, result: .failure(CancellationError()))
    }

    private static func waitUntilReady(_ session: TranslationSession) async throws {
        guard let source = session.sourceLanguage else { throw SubtitleError.unsupportedLanguage }
        while true {
            try Task.checkCancellation()
            let availability: LanguageAvailability
            if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
            else { availability = LanguageAvailability() }
            let status = await availability.status(from: source, to: session.targetLanguage)
            try Task.checkCancellation()
            if status == .unsupported { throw SubtitleError.unsupportedLanguage }
            if status == .installed {
                let ready = await session.isReady
                try Task.checkCancellation()
                if ready { return }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func finish(_ identifier: UUID, result: Result<Void, Error>) {
        guard requestID == identifier else { return }
        let continuation = continuation
        self.continuation = nil
        requestID = nil
        configuration = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        session?.cancel()
        session = nil
        continuation?.resume(with: result)
    }
}

@available(macOS 26.0, *)
struct TranslationPreparationView: View {
    @ObservedObject private var coordinator: TranslationPreparationCoordinator

    init(coordinator: TranslationPreparationCoordinator) { self.coordinator = coordinator }

    var body: some View {
        let requestID = coordinator.requestID
        Color.clear
            .translationTask(coordinator.configuration) { session in
                await coordinator.performPreparation(session, requestID: requestID)
            }
            .accessibilityHidden(true)
    }
}
