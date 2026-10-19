import Foundation

public struct ToolPaths: Sendable {
    public let ytDLP: URL
    public let ffmpeg: URL
    public let deno: URL?

    public init(ytDLP: URL, ffmpeg: URL, deno: URL? = nil) {
        self.ytDLP = ytDLP
        self.ffmpeg = ffmpeg
        self.deno = deno
    }
}

public enum Browser: String, CaseIterable, Codable, Sendable, Identifiable {
    case chrome, safari, edge, firefox
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        }
    }
}

/// `.none` never asks yt-dlp to read a browser or cookie file.
public enum CookieSource: Sendable, Equatable {
    case none
    case browser(Browser)
    case netscapeFile(URL)
}

public enum DownloadQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case best, p1080, p720, audio
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .best: return "最佳画质"
        case .p1080: return "1080p 及以下"
        case .p720: return "720p 及以下"
        case .audio: return "仅音频 · M4A"
        }
    }

    var formatSelector: String {
        switch self {
        case .best: return "bv*+ba/b"
        case .p1080: return "bv*[height<=1080]+ba/b[height<=1080]"
        case .p720: return "bv*[height<=720]+ba/b[height<=720]"
        case .audio: return "ba/b"
        }
    }
}

public struct MediaFormat: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let fileExtension: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let fileSize: Int64?
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let formatNote: String?

    public init(id: String, fileExtension: String? = nil, width: Int? = nil,
                height: Int? = nil, fps: Double? = nil, fileSize: Int64? = nil,
                hasVideo: Bool = true, hasAudio: Bool = true, formatNote: String? = nil) {
        self.id = id
        self.fileExtension = fileExtension
        self.width = width
        self.height = height
        self.fps = fps
        self.fileSize = fileSize
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.formatNote = formatNote
    }
}

public struct VideoMetadata: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    /// The original complete URL, including query parameters, is used to download.
    public let sourceURL: URL
    public let webpageURL: URL?
    public let title: String
    public let thumbnailURL: URL?
    public let duration: Double?
    public let formats: [MediaFormat]
    public let extractor: String?
    public let isLive: Bool
    /// Set only by first-party adapters. This signed URL is kept in memory, never logged.
    public let resolvedMediaURL: URL?
    public let httpHeaders: [String: String]
    public let resolvedAudioURL: URL?
    public var availableHeights: [Int] { Array(Set(formats.compactMap(\.height))).sorted(by: >) }

    public init(id: String, sourceURL: URL, webpageURL: URL? = nil, title: String,
                thumbnailURL: URL? = nil, duration: Double? = nil,
                formats: [MediaFormat] = [], extractor: String? = nil, isLive: Bool = false,
                resolvedMediaURL: URL? = nil, httpHeaders: [String: String] = [:],
                resolvedAudioURL: URL? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.webpageURL = webpageURL
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.formats = formats
        self.extractor = extractor
        self.isLive = isLive
        self.resolvedMediaURL = resolvedMediaURL
        self.httpHeaders = httpHeaders
        self.resolvedAudioURL = resolvedAudioURL
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public let fraction: Double?
    public let speedBytesPerSecond: Double?
    public let etaSeconds: Double?
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    public let status: String

    public init(fraction: Double? = nil, speedBytesPerSecond: Double? = nil,
                etaSeconds: Double? = nil, downloadedBytes: Int64? = nil,
                totalBytes: Int64? = nil, status: String = "downloading") {
        self.fraction = fraction
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.status = status
    }
}

public struct DownloadResult: Sendable, Equatable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
}

public enum DownloadError: Error, LocalizedError, Sendable {
    case noURL
    case missingTool(String)
    case invalidCookieFile
    case timedOut
    case outputTooLarge
    case launchFailed(String)
    case processFailed(Int32, String)
    case invalidMetadata
    case liveVideo
    case missingFinalFile
    case invalidDirectory
    case kuaishouShareLinkRequired
    case stalled
    case memoryLimitExceeded
    case helperDidNotExit

    public static let xMediaVisibilityMessage = "未获取到这条 X 帖子的媒体信息，可能受登录或内容可见性限制。请在顶部「登录状态」菜单选择已登录且有权访问的浏览器后重试。"

    public var errorDescription: String? {
        switch self {
        case .noURL: return "没有找到有效的视频链接。请粘贴 http 或 https 链接，或完整分享文案。"
        case .missingTool(let name): return "应用内的 \(name) 下载组件缺失或无法运行，请重新安装应用。"
        case .invalidCookieFile: return "所选 Cookie 文件无法读取。请选择 Netscape 格式的文本文件。"
        case .timedOut: return "操作等待过久，已停止。请检查网络后重试。"
        case .outputTooLarge: return "平台返回的数据过大，已停止本次操作。"
        case .launchFailed(let detail): return "下载组件未能启动：\(detail)"
        case .processFailed(_, let detail): return Self.readableFailure(detail)
        case .invalidMetadata: return "没有获得有效的视频信息。请确认这是单个视频的公开链接，或选择登录状态后重试。"
        case .liveVideo: return "这个链接是正在直播的内容。当前版本只下载已发布的视频。"
        case .missingFinalFile: return "下载组件没有返回可验证的完成文件，请重试。"
        case .invalidDirectory: return "保存目录不可写，请重新选择目录。"
        case .kuaishouShareLinkRequired: return "请在快手中复制完整的分享链接（包含作者信息），或粘贴快手分享短链后重试。"
        case .stalled: return "下载长时间没有实际进展，已自动停止并释放资源。请检查网络后手动重试。"
        case .memoryLimitExceeded: return "下载组件占用内存过多，已自动停止并释放资源。可以换一个视频或较低画质后重试。"
        case .helperDidNotExit: return "下载组件未正常退出，已停止相关任务并释放资源。请手动重试。"
        }
    }

    private static func readableFailure(_ detail: String) -> String {
        // Warnings may mention cookies, unavailable formats, or filesystem paths.
        // Classify the final actual error, and never classify credential-bearing URL text.
        let lines = detail.split(whereSeparator: \.isNewline).map(String.init)
        let primary = lines.last(where: { $0.range(of: "ERROR:", options: .caseInsensitive) != nil }) ?? detail
        let lower = primary.replacingOccurrences(of: #"https?://[^\s]+"#, with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
        func containsAny(_ phrases: [String]) -> Bool { phrases.contains(where: lower.contains) }
        let explanation: String
        if lower.contains("unsupported url") || lower.contains("no suitable extractor") {
            explanation = "暂时无法解析这个平台或链接，请换用视频详情页链接。"
        } else if lower.contains("requested format is not available") {
            explanation = "视频没有所选清晰度，请选择最佳画质后重试。"
        } else if lower.contains("[twitter]"),
                  (lower.contains("no video could be found in this tweet") || lower.range(of: #"video #\d+ is unavailable"#, options: .regularExpression) != nil) {
            explanation = xMediaVisibilityMessage
        } else if containsAny(["not available in your country", "not made available in your country", "not available in your region", "not available from your location", "blocked in your country", "geo-restricted", "geoblocked"]) {
            explanation = "平台明确限制了当前地区的访问，暂时无法下载这个视频。"
        } else if containsAny(["private video", "video is private", "tweet is private", "protected tweet", "protected account", "only available to subscribers", "members-only", "only available for registered users"]) {
            explanation = "平台明确限制了这个内容的访问权限。请使用本身有权查看它的账号登录状态后重试。"
        } else if containsAny(["video has been deleted", "video has been removed", "tweet has been deleted", "tweet was deleted", "deleted by the uploader", "removed by the uploader", "this content was removed"]) {
            explanation = "平台提示这个内容已被删除或移除，无法继续下载。"
        } else if lower.contains("permission denied") || lower.contains("no space left") || lower.contains("read-only") {
            explanation = "文件无法写入，请检查保存目录权限和磁盘剩余空间。"
        } else if containsAny(["cookies", "sign in", "login", "log in", "not authorized", "unauthorized", "authentication required", "age-restricted", "confirm your age"]) {
            explanation = "平台需要有效登录状态或内容访问资格。请在顶部「登录状态」菜单选择已登录且有权访问的浏览器，或在下载设置中选择 Cookie 文件后重试。"
        } else if lower.contains("429") || lower.contains("too many requests") {
            explanation = "平台暂时限制了请求频率，请稍后手动重试。"
        } else if lower.contains("403") || lower.contains("captcha") || lower.contains("verify") || lower.contains("blocked") {
            explanation = "平台拒绝了这次请求，可能需要登录、验证或稍后重试。"
        } else if containsAny(["timed out", "connection", "network", "name or service", "could not resolve", "unable to resolve", "failed to resolve", "nodename nor servname"]) {
            explanation = "网络连接未成功，请检查网络或代理设置后重试。"
        } else if containsAny(["unavailable", "not available", "no video formats found"]) {
            explanation = "平台当前没有返回可下载的视频。请先在浏览器确认内容可播放，并检查是否需要登录或具备访问权限。"
        } else {
            explanation = "这次解析或下载没有成功。可以重试，或使用另一个视频链接。"
        }
        // Do not echo URLs, tokens, browser paths or raw engine diagnostics into UI/history.
        return explanation
    }
}

public enum ShareLinkParser {
    /// Finds links inside Chinese/English share text without discarding signed query strings.
    public static func urls(in text: String) -> [URL] {
        let pattern = #"https?://[^\s<>\"“”‘’「」『』【】《》。，、！？；：]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsText = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            var value = nsText.substring(with: match.range)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "。，、！？；：….,!;:'"))
            // Strip unbalanced sentence wrappers, preserving balanced URL parentheses.
            while let last = value.last, [")", "]", "}", "）"].contains(last) {
                let opening: Character = last == ")" ? "(" : last == "]" ? "[" : last == "}" ? "{" : "（"
                if value.filter({ $0 == last }).count <= value.filter({ $0 == opening }).count { break }
                value.removeLast()
            }
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
}
