import AppKit
import Foundation
import SubtitleCore

struct SubtitleHistoryItem: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case preparing, processing, cancelling, completed, failed, cancelled, interrupted
        var active: Bool { self == .preparing || self == .processing || self == .cancelling }
        var title: String {
            switch self {
            case .preparing: return "准备语言"
            case .processing: return "正在处理"
            case .cancelling: return "正在取消"
            case .completed: return "处理完成"
            case .failed: return "处理失败"
            case .cancelled: return "已取消"
            case .interrupted: return "上次处理已中断"
            }
        }
    }
    var id: UUID { request.id }
    let request: SubtitleRequest
    var createdAt = Date()
    var state: State = .preparing
    var detail = "正在准备本机语言资源…"
    var fraction: Double?
    var error: String?
    var result: SubtitleExportResult?
}

private final class SubtitleProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: SubtitleWorkerEvent?
    private var closed = false
    func submit(_ event: SubtitleWorkerEvent) { lock.lock(); defer { lock.unlock() }; if !closed { latest = event } }
    func take() -> SubtitleWorkerEvent? { lock.lock(); defer { lock.unlock() }; defer { latest = nil }; return latest }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true; latest = nil }
}

@available(macOS 26.0, *)
@MainActor
final class SubtitleApplicationModel: ObservableObject {
    let preparation = TranslationPreparationCoordinator()
    @Published private(set) var sourceLanguages: [SubtitleLanguage] = []
    @Published private(set) var targetLanguages: [SubtitleLanguage] = []
    @Published private(set) var languagesLoading = true
    @Published var source = "en-US"
    @Published var target = "zh"
    @Published var inputURL: URL?
    @Published var textMode: SubtitleTextMode = .bilingual
    @Published var videoMode: SubtitleVideoMode = .burned
    @Published var style = SubtitleStyle.default {
        didSet {
            if savesStylePreferences, let data = try? JSONEncoder().encode(style) {
                AppTools.preferences?.set(data, forKey: "subtitleBurnStyle.v1")
            }
        }
    }
    @Published var destination: URL
    @Published private(set) var records: [SubtitleHistoryItem] = []
    @Published private(set) var isBusy = false
    @Published var notice: String?
    private let engine: SubtitleEngine
    private let historyURL: URL
    private let receiptsURL: URL
    private var activeID: UUID?
    private var worker: Task<Void, Never>?
    private var engineTask: Task<SubtitleExportResult, Error>?
    private var languageTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var mailbox: SubtitleProgressMailbox?
    private var shuttingDown = false
    private var savesStylePreferences = false

    init(historyFile: URL? = nil, executable: URL? = nil) {
        destination = AppTools.downloadsDirectory.appendingPathComponent("字幕", isDirectory: true)
        historyURL = historyFile ?? AppTools.supportDirectory.appendingPathComponent("subtitle-history.json")
        receiptsURL = historyURL.deletingLastPathComponent().appendingPathComponent("subtitle-receipts", isDirectory: true)
        engine = SubtitleEngine(executable: executable ?? Bundle.main.executableURL!, ffmpeg: AppTools.paths.ffmpeg)
        if historyFile == nil, let data = AppTools.preferences?.data(forKey: "subtitleBurnStyle.v1"),
           let saved = try? JSONDecoder().decode(SubtitleStyle.self, from: data) { style = saved }
        savesStylePreferences = historyFile == nil && AppTools.testDataDirectory == nil
        restore()
        languageTask = Task { [weak self] in
            async let sources = NativeSpeech.languages()
            async let targets = NativeTranslation.languages()
            let (sourceValues, targetValues) = await (sources, targets)
            guard !Task.isCancelled, let self else { return }
            sourceLanguages = sourceValues
            targetLanguages = targetValues
            if !sourceValues.contains(where: { $0.id == self.source }) { source = sourceValues.first?.id ?? "" }
            if !targetValues.contains(where: { $0.id == self.target }) { target = targetValues.first?.id ?? "" }
            languagesLoading = false
        }
    }

    deinit { worker?.cancel(); engineTask?.cancel(); languageTask?.cancel(); progressTask?.cancel(); mailbox?.close() }
    var current: SubtitleHistoryItem? { records.first }
    var canStart: Bool { !isBusy && !shuttingDown && !languagesLoading && inputURL != nil && !source.isEmpty && (textMode == .original || !target.isEmpty) }
    var sameLanguage: Bool { NativeTranslation.sameLanguage(source, target) }
    var hasActiveWorkForUpdate: Bool {
        isBusy || languagesLoading || worker != nil || engineTask != nil || preparation.isPreparing
    }

    func selectFile(_ url: URL) {
        guard !isBusy else { return }
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            notice = "这个文件无法读取，请选择已完整保存的视频。"; return
        }
        inputURL = url.standardizedFileURL
        notice = nil
    }

    func chooseFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择需要翻译或加字幕的视频"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video]
        if panel.runModal() == .OK, let url = panel.url { selectFile(url) }
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择字幕和视频的保存文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    func start() {
        guard canStart, let inputURL else { return }
        let request = SubtitleRequest(input: inputURL, destination: destination, source: source, target: target,
                                      textMode: textMode, videoMode: videoMode, style: style)
        let dropped = Array(records.dropFirst(199)).map(\.id)
        records.insert(SubtitleHistoryItem(request: request), at: 0)
        records = Array(records.prefix(200))
        do {
            try persist()
            for id in dropped { try? FileManager.default.removeItem(at: receiptURL(id)) }
        } catch {
            records[0].state = .failed; records[0].error = error.localizedDescription
            records[0].detail = "无法保存任务记录，尚未开始处理。"
            notice = "无法保存字幕任务：\(error.localizedDescription)"; return
        }
        activeID = request.id; isBusy = true; notice = nil
        let mailbox = SubtitleProgressMailbox()
        self.mailbox = mailbox
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { break }
                if let event = mailbox.take() { self?.apply(event, id: request.id) }
            }
        }
        let preparation = preparation, engine = engine, receipt = receiptURL(request.id)
        worker = Task { [weak self] in
            do {
                if request.textMode != .original { try await preparation.prepare(source: request.source, target: request.target) }
                try Task.checkCancellation()
                guard self?.activeID == request.id else { throw CancellationError() }
                self?.update(request.id) { $0.state = .processing; $0.detail = "正在检查视频…"; $0.fraction = 0 }
                self?.saveNoticeIfNeeded()
                let task = Task.detached(priority: .utility) {
                    try await engine.run(request, receiptURL: receipt) { mailbox.submit($0) }
                }
                self?.engineTask = task
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                self?.complete(request.id, result: result)
            } catch {
                if let result = self?.recover(request) { self?.complete(request.id, result: result) }
                else {
                    let cancelled = Task.isCancelled || error is CancellationError
                    self?.update(request.id) {
                        $0.state = cancelled ? .cancelled : .failed; $0.fraction = nil
                        $0.detail = cancelled ? "已停止，可选中原视频后手动重新开始。" : "本次处理未完成，可手动重试。"
                        $0.error = cancelled ? nil : String(error.localizedDescription.prefix(1_200))
                    }
                }
            }
            self?.finish(request.id)
        }
    }

    func cancel() {
        guard let activeID else { return }
        update(activeID) { $0.state = .cancelling; $0.detail = "正在停止并释放本次处理资源…" }
        preparation.cancel(); engineTask?.cancel(); worker?.cancel()
        saveNoticeIfNeeded()
    }

    func shutdown() async {
        shuttingDown = true; languageTask?.cancel(); cancel()
        let pending = worker
        await pending?.value
        progressTask?.cancel(); mailbox?.close()
        saveNoticeIfNeeded()
    }

    func reuse(_ item: SubtitleHistoryItem) {
        guard !isBusy else { return }
        inputURL = nil
        selectFile(item.request.input)
        guard inputURL != nil else { return }
        source = item.request.source; target = item.request.target
        textMode = item.request.textMode; videoMode = item.request.videoMode; destination = item.request.destination
        style = item.request.style
    }

    func reveal(_ result: SubtitleExportResult) { NSWorkspace.shared.activateFileViewerSelecting([result.video ?? result.subtitles]) }
    func openVideo(_ result: SubtitleExportResult) { if let video = result.video { NSWorkspace.shared.open(video) } }
    func openSubtitles(_ result: SubtitleExportResult) {
        NSWorkspace.shared.open([result.subtitles], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func apply(_ event: SubtitleWorkerEvent, id: UUID) {
        guard activeID == id, records.first(where: { $0.id == id })?.state != .cancelling else { return }
        update(id) {
            $0.fraction = event.fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            if let detail = event.detail { $0.detail = String(detail.prefix(400)) }
        }
    }

    private func complete(_ id: UUID, result: SubtitleExportResult) {
        update(id) {
            $0.state = .completed; $0.result = result; $0.fraction = 1; $0.error = nil
            $0.detail = "已保存 \(result.cueCount) 条字幕" + (result.video == nil ? "。" : "和带字幕视频。")
        }
        if !result.receiptSaved { notice = "文件已保存；本次恢复凭据未能写入，已把文件位置保留在任务记录中。" }
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        progressTask?.cancel(); progressTask = nil; mailbox?.close(); mailbox = nil
        engineTask = nil; worker = nil; activeID = nil; isBusy = false
        saveNoticeIfNeeded()
    }

    private func update(_ id: UUID, mutation: (inout SubtitleHistoryItem) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }

    private func receiptURL(_ id: UUID) -> URL { receiptsURL.appendingPathComponent(id.uuidString + ".json") }
    private func recover(_ request: SubtitleRequest) -> SubtitleExportResult? {
        let url = receiptURL(request.id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 128 * 1_024,
              let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(SubtitleReceipt.self, from: data),
              receipt.request.id == request.id, receipt.request.input.standardizedFileURL == request.input.standardizedFileURL,
              receipt.request.destination.standardizedFileURL == request.destination.standardizedFileURL,
              receipt.request.source == request.source, receipt.request.target == request.target,
              receipt.request.textMode == request.textMode, receipt.request.videoMode == request.videoMode,
              receipt.request.style == request.style,
              receipt.result.filesExist() else { return nil }
        return receipt.result
    }

    private func restore() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let size = try historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1_024 * 1_024 else { throw SubtitleError.operation("字幕记录文件过大。") }
            let saved = try JSONDecoder().decode([SubtitleHistoryItem].self, from: Data(contentsOf: historyURL))
            records = Array(saved.prefix(200)).map { item in
                var item = item
                if item.state != .completed, let result = recover(item.request) {
                    item.state = .completed; item.result = result; item.fraction = 1; item.error = nil
                    item.detail = "已从保存凭据恢复完成记录。"
                } else if item.state.active {
                    item.state = .interrupted; item.detail = "上次处理已中断，请手动重新开始。"; item.fraction = nil
                } else if item.state == .completed, item.result?.filesExist() != true {
                    item.state = .failed; item.detail = "导出文件已移动或删除，可选中原视频重新处理。"; item.fraction = nil
                }
                return item
            }
            saveNoticeIfNeeded()
        } catch {
            let backup = historyURL.deletingLastPathComponent().appendingPathComponent("subtitle-history-unreadable-\(UUID().uuidString.prefix(8)).json")
            do { try FileManager.default.copyItem(at: historyURL, to: backup); notice = "旧字幕记录无法读取，已保留备份；可以新建字幕任务。" }
            catch { notice = "字幕记录无法读取：\(error.localizedDescription)"; shuttingDown = true }
        }
    }

    private func persist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: receiptsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: receiptsURL.path)
        try JSONEncoder().encode(Array(records.prefix(200))).write(to: historyURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
    private func saveNoticeIfNeeded() {
        do { try persist() }
        catch { notice = "字幕任务记录未能保存：\(error.localizedDescription)。已导出的文件仍在保存文件夹中。" }
    }
}
