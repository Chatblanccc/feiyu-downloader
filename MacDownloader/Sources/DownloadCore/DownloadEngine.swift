import Foundation

public struct DownloadSafetyLimits: Sendable {
    public let preparationTimeout: TimeInterval
    public let inactivityTimeout: TimeInterval
    public let processingTimeout: TimeInterval
    public let totalTimeout: TimeInterval
    public let maximumMemoryBytes: UInt64
    public init(preparationTimeout: TimeInterval = 90, inactivityTimeout: TimeInterval = 60,
                processingTimeout: TimeInterval = 600, totalTimeout: TimeInterval = 90 * 60,
                maximumMemoryBytes: UInt64 = 768 * 1_024 * 1_024) {
        self.preparationTimeout = preparationTimeout; self.inactivityTimeout = inactivityTimeout
        self.processingTimeout = processingTimeout; self.totalTimeout = totalTimeout
        self.maximumMemoryBytes = maximumMemoryBytes
    }
}

public final class DownloadEngine: @unchecked Sendable {
    private let tools: ToolPaths
    private let environment: [String: String]
    private let runner: any ProcessRunning
    private let http: any HTTPFetching
    private let browserResolver: (@Sendable (URL) async throws -> VideoMetadata)?
    private let safetyLimits: DownloadSafetyLimits

    public init(tools: ToolPaths, environment: [String: String] = [:],
                runner: any ProcessRunning = FoundationProcessRunner(),
                http: any HTTPFetching = AnonymousHTTPClient(),
                browserResolver: (@Sendable (URL) async throws -> VideoMetadata)? = nil,
                safetyLimits: DownloadSafetyLimits = DownloadSafetyLimits()) {
        self.tools = tools
        self.environment = environment
        self.runner = runner
        self.http = http
        self.browserResolver = browserResolver
        self.safetyLimits = safetyLimits
    }

    public func resolve(shareText: String, authentication: CookieSource = .none) async throws -> VideoMetadata {
        guard let url = ShareLinkParser.urls(in: shareText).first else { throw DownloadError.noURL }
        try Task.checkCancellation()
        try validateTools()
        if KuaishouAdapter.supports(url) {
            return try await KuaishouAdapter(http: http).resolve(url)
        }
        let auth = try PreparedAuthentication(authentication)
        defer { auth.removeTemporaryFiles() }
        let arguments = commonArguments + auth.arguments + ["--dump-single-json", "--skip-download", "--", url.absoluteString]
        do {
            let result = try await runner.run(command(arguments: arguments, timeout: 90), onOutput: { _ in })
            try check(result)
            try Task.checkCancellation()
            return try autoreleasepool { try Self.decodeMetadata(result.stdout, sourceURL: url) }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard DouyinBrowserAdapter.supports(url) else { throw error }
            // Public-page fallback uses a fresh, non-persistent system browser session.
            if let browserResolver = browserResolver { return try await browserResolver(url) }
            return try await DouyinBrowserAdapter.resolve(url: url)
        }
    }

    public func download(metadata: VideoMetadata, quality: DownloadQuality,
                         directory: URL, authentication: CookieSource = .none,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> DownloadResult {
        try Task.checkCancellation()
        guard !metadata.isLive else { throw DownloadError.liveVideo }
        try validateTools()
        let destination = directory.standardizedFileURL
        guard destination.isFileURL else { throw DownloadError.invalidDirectory }
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { throw DownloadError.invalidDirectory }
        guard FileManager.default.isWritableFile(atPath: destination.path) else { throw DownloadError.invalidDirectory }
        let auth = try PreparedAuthentication(authentication)
        defer { auth.removeTemporaryFiles() }
        let output = StructuredDownloadOutput(onProgress: onProgress)
        var formatSelector = quality.formatSelector
        if metadata.resolvedMediaURL != nil, quality != .audio {
            let maximum = quality == .p720 ? 720 : quality == .p1080 ? 1_080 : Int.max
            if maximum != Int.max && (metadata.availableHeights.first == nil || metadata.availableHeights.first! > maximum) {
                throw DownloadError.processFailed(1, "Requested format is not available")
            }
            // A single direct source has no extractor height tags for yt-dlp's format filter.
            formatSelector = metadata.resolvedAudioURL == nil ? "best" : "bv+ba"
        }
        if metadata.resolvedMediaURL == nil, quality != .audio,
           let host = metadata.sourceURL.host?.lowercased(),
           host == "x.com" || host.hasSuffix(".x.com") ||
           host == "twitter.com" || host.hasSuffix(".twitter.com") {
            let maximum = quality == .p720 ? 720 : quality == .p1080 ? 1_080 : Int.max
            if let height = metadata.availableHeights.first(where: { $0 <= maximum }) {
                // X also offers single-connection MP4s. Prefer parallel HLS at the
                // same requested height, retaining the original selector as fallback.
                let video = "bv[protocol=m3u8_native][height=\(height)]"
                let muxed = "b[protocol=m3u8_native][height=\(height)]"
                formatSelector = video + "+ba[protocol=m3u8_native]/" + muxed + "/" + formatSelector
            }
        }
        let preparedInfo = try PreparedMediaInfo(metadata)
        defer { preparedInfo.removeTemporaryFiles() }
        // Audio post-processing deletes its own downloaded input; use a separate name so it
        // cannot reuse and remove a video that the user downloaded earlier into this folder.
        let outputTemplate = quality == .audio
            ? "%(title).180B [%(id)s] · 音频.%(ext)s"
            : "%(title).180B [%(id)s].%(ext)s"
        var arguments = commonArguments + auth.arguments + [
            "--no-simulate", "--quiet", "--newline", "--progress", "--progress-delta", "0.5",
            // Fetch independent HLS/DASH fragments in parallel. Ordinary HTTP files
            // keep the native downloader, and --continue retains partial downloads.
            "--concurrent-fragments", "8",
            "--progress-template", "download:" + StructuredDownloadOutput.progressPrefix
                + #"{"status":%(progress.status|null)j,"downloaded_bytes":%(progress.downloaded_bytes|null)j,"total_bytes":%(progress.total_bytes|null)j,"total_bytes_estimate":%(progress.total_bytes_estimate|null)j,"speed":%(progress.speed|null)j,"eta":%(progress.eta|null)j,"item":%(info.format_id|null)j}"#,
            "--progress-template", "postprocess:" + StructuredDownloadOutput.progressPrefix
                + #"{"status":%(progress.status|null)j,"postprocessor":%(progress.postprocessor|null)j}"#,
            "--print", "after_move:" + StructuredDownloadOutput.finalPrefix + "%(filepath)j",
            "--no-overwrites", "--continue", "--windows-filenames",
            "--paths", destination.path, "--output", outputTemplate,
            "--format", formatSelector
        ]
        if quality == .audio {
            arguments += ["--extract-audio", "--audio-format", "m4a", "--audio-quality", "0"]
        } else {
            // Mirrors yt-dlp's documented mp4 preset: prefer QuickTime-compatible H.264/AAC,
            // while retaining other codecs when the platform offers no compatible source.
            arguments += ["--merge-output-format", "mp4", "--format-sort", "vcodec:h264,lang,quality,res,fps,hdr:12,acodec:aac"]
        }
        if let infoFile = preparedInfo.infoFile {
            arguments += ["--load-info-json", infoFile.path]
        } else {
            arguments += ["--", metadata.sourceURL.absoluteString]
        }
        let result = try await runner.run(command(arguments: arguments, timeout: safetyLimits.totalTimeout, isDownload: true)) { line in
            output.consume(line.line)
        }
        try check(result)
        // A successful helper exit plus its verified after_move file is the
        // commit point. A later cancellation must not discard the saved result.
        guard let finalURL = output.finalFileURL,
              finalURL.path.hasPrefix(destination.path + "/"),
              FileManager.default.fileExists(atPath: finalURL.path),
              let properties = try? finalURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              properties.isRegularFile == true, (properties.fileSize ?? 0) > 0 else {
            throw DownloadError.missingFinalFile
        }
        return DownloadResult(fileURL: finalURL)
    }

    private var commonArguments: [String] {
        var arguments = [
            "--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-playlist", "--playlist-items", "1",
            "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3",
            "--ffmpeg-location", tools.ffmpeg.deletingLastPathComponent().path,
            "--no-js-runtimes"
        ]
        if let deno = tools.deno { arguments += ["--js-runtimes", "deno:" + deno.path] }
        return arguments
    }

    private func command(arguments: [String], timeout: TimeInterval, isDownload: Bool = false) -> ProcessCommand {
        var env = environment
        let existingPath = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var paths = [tools.ffmpeg.deletingLastPathComponent().path]
        if let deno = tools.deno { paths.append(deno.deletingLastPathComponent().path) }
        env["PATH"] = (paths + [existingPath]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        return ProcessCommand(executable: tools.ytDLP, arguments: arguments, environment: env, timeout: timeout,
                              maximumOutputBytes: isDownload ? 8 * 1_024 * 1_024 : 16 * 1_024 * 1_024,
                              maximumStandardErrorBytes: 512 * 1_024,
                              maximumLineBytes: isDownload ? 16 * 1_024 : 16 * 1_024 * 1_024,
                              captureStandardOutput: !isDownload, maximumMemoryBytes: safetyLimits.maximumMemoryBytes,
                              preparationTimeout: isDownload ? safetyLimits.preparationTimeout : nil,
                              inactivityTimeout: isDownload ? safetyLimits.inactivityTimeout : nil,
                              processingTimeout: isDownload ? safetyLimits.processingTimeout : nil,
                              progressJSONPrefix: isDownload ? StructuredDownloadOutput.progressPrefix : nil)
    }

    private func validateTools() throws {
        for (name, url) in [("yt-dlp", tools.ytDLP), ("FFmpeg", tools.ffmpeg)] {
            guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else { throw DownloadError.missingTool(name) }
        }
        if let deno = tools.deno, !FileManager.default.isExecutableFile(atPath: deno.path) {
            throw DownloadError.missingTool("Deno")
        }
    }

    private func check(_ result: ProcessResult) throws {
        if result.exitCode != 0 {
            throw DownloadError.processFailed(result.exitCode, String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private static func decodeMetadata(_ data: Data, sourceURL: URL) throws -> VideoMetadata {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["entries"] == nil,
              let id = raw["id"] as? String, let title = raw["title"] as? String, !title.isEmpty else {
            throw DownloadError.invalidMetadata
        }
        let isLive = raw["is_live"] as? Bool ?? false
        if isLive { throw DownloadError.liveVideo }
        let formats: [MediaFormat] = (raw["formats"] as? [[String: Any]] ?? []).compactMap { format in
            guard let id = format["format_id"] as? String else { return nil }
            return MediaFormat(id: id, fileExtension: format["ext"] as? String,
                               width: (format["width"] as? NSNumber)?.intValue,
                               height: (format["height"] as? NSNumber)?.intValue,
                               fps: (format["fps"] as? NSNumber)?.doubleValue,
                               fileSize: ((format["filesize"] as? NSNumber) ?? (format["filesize_approx"] as? NSNumber))?.int64Value,
                               hasVideo: (format["vcodec"] as? String).map { $0 != "none" } ?? false,
                               hasAudio: (format["acodec"] as? String).map { $0 != "none" } ?? false,
                               formatNote: format["format_note"] as? String)
        }
        return VideoMetadata(id: id, sourceURL: sourceURL, webpageURL: httpURL(raw["webpage_url"] as? String),
                             title: title, thumbnailURL: httpURL(raw["thumbnail"] as? String),
                             duration: (raw["duration"] as? NSNumber)?.doubleValue,
                             formats: formats, extractor: raw["extractor_key"] as? String ?? raw["extractor"] as? String,
                             isLive: isLive)
    }

    private static func httpURL(_ string: String?) -> URL? {
        guard let string = string, let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Supplies observed media streams through yt-dlp's supported info-json entry point.
/// Signed CDN URLs stay in a private, short-lived file instead of command lines or persisted history.
private struct PreparedMediaInfo {
    let infoFile: URL?
    private let temporaryDirectory: URL?

    init(_ metadata: VideoMetadata) throws {
        guard let video = metadata.resolvedMediaURL else {
            infoFile = nil; temporaryDirectory = nil; return
        }
        let mediaURLs = [video] + (metadata.resolvedAudioURL.map { [$0] } ?? [])
        guard mediaURLs.allSatisfy({ $0.scheme?.lowercased() == "https" || $0.host == "127.0.0.1" }),
              metadata.httpHeaders.allSatisfy({ !$0.key.contains("\n") && !$0.key.contains("\r") && !$0.value.contains("\n") && !$0.value.contains("\r") }) else {
            throw DownloadError.invalidMetadata
        }
        var videoFormat: [String: Any] = ["format_id": "feather-video", "url": video.absoluteString,
                                           "ext": metadata.formats.first?.fileExtension ?? "mp4",
                                           "vcodec": "unknown", "acodec": metadata.resolvedAudioURL == nil ? "unknown" : "none",
                                           "http_headers": metadata.httpHeaders]
        if let format = metadata.formats.first(where: { $0.hasVideo }) {
            if let width = format.width { videoFormat["width"] = width }
            if let height = format.height { videoFormat["height"] = height }
        }
        var formats = [videoFormat]
        if let audio = metadata.resolvedAudioURL {
            formats.append(["format_id": "feather-audio", "url": audio.absoluteString,
                            "ext": "m4a", "vcodec": "none", "acodec": "unknown", "http_headers": metadata.httpHeaders])
        }
        var info: [String: Any] = [
            "id": metadata.id, "title": metadata.title, "webpage_url": metadata.sourceURL.absoluteString,
            "extractor": "FeatherBrowser", "extractor_key": "Generic", "http_headers": metadata.httpHeaders,
            "formats": formats
        ]
        if let duration = metadata.duration { info["duration"] = duration }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherMedia-" + UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("media.info.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: info).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw DownloadError.invalidMetadata
        }
        infoFile = file
        temporaryDirectory = folder
    }

    func removeTemporaryFiles() {
        if let temporaryDirectory = temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

/// Cookie files are copied privately because yt-dlp may update its cookie jar at exit.
private struct PreparedAuthentication {
    let arguments: [String]
    let temporaryDirectory: URL?

    init(_ source: CookieSource) throws {
        switch source {
        case .none:
            arguments = ["--no-cookies", "--no-cookies-from-browser"]
            temporaryDirectory = nil
        case .browser(let browser):
            arguments = ["--no-cookies", "--cookies-from-browser", browser.rawValue]
            temporaryDirectory = nil
        case .netscapeFile(let file):
            guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1_024 * 1_024,
                  let content = try? String(contentsOf: file, encoding: .utf8),
                  content.prefix(1_024).contains("Netscape HTTP Cookie File") || content.prefix(1_024).contains("HTTP Cookie File") else {
                throw DownloadError.invalidCookieFile
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherCookies-" + UUID().uuidString, isDirectory: true)
            let copied = directory.appendingPathComponent("cookies.txt")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                try content.write(to: copied, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copied.path)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw DownloadError.invalidCookieFile
            }
            arguments = ["--no-cookies-from-browser", "--cookies", copied.path]
            temporaryDirectory = directory
        }
    }

    func removeTemporaryFiles() {
        if let temporaryDirectory = temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

/// Only the documented, explicitly requested JSON channels are interpreted.
final class StructuredDownloadOutput: @unchecked Sendable {
    static let progressPrefix = "__FEATHER_PROGRESS__"
    static let finalPrefix = "__FEATHER_FINAL__"
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var finalURL: URL?
    private var lastProgressEmission: TimeInterval = -.infinity
    var finalFileURL: URL? { lock.lock(); defer { lock.unlock() }; return finalURL }

    init(onProgress: @escaping @Sendable (DownloadProgress) -> Void) { self.onProgress = onProgress }

    func consume(_ line: String) {
        guard line.utf8.count <= 8_192 else { return }
        if line.hasPrefix(Self.finalPrefix) {
            guard let data = String(line.dropFirst(Self.finalPrefix.count)).data(using: .utf8),
                  let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/") else { return }
            lock.lock()
            finalURL = URL(fileURLWithPath: path).standardizedFileURL
            lock.unlock()
        } else if line.hasPrefix(Self.progressPrefix) {
            guard let data = String(line.dropFirst(Self.progressPrefix.count)).data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  raw.count <= 9,
                  Set(raw.keys).isSubset(of: ["status", "downloaded_bytes", "total_bytes", "total_bytes_estimate", "speed", "eta", "item", "postprocessor"]) else { return }
            let downloaded = (raw["downloaded_bytes"] as? NSNumber)?.int64Value
            let total = ((raw["total_bytes"] as? NSNumber) ?? (raw["total_bytes_estimate"] as? NSNumber))?.int64Value
            var fraction: Double?
            if let downloaded = downloaded, let total = total, total > 0 {
                fraction = min(1, max(0, Double(downloaded) / Double(total)))
            }
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let shouldEmit = now - lastProgressEmission >= 0.2
            if shouldEmit { lastProgressEmission = now }
            lock.unlock()
            guard shouldEmit else { return }
            onProgress(DownloadProgress(fraction: fraction,
                                        speedBytesPerSecond: (raw["speed"] as? NSNumber)?.doubleValue,
                                        etaSeconds: (raw["eta"] as? NSNumber)?.doubleValue,
                                        downloadedBytes: downloaded, totalBytes: total,
                                        status: raw["status"] as? String ?? "processing"))
        }
    }
}
