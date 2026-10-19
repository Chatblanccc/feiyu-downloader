import AppKit
import Combine
import DownloadCore
import Foundation
import UniformTypeIdentifiers

struct DownloadItem: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, resolving, downloading, cancelling, completed, failed, stopped, cancelled, interrupted
        var label: String {
            switch self {
            case .queued: return "等待下载"
            case .resolving: return "正在解析"
            case .downloading: return "正在下载"
            case .cancelling: return "正在取消"
            case .completed: return "下载完成"
            case .failed: return "下载失败"
            case .stopped: return "已停止"
            case .cancelled: return "已取消"
            case .interrupted: return "上次下载已中断"
            }
        }
        var isActive: Bool { self == .resolving || self == .downloading || self == .cancelling }
        var canRetry: Bool { self == .failed || self == .stopped || self == .cancelled || self == .interrupted }
    }
    var id = UUID()
    var source: String
    var title: String
    var platform: String
    var thumbnailURL: URL?
    var quality: String
    var directory: URL
    var createdAt = Date()
    var state: State = .queued
    var fraction: Double?
    var detail = ""
    var fileURL: URL?
    var error: String?
}

enum AppTools {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0" }
    /// Local acceptance tests use an isolated history, output folder and cache.
    /// Normal launches retain the existing application-support paths and defaults.
    static var testDataDirectory: URL? {
        guard let custom = ProcessInfo.processInfo.environment["FEATHER_TEST_DATA"], !custom.isEmpty else { return nil }
        return URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
    }
    static var preferences: UserDefaults? { testDataDirectory == nil ? .standard : nil }
    static var supportDirectory: URL {
        testDataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FeatherDownloader", isDirectory: true)
    }
    static var downloadsDirectory: URL {
        testDataDirectory?.appendingPathComponent("Downloads", isDirectory: true) ??
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent("飞羽下载", isDirectory: true)
    }
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["FEATHER_TOOLS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("tools", isDirectory: true)
    }
    static var paths: ToolPaths {
        ToolPaths(ytDLP: directory.appendingPathComponent("yt-dlp"),
                  ffmpeg: directory.appendingPathComponent("ffmpeg"),
                  deno: directory.appendingPathComponent("deno"))
    }
    static func makeEngine() -> DownloadEngine {
        let cache = (testDataDirectory?.appendingPathComponent("Cache", isDirectory: true) ??
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.featherdownloader.app", isDirectory: true))
            .appendingPathComponent("deno", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return DownloadEngine(tools: paths, environment: ["DENO_DIR": cache.path])
    }
}

protocol DownloadServing: Sendable {
    func resolve(shareText: String, authentication: CookieSource) async throws -> VideoMetadata
    func download(metadata: VideoMetadata, quality: DownloadQuality, directory: URL,
                  authentication: CookieSource, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult
}

extension DownloadEngine: DownloadServing {}

/// Producers replace one value. There is no actor Task allocation per progress event.
final class ProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DownloadProgress?
    private var isClosed = false
    func submit(_ progress: DownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        if !isClosed { latest = progress }
    }
    func take() -> DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        let value = latest
        latest = nil
        return value
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
        latest = nil
    }
}

@MainActor final class ApplicationModel: ObservableObject {
    let subtitleFeature = SubtitleFeature()
    let videoRepairFeature = VideoRepairFeature()
    @Published var shareText = ""
    @Published var quality: DownloadQuality = .best
    @Published var preview: VideoMetadata?
    @Published private(set) var isResolving = false
    @Published private(set) var isCancellingPreview = false
    @Published var previewError: String?
    @Published var items: [DownloadItem] = []
    @Published var destination: URL
    @Published var cookieSource: CookieSource = .none
    @Published var cookieLabel = "不使用登录凭据"
    @Published var showSettings = false
    @Published var showAbout = false
    @Published var selectedSection: SidebarSection = .all
    @Published var notification: String?
    lazy var updater = AppUpdater(model: self)

    /// Include task handles as cancellation can leave native workers cleaning up
    /// after the visible state has changed. Queued downloads must also finish.
    var hasActiveWorkForUpdate: Bool {
        worker != nil || previewTask != nil || pendingPreview != nil || isResolving ||
        activeCount > 0 || subtitleFeature.hasActiveWorkForUpdate || videoRepairFeature.hasActiveWorkForUpdate
    }

    enum SidebarSection: String, CaseIterable {
        case all = "全部任务", active = "下载中", completed = "已完成", subtitles = "翻译与字幕", videoRepair = "AI 视频修复"
        var icon: String {
            switch self {
            case .all: return "square.stack.3d.up"
            case .active: return "arrow.down.circle"
            case .completed: return "checkmark.circle"
            case .subtitles: return "captions.bubble"
            case .videoRepair: return "wand.and.stars"
            }
        }
    }

    private let engine: any DownloadServing
    private let historyURL: URL
    private let completionStore: DownloadCompletionStore
    private var worker: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var activeID: UUID?
    private var metadataCache: [UUID: VideoMetadata] = [:]
    private var authenticationCache: [UUID: CookieSource] = [:]
    private struct PreviewRequest {
        let id = UUID()
        let input: String
        let authentication: CookieSource
    }
    private var pendingPreview: PreviewRequest?
    private var previewID: UUID?
    private var isWorkerResolving = false
    private var progressMailbox: ProgressMailbox?
    private var progressTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(engine: any DownloadServing = AppTools.makeEngine(), historyFile: URL? = nil) {
        self.engine = engine
        destination = AppTools.preferences?.url(forKey: "downloadDirectory") ?? AppTools.downloadsDirectory
        historyURL = historyFile ?? AppTools.supportDirectory.appendingPathComponent("history.json")
        completionStore = DownloadCompletionStore(historyURL: historyURL)
        let receipts = completionStore
        var recoveredCompletion = false
        var upgradedFailureMessage = false
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved.map { item in
                var restored = item
                if item.state != .completed, let file = receipts.recover(id: item.id, source: item.source) {
                    restored.state = .completed
                    restored.fileURL = file
                    restored.fraction = 1
                    restored.error = nil
                    restored.detail = "已保存到 \(file.deletingLastPathComponent().lastPathComponent)"
                    recoveredCompletion = true
                } else if restored.state.isActive || restored.state == .queued {
                    restored.state = .interrupted
                    restored.detail = "点击重试，继续下载"
                    restored.fraction = nil
                }
                if restored.state == .failed, restored.platform == "X",
                   restored.error == "视频不可用，可能已删除、设为私密或限制了访问地区。" {
                    restored.error = DownloadError.xMediaVisibilityMessage
                    upgradedFailureMessage = true
                }
                return restored
            }
        }
        if recoveredCompletion || upgradedFailureMessage { persist() }
    }

    deinit {
        previewTask?.cancel()
        worker?.cancel()
        progressTask?.cancel()
        progressMailbox?.close()
    }

    var extractedURLs: [URL] { ShareLinkParser.urls(in: shareText) }
    var activeCount: Int { items.filter { $0.state.isActive || $0.state == .queued }.count }
    var completedCount: Int { items.filter { $0.state == .completed }.count }
    var visibleItems: [DownloadItem] {
        items.filter { item in
            switch selectedSection {
            case .all: return true
            case .active: return item.state.isActive || item.state == .queued
            case .completed: return item.state == .completed
            case .subtitles, .videoRepair: return false
            }
        }
    }
    var hasInput: Bool { !shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            cancelPreview()
            shareText = text
            preview = nil
            previewError = nil
        }
    }

    func newDownload() {
        cancelPreview()
        selectedSection = .all
        shareText = ""
        preview = nil
        previewError = nil
    }

    func resolvePreview() {
        guard hasInput, !isShuttingDown else { return }
        // Repeated menu/keyboard requests replace one waiting request, never spawn another
        // browser while a previous preview or worker resolver is still cleaning up.
        pendingPreview = PreviewRequest(input: shareText, authentication: cookieSource)
        preview = nil
        previewError = nil
        isResolving = true
        if let task = previewTask {
            isCancellingPreview = true
            task.cancel()
        } else {
            startPendingPreview()
        }
    }

    private func startPendingPreview() {
        guard !isShuttingDown, !isWorkerResolving, previewTask == nil, let request = pendingPreview else { return }
        pendingPreview = nil
        previewID = request.id
        isResolving = true
        isCancellingPreview = false
        let engine = self.engine
        previewTask = Task { [weak self] in
            let outcome: Result<VideoMetadata, Error>
            do {
                let metadata = try await engine.resolve(shareText: request.input, authentication: request.authentication)
                try Task.checkCancellation()
                outcome = .success(metadata)
            } catch { outcome = .failure(error) }
            // The model is not retained across the engine await.
            self?.finishPreview(request.id, outcome: outcome, cancelled: Task.isCancelled)
        }
    }

    private func finishPreview(_ id: UUID, outcome: Result<VideoMetadata, Error>, cancelled: Bool) {
        guard previewID == id else { return }
        previewTask = nil
        previewID = nil
        if !cancelled, !isShuttingDown {
            switch outcome {
            case .success(let metadata): preview = metadata
            case .failure(let error): previewError = Self.message(for: error)
            }
        }
        isCancellingPreview = false
        isResolving = pendingPreview != nil && !isShuttingDown
        if !isShuttingDown {
            startPendingPreview()
            startNext()
        }
    }

    func shutdown() async {
        isShuttingDown = true
        pendingPreview = nil
        let preview = previewTask
        let download = worker
        preview?.cancel()
        download?.cancel()
        stopProgressUpdates()
        await subtitleFeature.shutdown()
        await videoRepairFeature.shutdown()
        await preview?.value
        await download?.value
        persist()
    }

    func openSubtitles(for item: DownloadItem) {
        guard let file = item.fileURL, FileManager.default.fileExists(atPath: file.path) else {
            notification = "这个视频已被移动或删除，请重新选择本地文件。"
            return
        }
        guard #available(macOS 26, *) else {
            notification = "视频翻译和字幕功能需要 macOS 26 或更新版本。"
            return
        }
        subtitleFeature.model.selectFile(file)
        selectedSection = .subtitles
    }

    func openVideoRepair(for item: DownloadItem) {
        guard let file = item.fileURL, FileManager.default.fileExists(atPath: file.path) else {
            notification = "这个视频已被移动或删除，请重新选择本地文件。"
            return
        }
        guard !videoRepairFeature.model.isBusy else {
            selectedSection = .videoRepair
            return
        }
        videoRepairFeature.model.selectFile(file)
        selectedSection = .videoRepair
    }

    func cancelPreview() {
        pendingPreview = nil
        if let task = previewTask {
            isCancellingPreview = true
            task.cancel()
            // Keep the handle until cleanup finishes. Allowing a replacement immediately
            // here previously let cancelled-but-live browser resolvers accumulate.
        } else {
            isResolving = false
            isCancellingPreview = false
        }
    }

    func enqueueInput() {
        let links = extractedURLs
        guard !links.isEmpty else {
            previewError = "没有找到有效链接。请粘贴包含 https:// 或 http:// 的视频分享内容。"
            return
        }
        cancelPreview()
        for url in links {
            let cached = preview.flatMap { metadata in metadata.sourceURL == url ? metadata : nil }
            enqueue(url: url, metadata: cached)
        }
        shareText = ""
        preview = nil
        previewError = nil
        selectedSection = .all
        persist()
        startNext()
    }

    func enqueuePreview() {
        guard let preview else { return }
        cancelPreview()
        enqueue(url: preview.sourceURL, metadata: preview)
        self.preview = nil
        shareText = ""
        selectedSection = .all
        persist()
        startNext()
    }

    private func enqueue(url: URL, metadata: VideoMetadata?) {
        var item = DownloadItem(source: url.absoluteString,
                                title: metadata?.title ?? "等待读取视频信息…",
                                platform: Self.platformName(for: url),
                                thumbnailURL: metadata?.thumbnailURL,
                                quality: quality.rawValue,
                                directory: destination)
        item.detail = "下载到 \(destination.lastPathComponent)"
        items.insert(item, at: 0)
        if let metadata { metadataCache[item.id] = metadata }
        authenticationCache[item.id] = cookieSource
    }

    private func startNext() {
        guard !isShuttingDown, !isResolving, worker == nil,
              let item = items.reversed().first(where: { $0.state == .queued }) else { return }
        let id = item.id
        activeID = id
        isWorkerResolving = true
        update(id) { $0.state = .resolving; $0.detail = "正在获取视频信息…"; $0.error = nil; $0.fraction = nil }
        let auth = authenticationCache[id] ?? .none
        let selectedQuality = DownloadQuality(rawValue: item.quality) ?? .best
        let cached = metadataCache[id]
        let engine = self.engine
        let receipts = completionStore
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let metadata: VideoMetadata
                if let cached { metadata = cached }
                else { metadata = try await engine.resolve(shareText: item.source, authentication: auth) }
                try Task.checkCancellation()
                await self?.workerResolved(id, metadata: metadata)
                let mailbox = ProgressMailbox()
                await self?.startProgressUpdates(id, mailbox: mailbox)
                defer { mailbox.close() }
                let result = try await engine.download(metadata: metadata, quality: selectedQuality, directory: item.directory,
                                                       authentication: auth, onProgress: { mailbox.submit($0) })
                // Persist the completed result before waiting for the UI actor. A slow
                // or interrupted window must not lose an already saved video's state.
                // A successful engine return commits completion even when cancellation
                // arrives at the same moment; cancelling cannot undo the saved file.
                var receiptError: String?
                do { try receipts.record(id: id, source: item.source, result: result) }
                catch { receiptError = error.localizedDescription }
                await self?.workerCompleted(id, result: result, receiptError: receiptError)
            } catch {
                await self?.workerFailed(id, error: error, cancelled: Task.isCancelled)
            }
            await self?.finishWorker(id)
        }
    }

    private func workerCompleted(_ id: UUID, result: DownloadResult, receiptError: String?) {
        guard activeID == id else { return }
        update(id) {
            $0.state = .completed
            $0.fileURL = result.fileURL
            $0.fraction = 1
            $0.detail = "已保存到 \(result.fileURL.deletingLastPathComponent().lastPathComponent)"
            $0.error = nil
        }
        if let receiptError { notification = "视频已保存，但完成凭据未能写入：\(receiptError)" }
    }

    private func workerFailed(_ id: UUID, error: Error, cancelled: Bool) {
        guard activeID == id else { return }
        if cancelled {
            update(id) { $0.state = .cancelled; $0.detail = "下载已取消"; $0.fraction = nil }
        } else {
            update(id) { $0.state = Self.wasStopped(error) ? .stopped : .failed; $0.error = Self.message(for: error); $0.detail = "任务已结束，不会自动重试；需要时点击重试"; $0.fraction = nil }
        }
    }

    private func workerResolved(_ id: UUID, metadata: VideoMetadata) {
        guard activeID == id else { return }
        isWorkerResolving = false
        update(id) { $0.title = metadata.title; $0.thumbnailURL = metadata.thumbnailURL; $0.state = .downloading; $0.detail = "正在准备下载…" }
        persist()
        startPendingPreview()
    }

    private func finishWorker(_ id: UUID) {
        guard activeID == id else { return }
        stopProgressUpdates()
        metadataCache[id] = nil
        authenticationCache[id] = nil
        activeID = nil
        isWorkerResolving = false
        worker = nil
        persist()
        startPendingPreview()
        startNext()
    }

    private func startProgressUpdates(_ id: UUID, mailbox: ProgressMailbox) {
        stopProgressUpdates()
        progressMailbox = mailbox
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { break }
                guard !Task.isCancelled else { break }
                guard let self else { mailbox.close(); break }
                if let progress = mailbox.take() { self.receive(progress, for: id) }
            }
        }
    }

    private func stopProgressUpdates() {
        progressMailbox?.close()
        progressMailbox = nil
        progressTask?.cancel()
        progressTask = nil
    }

    private func receive(_ progress: DownloadProgress, for id: UUID) {
        guard activeID == id, let item = items.first(where: { $0.id == id }), item.state == .downloading else { return }
        var details: [String] = []
        if let bytes = progress.downloadedBytes { details.append(Self.bytes(bytes)) }
        if let total = progress.totalBytes { details.append("共 \(Self.bytes(total))") }
        if let speed = progress.speedBytesPerSecond, speed.isFinite, speed > 0, speed < Double(Int64.max) { details.append("\(Self.bytes(Int64(speed)))/s") }
        if let eta = progress.etaSeconds, eta.isFinite, eta > 0 { details.append("剩余 \(Self.duration(eta))") }
        update(id) {
            $0.fraction = progress.fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            $0.detail = details.isEmpty ? Self.progressLabel(progress.status) : details.joined(separator: " · ")
        }
    }

    func cancel(_ id: UUID) {
        if activeID == id {
            update(id) { $0.state = .cancelling; $0.detail = "正在停止下载…"; $0.fraction = nil }
            stopProgressUpdates()
            worker?.cancel()
        } else {
            update(id) { $0.state = .cancelled; $0.detail = "已移出等待队列"; $0.fraction = nil }
            authenticationCache[id] = nil
            metadataCache[id] = nil
        }
        persist()
    }

    func retry(_ id: UUID) {
        guard activeID != id, let item = items.first(where: { $0.id == id }), item.state.canRetry else { return }
        update(id) { $0.state = .queued; $0.error = nil; $0.detail = "等待重新下载"; $0.fraction = nil; $0.quality = quality.rawValue; $0.directory = destination }
        authenticationCache[id] = cookieSource
        persist()
        startNext()
    }

    func remove(_ id: UUID) {
        guard activeID != id else { return }
        items.removeAll { $0.id == id }
        completionStore.remove(id: id)
        metadataCache[id] = nil
        authenticationCache[id] = nil
        persist()
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { notification = "这个文件已被移动或删除。下载记录仍保留在本机。" }
    }

    func openDownloads() {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            NSWorkspace.shared.open(destination)
        } catch { notification = error.localizedDescription }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择视频保存位置"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        if panel.runModal() == .OK, let chosen = panel.url {
            destination = chosen
            AppTools.preferences?.set(chosen, forKey: "downloadDirectory")
        }
    }

    func setNoCookies() { cookieSource = .none; cookieLabel = "不使用登录凭据" }
    func setBrowser(_ browser: Browser) {
        cookieSource = .browser(browser)
        cookieLabel = "使用 \(browser.displayName) 登录状态"
    }
    func importCookies() {
        let panel = NSOpenPanel()
        panel.title = "导入 Netscape 格式 cookies 文件"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            cookieSource = .netscapeFile(url)
            cookieLabel = "cookies 文件：\(url.lastPathComponent)"
        }
    }

    private func update(_ id: UUID, _ mutation: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: historyURL, options: .atomic)
        } catch { notification = "下载记录保存失败：\(error.localizedDescription)" }
    }

    static func platformName(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host.contains("bilibili") || host == "b23.tv" { return "哔哩哔哩" }
        if host.contains("youtube") || host == "youtu.be" { return "YouTube" }
        if host.contains("douyin") || host.contains("iesdouyin") { return "抖音" }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "小红书" }
        if host.contains("kuaishou") || host.contains("kwai") { return "快手" }
        if host.contains("twitter") || host == "x.com" { return "X" }
        if host.contains("instagram") { return "Instagram" }
        if host.contains("facebook") || host == "fb.watch" { return "Facebook" }
        if host.contains("vimeo") { return "Vimeo" }
        if host.contains("weibo") { return "微博" }
        return host.isEmpty ? "视频链接" : host
    }
    static func progressLabel(_ status: String) -> String {
        switch status {
        case "downloading": return "正在接收视频数据…"
        case "finished": return "正在整理并保存文件…"
        default: return "正在处理文件…"
        }
    }
    static func wasStopped(_ error: Error) -> Bool {
        guard let error = error as? DownloadError else { return false }
        switch error {
        case .stalled, .memoryLimitExceeded, .helperDidNotExit, .timedOut, .outputTooLarge: return true
        default: return false
        }
    }
    static func message(for error: Error) -> String { error.localizedDescription }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 31_536_000, seconds < Double(Int.max) else { return "--:--" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
