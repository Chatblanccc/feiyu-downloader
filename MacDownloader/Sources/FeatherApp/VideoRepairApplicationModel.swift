import AppKit
import Foundation
import UniformTypeIdentifiers
import VideoRepairCore

struct VideoRepairHistoryItem: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case preparing, processing, cancelling, completed, failed, cancelled, interrupted

        var active: Bool { self == .preparing || self == .processing || self == .cancelling }
        var title: String {
            switch self {
            case .preparing: return "准备修复"
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
    let request: VideoRepairRequest
    var createdAt = Date()
    var state: State = .preparing
    var stage = "preparing"
    var detail = "正在准备本机 AI 引擎…"
    var fraction: Double?
    var error: String?
    var result: VideoRepairExportResult?
}

private final class VideoRepairProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: VideoRepairWorkerEvent?
    private var closed = false

    func submit(_ event: VideoRepairWorkerEvent) {
        lock.lock(); defer { lock.unlock() }
        if !closed { latest = event }
    }
    func take() -> VideoRepairWorkerEvent? {
        lock.lock(); defer { lock.unlock() }
        defer { latest = nil }
        return latest
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; latest = nil
    }
}

/// This feature is available on macOS 13 independently of native subtitle services.
@MainActor
final class VideoRepairFeature {
    private var storage: VideoRepairApplicationModel?
    var model: VideoRepairApplicationModel {
        if let storage { return storage }
        let model = VideoRepairApplicationModel()
        storage = model
        return model
    }
    var hasActiveWorkForUpdate: Bool { storage?.hasActiveWorkForUpdate == true }
    func shutdown() async { await storage?.shutdown() }
}

@MainActor
final class VideoRepairApplicationModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var engine: VideoRepairEngineKind = .realesrgan {
        didSet {
            if engine == .seedvr2 { enhance = true; repairMosaic = false; performance = .quality; outputSize = .hd720 }
            else if outputSize == .hd720 { outputSize = .source }
        }
    }
    @Published var enhance = true
    @Published var repairMosaic = true
    @Published var performance: VideoRepairPerformance = .balanced
    @Published var outputSize: VideoRepairOutputSize = .source {
        didSet {
            if outputSize == .fullHD {
                enhance = true
                if performance == .balanced { performance = .quality }
            }
        }
    }
    @Published var destination: URL
    @Published private(set) var records: [VideoRepairHistoryItem] = []
    @Published private(set) var isBusy = false
    @Published var notice: String?
    @Published private(set) var isPreparingComponent = false
    @Published private(set) var componentFraction: Double?
    @Published private(set) var componentDetail = ""

    private let historyURL: URL
    private let receiptsURL: URL
    private var activeID: UUID?
    private var worker: Task<Void, Never>?
    private var engineTask: Task<VideoRepairExportResult, Error>?
    private var progressTask: Task<Void, Never>?
    private var mailbox: VideoRepairProgressMailbox?
    private var shuttingDown = false
    private var componentTask: Task<Void, Never>?
    private var componentProgressTask: Task<Void, Never>?
    private var componentMailbox: VideoRepairProgressMailbox?

    init(historyFile: URL? = nil) {
        destination = AppTools.downloadsDirectory.appendingPathComponent("AI修复", isDirectory: true)
        historyURL = historyFile ?? AppTools.supportDirectory.appendingPathComponent("video-repair-history.json")
        receiptsURL = historyURL.deletingLastPathComponent().appendingPathComponent("video-repair-receipts", isDirectory: true)
        restore()
    }

    deinit { worker?.cancel(); engineTask?.cancel(); progressTask?.cancel(); mailbox?.close(); componentTask?.cancel(); componentProgressTask?.cancel(); componentMailbox?.close() }

    var current: VideoRepairHistoryItem? { records.first }
    var canStart: Bool { !isBusy && !shuttingDown && inputURL != nil && (enhance || repairMosaic) }
    var hasActiveWorkForUpdate: Bool { isBusy || worker != nil || engineTask != nil || componentTask != nil }
    var componentReady: Bool { (try? VideoRepairRuntime.discover(bundle: .main, engine: engine)) != nil }
    var componentDownloadSize: String {
        guard let catalog = try? componentStore.catalog else { return "组件" }
        return ByteCountFormatter.string(fromByteCount: catalog.totalDownloadBytes, countStyle: .file)
    }
    private var componentStore: VideoRepairComponentStore {
        VideoRepairComponentStore(supportDirectory: AppTools.supportDirectory,
                                  resourcesDirectory: Bundle.main.resourceURL ?? Bundle.main.bundleURL, engine: engine)
    }

    func prepareComponents(startWhenReady: Bool = false, forceRepair: Bool = false) {
        guard !isBusy, !shuttingDown else { return }
        let selected = engine, store = componentStore
        isBusy = true; isPreparingComponent = true; componentFraction = nil
        componentDetail = "正在检查本地组件和可用空间…"; notice = nil
        let updates = VideoRepairProgressMailbox(); componentMailbox = updates
        componentProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { break }
                if let event = updates.take() { self?.componentFraction = event.fraction; self?.componentDetail = event.detail ?? "正在准备组件…" }
            }
        }
        componentTask = Task { [weak self] in
            var ready = false
            do {
                _ = try await store.ensureInstalled(forceRepair: forceRepair) { updates.submit($0) }
                try Task.checkCancellation()
                self?.componentFraction = 1; self?.componentDetail = "组件已准备好，之后可离线使用。"
                ready = true
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                self?.componentDetail = cancelled ? "已停止下载，已校验的文件会保留供下次使用。" : "组件尚未准备完成，可重试。"
                self?.notice = cancelled ? nil : error.localizedDescription
            }
            updates.close(); self?.componentProgressTask?.cancel(); self?.componentProgressTask = nil; self?.componentMailbox = nil
            self?.isBusy = false; self?.isPreparingComponent = false; self?.componentTask = nil
            if ready && startWhenReady && self?.engine == selected && self?.shuttingDown == false { self?.startPrepared() }
        }
    }

    func selectFile(_ url: URL) {
        guard !isBusy, !shuttingDown else { return }
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            notice = "这个文件无法读取，请选择已完整保存的视频。"
            return
        }
        inputURL = url.standardizedFileURL
        notice = nil
    }

    func chooseFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择需要 AI 修复的视频"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video] + ["mkv", "webm", "avi", "ts"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { selectFile(url) }
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择修复视频的保存文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    func start() {
        guard canStart else { return }
        if componentReady { startPrepared() }
        else { prepareComponents(startWhenReady: true) }
    }

    private func startPrepared() {
        guard canStart, let inputURL else { return }
        let request = VideoRepairRequest(input: inputURL, destination: destination,
                                        enhance: enhance || outputSize == .fullHD, repairMosaic: repairMosaic,
                                        performance: performance, outputSize: outputSize, engine: engine)
        let dropped = Array(records.dropFirst(199)).map(\.id)
        records.insert(VideoRepairHistoryItem(request: request), at: 0)
        records = Array(records.prefix(200))
        do {
            try persist()
            for id in dropped { try? FileManager.default.removeItem(at: receiptURL(id)) }
        } catch {
            records[0].state = .failed
            records[0].error = error.localizedDescription
            records[0].detail = "无法保存任务记录，尚未开始处理。"
            notice = "无法保存 AI 修复任务：\(error.localizedDescription)"
            return
        }

        activeID = request.id; isBusy = true; notice = nil
        let mailbox = VideoRepairProgressMailbox()
        self.mailbox = mailbox
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { break }
                if let event = mailbox.take() { self?.apply(event, id: request.id) }
            }
        }
        let receipt = receiptURL(request.id)
        worker = Task { [weak self] in
            do {
                let task = Task.detached(priority: .utility) {
                    let runtime = try VideoRepairRuntime.discover(bundle: .main, engine: request.engine)
                    let engine = VideoRepairEngine(runtime: runtime)
                    return try await engine.run(request, receiptURL: receipt) { mailbox.submit($0) }
                }
                self?.engineTask = task
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                self?.complete(request.id, result: result)
            } catch {
                // A successfully committed output wins over a late cancellation.
                if let result = self?.recover(request) { self?.complete(request.id, result: result) }
                else {
                    let cancelled = Task.isCancelled || error is CancellationError
                    self?.update(request.id) {
                        $0.state = cancelled ? .cancelled : .failed; $0.fraction = nil
                        $0.detail = cancelled ? "已停止处理，可使用原视频重新开始。" : "本次处理未完成，可使用原视频重试。"
                        $0.error = cancelled ? nil : String(error.localizedDescription.prefix(1_200))
                    }
                }
            }
            self?.finish(request.id)
        }
    }

    func cancel() {
        if isPreparingComponent { componentTask?.cancel(); componentDetail = "正在停止下载并释放资源…"; return }
        guard let activeID else { return }
        update(activeID) { $0.state = .cancelling; $0.detail = "正在停止并释放本次处理资源…" }
        engineTask?.cancel(); worker?.cancel()
        saveNoticeIfNeeded()
    }

    func shutdown() async {
        shuttingDown = true
        cancel()
        let pending = worker
        let preparing = componentTask
        await preparing?.value
        await pending?.value
        progressTask?.cancel(); mailbox?.close()
        saveNoticeIfNeeded()
    }

    func reuse(_ item: VideoRepairHistoryItem) {
        guard !isBusy else { return }
        inputURL = nil
        selectFile(item.request.input)
        guard inputURL != nil else { return }
        engine = item.request.engine
        enhance = item.request.enhance; repairMosaic = item.request.repairMosaic
        performance = item.request.performance
        outputSize = item.request.outputSize
        destination = item.request.destination
    }

    func canRemove(_ id: UUID) -> Bool {
        guard activeID != id, let item = records.first(where: { $0.id == id }) else { return false }
        return !item.state.active
    }

    func remove(_ id: UUID) {
        guard canRemove(id) else { return }
        let previous = records
        records.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            records = previous
            notice = "无法移除 AI 修复记录：\(error.localizedDescription)。记录已保留，请稍后重试。"
            return
        }
        // Only discard the internal recovery receipt; source and exported files stay intact.
        try? FileManager.default.removeItem(at: receiptURL(id))
    }

    func reveal(_ result: VideoRepairExportResult) {
        guard resultAvailable(result) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.video])
    }
    func openVideo(_ result: VideoRepairExportResult) {
        guard resultAvailable(result) else { return }
        NSWorkspace.shared.open(result.video)
    }
    func openReport(_ result: VideoRepairExportResult) {
        guard resultAvailable(result) else { return }
        NSWorkspace.shared.open([result.report], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func resultAvailable(_ result: VideoRepairExportResult) -> Bool {
        guard result.filesExist() else {
            notice = "导出视频或处理报告已被移动、删除或更改，请在保存文件夹中查找，或使用原视频重新处理。"
            return false
        }
        return true
    }

    private func apply(_ event: VideoRepairWorkerEvent, id: UUID) {
        guard activeID == id, records.first(where: { $0.id == id })?.state != .cancelling else { return }
        let stageChanged = records.first(where: { $0.id == id })?.stage != event.stage
        update(id) {
            $0.state = .processing
            $0.stage = String(event.stage.prefix(80))
            $0.fraction = event.fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            if let detail = event.detail { $0.detail = String(detail.prefix(400)) }
        }
        if stageChanged { saveNoticeIfNeeded() }
    }

    private func complete(_ id: UUID, result: VideoRepairExportResult) {
        update(id) {
            $0.state = .completed; $0.result = result; $0.fraction = 1; $0.error = nil
            $0.detail = $0.request.repairMosaic && result.detectedRegions == 0
                ? "整片处理完成，未检测到达到阈值的疑似马赛克区域。已保存处理视频和报告。"
                : "已保存修复视频和处理报告，可以播放检查效果。"
        }
        if !result.receiptSaved { notice = "视频已保存；本次恢复凭据未能写入，文件位置已保留在任务记录中。" }
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        progressTask?.cancel(); progressTask = nil; mailbox?.close(); mailbox = nil
        engineTask = nil; worker = nil; activeID = nil; isBusy = false
        saveNoticeIfNeeded()
    }

    private func update(_ id: UUID, mutation: (inout VideoRepairHistoryItem) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }

    private func receiptURL(_ id: UUID) -> URL { receiptsURL.appendingPathComponent(id.uuidString + ".json") }

    private func recover(_ request: VideoRepairRequest) -> VideoRepairExportResult? {
        let url = receiptURL(request.id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 128 * 1_024,
              let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(VideoRepairReceipt.self, from: data),
              receipt.request == request, receipt.result.filesExist() else { return nil }
        return receipt.result
    }

    private func restore() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let size = try historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            let saved = try JSONDecoder().decode([VideoRepairHistoryItem].self, from: Data(contentsOf: historyURL))
            records = Array(saved.prefix(200)).map { item in
                var item = item
                if item.state != .completed, let result = recover(item.request) {
                    item.state = .completed; item.result = result; item.fraction = 1; item.error = nil
                    item.detail = "已从保存凭据恢复完成记录。"
                } else if item.state.active {
                    item.state = .interrupted; item.detail = "上次处理已中断，请使用原视频重新开始。"; item.fraction = nil
                } else if item.state == .completed, item.result?.filesExist() != true {
                    item.state = .failed; item.detail = "导出文件已移动或删除，可使用原视频重新处理。"; item.fraction = nil
                }
                return item
            }
            saveNoticeIfNeeded()
        } catch {
            let backup = historyURL.deletingLastPathComponent().appendingPathComponent("video-repair-history-unreadable-\(UUID().uuidString.prefix(8)).json")
            do {
                try FileManager.default.copyItem(at: historyURL, to: backup)
                notice = "旧 AI 修复记录无法读取，已保留备份；可以新建修复任务。"
            } catch {
                notice = "AI 修复记录无法读取：\(error.localizedDescription)"
                shuttingDown = true
            }
        }
    }

    private func persist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: receiptsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: receiptsURL.path)
        try TaskHistoryStorage.write(JSONEncoder().encode(Array(records.prefix(200))), to: historyURL)
    }

    private func saveNoticeIfNeeded() {
        do { try persist() }
        catch { notice = "AI 修复记录未能保存：\(error.localizedDescription)。已导出的视频仍在保存文件夹中。" }
    }
}
