import AppKit
import DownloadCore
import ImageIO
import SwiftUI

private let featherBlue = Color(red: 0.16, green: 0.39, blue: 0.86)
private let featherInk = Color(red: 0.13, green: 0.17, blue: 0.23)

struct FeatherRootView: View {
    @EnvironmentObject private var model: ApplicationModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.selectedSection == .subtitles {
                            if #available(macOS 26, *) {
                                SubtitleWorkspaceView(model: model.subtitleFeature.model, downloads: model.items)
                            } else {
                                ContentUnavailableSubtitleView()
                            }
                        } else {
                            if model.selectedSection == .all {
                                composer
                                if let preview = model.preview { previewCard(preview) }
                            }
                            queue
                        }
                    }
                    .padding(28)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 650)
        .tint(featherBlue)
        .sheet(isPresented: $model.showSettings) { FeatherSettingsView().environmentObject(model).preferredColorScheme(.light) }
        .sheet(isPresented: $model.showAbout) { FeatherAboutView().preferredColorScheme(.light) }
        .alert("飞羽下载", isPresented: Binding(get: { model.notification != nil }, set: { if !$0 { model.notification = nil } })) {
            Button("好", role: .cancel) { model.notification = nil }
        } message: { Text(model.notification ?? "") }
        .preferredColorScheme(.light)
        .background {
            if #available(macOS 26, *) {
                TranslationPreparationView(coordinator: model.subtitleFeature.model.preparation)
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(featherBlue.gradient)
                    Image(systemName: "arrow.down.to.line.compact").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("飞羽下载").font(.system(size: 18, weight: .semibold)).foregroundStyle(featherInk)
                    Text("FEATHER").font(.system(size: 9, weight: .medium, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32).padding(.bottom, 38).padding(.horizontal, 21)

            Text("工作区").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 10)
            ForEach(ApplicationModel.SidebarSection.allCases, id: \.self) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon).frame(width: 19).font(.system(size: 15))
                        Text(section.rawValue).font(.system(size: 13, weight: model.selectedSection == section ? .semibold : .regular))
                        Spacer(minLength: 0)
                        let count = count(for: section)
                        if count > 0 { Text("\(count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(model.selectedSection == section ? featherBlue : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(model.selectedSection == section ? featherBlue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("安心保存在本机", systemImage: "internaldrive")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(featherInk.opacity(0.75))
                Text("下载文件和历史记录均保存在你的 Mac。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .padding(16)
            Button { model.showAbout = true } label: {
                HStack { Text("关于飞羽"); Spacer(); Text(AppTools.version).monospacedDigit() }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.horizontal, 23).padding(.bottom, 20)
        }
        .frame(width: 192)
        .background(Color(red: 0.94, green: 0.955, blue: 0.975))
    }

    private func count(for section: ApplicationModel.SidebarSection) -> Int {
        switch section {
        case .all: return model.items.count
        case .active: return model.activeCount
        case .completed: return model.completedCount
        case .subtitles: return 0
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selectedSection == .all ? "把喜欢的视频，留在手边。" : model.selectedSection.rawValue)
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(featherInk)
                Text(model.selectedSection == .all ? "粘贴分享内容，让下载变得简单。" : model.selectedSection == .subtitles ? "选好语言，让视频更容易看懂。" : "视频文件与下载记录，随时可查。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.openDownloads() } label: { Image(systemName: "folder").font(.system(size: 16)) }
                .buttonStyle(.borderless).help("打开保存文件夹").accessibilityLabel("打开保存文件夹")
            Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 16)) }
                .buttonStyle(.borderless).padding(.leading, 10).help("下载设置").accessibilityLabel("下载设置")
        }.padding(.horizontal, 29).padding(.vertical, 24)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("新建下载", systemImage: "link").font(.system(size: 14, weight: .semibold)).foregroundStyle(featherInk)
                Spacer()
                Text(model.extractedURLs.count > 1 ? "已识别 \(model.extractedURLs.count) 个链接 · 预览显示首个视频" : "支持完整分享文案与批量链接").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.shareText.isEmpty {
                    Text("粘贴视频链接，或直接粘贴完整分享文案…\n支持 http / https 链接")
                        .font(.system(size: 13)).foregroundStyle(.tertiary).lineSpacing(7)
                        .padding(.horizontal, 7).padding(.vertical, 9).allowsHitTesting(false)
                }
                TextEditor(text: $model.shareText)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 110)
                    .padding(3)
                    .accessibilityLabel("视频链接或分享文案")
            }
            .padding(7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.085), lineWidth: 1))

            HStack(spacing: 10) {
                Button { model.paste() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.bordered).controlSize(.large)
                    .help("粘贴剪贴板中的链接或完整分享文案")
                Spacer(minLength: 8)
                if model.isResolving {
                    ProgressView().controlSize(.small).padding(.trailing, 2)
                    Button(model.isCancellingPreview ? "正在停止解析…" : "取消解析") { DispatchQueue.main.async { model.cancelPreview() } }
                        .buttonStyle(.bordered).controlSize(.large).disabled(model.isCancellingPreview)
                } else {
                    Button("解析预览") { DispatchQueue.main.async { model.resolvePreview() } }
                        .buttonStyle(.bordered).controlSize(.large).disabled(!model.hasInput)
                }
                Button { DispatchQueue.main.async { model.enqueueInput() } } label: {
                    Label(model.extractedURLs.count > 1 ? "添加 \(model.extractedURLs.count) 个下载" : "加入下载队列", systemImage: "arrow.down")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.hasInput)
            }

            HStack(spacing: 10) {
                Text("下载画质").foregroundStyle(.secondary)
                Picker("下载画质", selection: $model.quality) {
                    ForEach(DownloadQuality.allCases, id: \.self) { value in Text(value.displayName).tag(value) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 138)
                Spacer()
                authenticationMenu
            }.font(.system(size: 11))

            if let error = model.previewError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.black.opacity(0.065)))
    }

    private var authenticationMenu: some View {
        Menu {
            Button("不使用登录凭据") { model.setNoCookies() }
            Divider()
            ForEach(Browser.allCases, id: \.self) { browser in
                Button("使用 \(browser.displayName) 登录状态…") { model.setBrowser(browser) }
            }
            Divider()
            Button("导入 cookies 文件…") { model.importCookies() }
            Button("查看登录说明…") { model.showSettings = true }
        } label: {
            Label(model.cookieLabel, systemImage: "person.crop.circle")
                .lineLimit(1).frame(maxWidth: 245, alignment: .trailing)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .help("仅在你主动选择后，读取指定浏览器的登录状态或 cookies 文件")
    }

    private func previewCard(_ metadata: VideoMetadata) -> some View {
        HStack(alignment: .top, spacing: 15) {
            VideoThumbnail(url: metadata.thumbnailURL).frame(width: 152, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text(metadata.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(featherInk).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(ApplicationModel.platformName(for: metadata.sourceURL))
                    if let duration = metadata.duration { Text("·"); Text(ApplicationModel.duration(duration)).monospacedDigit() }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text(metadata.availableHeights.isEmpty ? "画质由源站提供，下载时自动匹配" : "可用画质：" + metadata.availableHeights.prefix(6).map { "\($0)p" }.joined(separator: " / "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 1)
                HStack {
                    Text("按所选画质上限自动匹配").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("下载这个视频") { DispatchQueue.main.async { model.enqueuePreview() } }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
            .background(featherBlue.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(featherBlue.opacity(0.12)))
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.selectedSection == .all ? "下载队列" : model.selectedSection.rawValue)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(featherInk)
                Text("\(model.visibleItems.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.activeCount > 0 {
                    HStack(spacing: 5) { Circle().fill(featherBlue).frame(width: 5, height: 5); Text("\(model.activeCount) 个任务进行中") }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.selectedSection == .completed ? "checkmark.circle" : "tray.and.arrow.down")
                        .font(.system(size: 29, weight: .light)).foregroundStyle(featherBlue.opacity(0.45))
                    Text(model.selectedSection == .completed ? "完成的视频会出现在这里" : model.selectedSection == .active ? "现在没有进行中的下载" : "你的下一段收藏，从一个链接开始")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.selectedSection == .all { Text("支持完整分享文案，也支持多个视频链接。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 35)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.black.opacity(0.07)))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.visibleItems) { item in DownloadRow(item: item).environmentObject(model) }
                }
            }
            if model.selectedSection == .all {
                VStack(alignment: .leading, spacing: 5) {
                    Text("B站  ·  YouTube  ·  抖音  ·  快手  ·  TikTok  ·  小红书  ·  更多")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text("平台适配由内置引擎提供，以实际解析结果为准。部分平台需要登录，受限内容可能无法下载。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text("保存到").foregroundStyle(.tertiary)
            Button { model.chooseDestination() } label: {
                Text(model.destination.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .lineLimit(1).truncationMode(.middle)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("更改保存位置")
            Spacer(minLength: 12)
            Text("飞羽下载 \(AppTools.version)").foregroundStyle(.tertiary)
        }.font(.system(size: 10)).padding(.horizontal, 28).padding(.vertical, 12)
            .background(.bar)
    }
}

/// One bounded transfer owns its delegate/session until a single terminal callback.
/// Cancellation resumes the awaiter and breaks the session/delegate cycle immediately.
private final class ThumbnailTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let byteLimit = 4 * 1_024 * 1_024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false

    func load(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 12
                configuration.timeoutIntervalForResource = 20
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= Int64(Self.byteLimit),
              response.mimeType?.hasPrefix("image/") != false else {
            completionHandler(.cancel)
            finish(.failure(URLError(.cannotDecodeContentData)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= Self.byteLimit - buffer.count else {
            lock.unlock()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffer
        lock.unlock()
        if let error { finish(.failure(error)) }
        else { finish(.success(data)) }
    }

    private func finish(_ outcome: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        buffer = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: outcome)
    }
}

@MainActor private final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private final class Job {
        let id = UUID()
        var task: Task<Void, Never>?
        var subscribers: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
    }
    private var images: [URL: (image: NSImage, cost: Int)] = [:]
    private var imageOrder: [URL] = []
    private var imageCost = 0
    private var failures: [URL: Date] = [:]
    private var failureOrder: [URL] = []
    private let imageCostLimit = 16 * 1_024 * 1_024
    private var jobs: [URL: Job] = [:]
    private var activeTransfers = 0
    private var permitOrder: [UUID] = []
    private var permitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let transferLimit = 3
    private let jobLimit = 24
    private init() {}

    private func cache(_ image: NSImage, for url: URL) {
        // Conservative accounting also allows room for a second drawing representation.
        let cost = max(1, Int(image.size.width * image.size.height) * 16)
        if let old = images.removeValue(forKey: url) { imageCost -= old.cost }
        imageOrder.removeAll { $0 == url }
        while (imageCost + cost > imageCostLimit || images.count >= 48), let oldest = imageOrder.first {
            imageOrder.removeFirst()
            if let old = images.removeValue(forKey: oldest) { imageCost -= old.cost }
        }
        guard cost <= imageCostLimit else { return }
        images[url] = (image, cost)
        imageOrder.append(url)
        imageCost += cost
    }

    private func cacheFailure(_ url: URL) {
        failureOrder.removeAll { $0 == url }
        while failures.count >= 64, let oldest = failureOrder.first {
            failureOrder.removeFirst()
            failures[oldest] = nil
        }
        failures[url] = Date()
        failureOrder.append(url)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = images[url] {
            imageOrder.removeAll { $0 == url }; imageOrder.append(url)
            return cached.image
        }
        if let failed = failures[url], Date().timeIntervalSince(failed) < 60 { return nil }
        let subscriber = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let job = jobs[url] {
                    guard job.subscribers.count < 64 else { continuation.resume(returning: nil); return }
                    job.subscribers[subscriber] = continuation
                    return
                }
                // History is preserved. Off-screen/overflow covers keep a placeholder
                // instead of creating unbounded network/decode work.
                guard jobs.count < jobLimit else { continuation.resume(returning: nil); return }
                let job = Job()
                job.subscribers[subscriber] = continuation
                jobs[url] = job
                job.task = Task { [weak self] in
                    guard let self else { return }
                    defer { job.task = nil }
                    let granted = await acquirePermit(job.id)
                    guard granted else { complete(url, id: job.id, image: nil); return }
                    defer { releasePermit() }
                    guard !Task.isCancelled else { complete(url, id: job.id, image: nil); return }
                    let image = await loadImage(url)
                    complete(url, id: job.id, image: Task.isCancelled ? nil : image)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelSubscriber(subscriber, for: url) }
        })
    }

    private func cancelSubscriber(_ subscriber: UUID, for url: URL) {
        guard let job = jobs[url], let continuation = job.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(returning: nil)
        if job.subscribers.isEmpty {
            jobs[url] = nil
            job.task?.cancel()
        }
    }

    private func complete(_ url: URL, id: UUID, image: NSImage?) {
        guard let job = jobs[url], job.id == id else { return }
        jobs[url] = nil
        job.task = nil
        for continuation in job.subscribers.values { continuation.resume(returning: image) }
        job.subscribers.removeAll()
    }

    private func acquirePermit(_ id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeTransfers < transferLimit { activeTransfers += 1; return true }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, permitOrder.count < jobLimit else { continuation.resume(returning: false); return }
                permitOrder.append(id)
                permitWaiters[id] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.permitWaiters.removeValue(forKey: id) else { return }
                self.permitOrder.removeAll { $0 == id }
                continuation.resume(returning: false)
            }
        })
    }

    private func releasePermit() {
        while let next = permitOrder.first {
            permitOrder.removeFirst()
            if let continuation = permitWaiters.removeValue(forKey: next) {
                continuation.resume(returning: true)
                return
            }
        }
        activeTransfers = max(0, activeTransfers - 1)
    }

    private func loadImage(_ url: URL) async -> NSImage? {
        do {
            let data = try await ThumbnailTransfer().load(url)
            try Task.checkCancellation()
            let image: NSImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0, width <= 8_192, height <= 8_192,
                      width <= 16_000_000 / height,
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            try Task.checkCancellation()
            if let image {
                cache(image, for: url)
            } else { cacheFailure(url) }
            return image
        } catch {
            if !Task.isCancelled { cacheFailure(url) }
            return nil
        }
    }
}

@MainActor private final class ThumbnailViewState: ObservableObject {
    @Published var image: NSImage?
}

struct VideoThumbnail: View {
    let url: URL?
    @StateObject private var thumbnail = ThumbnailViewState()
    private var imageURL: URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            return components.url
        }
        return url
    }
    var body: some View {
        ZStack {
            if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFill() }
            else { Color(red: 0.90, green: 0.93, blue: 0.97); Image(systemName: "play.rectangle").font(.system(size: 23, weight: .light)).foregroundStyle(featherBlue.opacity(0.5)) }
        }
        .clipped()
        .task(id: imageURL) {
            thumbnail.image = nil
            guard let url = imageURL else { return }
            let result = await ThumbnailStore.shared.image(for: url)
            guard !Task.isCancelled else { return }
            thumbnail.image = result
        }
        .onDisappear { thumbnail.image = nil }
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var model: ApplicationModel
    let item: DownloadItem
    private var stateColor: Color {
        switch item.state {
        case .completed: return Color(red: 0.19, green: 0.57, blue: 0.38)
        case .failed, .stopped, .interrupted: return .orange
        case .downloading, .resolving, .cancelling: return featherBlue
        default: return .secondary
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VideoThumbnail(url: item.thumbnailURL).frame(width: 86, height: 57).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(featherInk).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(item.state.label).font(.system(size: 10)).foregroundStyle(stateColor).fixedSize()
                }
                HStack(spacing: 7) {
                    Text(item.platform)
                    Text("·")
                    Text((DownloadQuality(rawValue: item.quality) ?? .best).displayName)
                    Spacer(minLength: 0)
                    if item.state == .downloading, let fraction = item.fraction { Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(featherBlue) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if item.state.isActive {
                    if let fraction = item.fraction { ProgressView(value: fraction).progressViewStyle(.linear).tint(featherBlue) }
                    else { ProgressView().progressViewStyle(.linear).tint(featherBlue) }
                }
                if let error = item.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            VStack(spacing: 9) {
                if item.state == .completed {
                    Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass") }.help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                    Button { DispatchQueue.main.async { model.openSubtitles(for: item) } } label: { Image(systemName: "captions.bubble") }
                        .help("翻译并添加字幕").accessibilityLabel("翻译并添加字幕")
                } else if item.state.canRetry {
                    // Leave the native button transaction before changing this row's
                    // structure. Updating selectable text and controls inside AXPress
                    // can otherwise trap macOS SwiftUI in repeated layout work.
                    Button { DispatchQueue.main.async { model.retry(item.id) } } label: { Image(systemName: "arrow.clockwise") }.help("使用当前画质、目录和登录设置重试").accessibilityLabel("重试下载")
                } else {
                    Button { DispatchQueue.main.async { model.cancel(item.id) } } label: { Image(systemName: "xmark") }.help("取消下载").accessibilityLabel("取消下载").disabled(item.state == .cancelling)
                }
            }.buttonStyle(.borderless).font(.system(size: 13)).frame(width: 22).padding(.top, 3)
        }.padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.black.opacity(0.055)))
            .contextMenu {
                Button("复制视频标题") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.title, forType: .string) }
                Button("复制原始链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.source, forType: .string) }
                if let error = item.error { Button("复制错误信息") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string) } }
                if item.state == .completed { Button("在 Finder 中显示") { model.reveal(item) } }
                if item.state == .completed { Button("翻译并添加字幕") { DispatchQueue.main.async { model.openSubtitles(for: item) } } }
                if item.state.canRetry { Button("重试下载") { DispatchQueue.main.async { model.retry(item.id) } } }
                if !item.state.isActive && item.state != .queued { Button("移除记录") { model.remove(item.id) } }
            }
    }
}

struct FeatherSettingsView: View {
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack { Text("下载设置").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            VStack(alignment: .leading, spacing: 11) {
                Label("保存位置", systemImage: "folder").font(.system(size: 13, weight: .semibold))
                HStack { Text(model.destination.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); Button("更改…") { model.chooseDestination() } }
                Text("新建和重试任务使用此位置；队列中的其他任务保留原位置。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label("登录凭据", systemImage: "person.crop.circle").font(.system(size: 13, weight: .semibold))
                Text("部分平台需要你已登录的浏览器会话。只有主动选择后，下载引擎才会读取指定浏览器的 cookies；macOS 可能要求授权钥匙串或文件访问。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                HStack {
                    Text(model.cookieLabel).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer()
                    Menu("选择浏览器") {
                        ForEach(Browser.allCases, id: \.self) { browser in Button(browser.displayName) { model.setBrowser(browser) } }
                    }.fixedSize()
                }
                HStack {
                    Button("不使用登录凭据") { model.setNoCookies() }
                    Button("导入 cookies 文件…") { model.importCookies() }
                }
                Text("也可导入 Netscape 格式的 cookies.txt 文件。凭据只传给本机下载引擎，飞羽不会上传它们；每次启动默认不使用登录凭据。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }
            Divider()
            Text("若解析失败，可检查网络或选择登录凭据后重试。平台的登录、地区和访问条件会影响可下载内容，失败原因会保留在任务中。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(28).frame(width: 560).tint(featherBlue)
    }
}

struct FeatherAboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "arrow.down.to.line.circle.fill").font(.system(size: 53)).foregroundStyle(featherBlue)
            Text("飞羽下载").font(.system(size: 24, weight: .semibold))
            Text("Feather · \(AppTools.version) · Apple silicon · macOS 13+").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("把喜欢的视频，留在手边。") .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("下载与媒体处理由 yt-dlp、FFmpeg 和 Deno 提供。\n本软件独立开发，与直播蜂及视频平台没有关联。")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 17) {
                Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                Link("FFmpeg", destination: URL(string: "https://ffmpeg.org/")!)
                Link("Deno", destination: URL(string: "https://deno.com/")!)
            }.font(.system(size: 11))
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).padding(.top, 8)
        }.padding(34).frame(width: 430).tint(featherBlue)
    }
}

private struct ContentUnavailableSubtitleView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "captions.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("视频翻译需要 macOS 26 或更新版本").font(.headline)
            Text("升级系统后，即可使用本机语音识别、翻译和字幕导出。").font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 300)
    }
}
