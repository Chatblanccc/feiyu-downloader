import Foundation

public struct SubtitleCue: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var sourceText: String
    public var translatedText: String?
    public init(id: Int, start: Double, end: Double, sourceText: String, translatedText: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.sourceText = sourceText; self.translatedText = translatedText
    }
    public func text(mode: SubtitleTextMode) -> String {
        switch mode {
        case .original: return sourceText
        case .translated: return translatedText ?? sourceText
        case .bilingual:
            guard let translatedText, translatedText != sourceText else { return sourceText }
            return sourceText + "\n" + translatedText
        }
    }
}

public struct SubtitleLanguage: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum SubtitleTextMode: String, Codable, CaseIterable, Sendable {
    case original, translated, bilingual
    public var title: String {
        switch self { case .original: return "仅原文"; case .translated: return "仅译文"; case .bilingual: return "原文＋译文" }
    }
}

public enum SubtitleVideoMode: String, Codable, CaseIterable, Sendable {
    case none, soft, burned
    public var title: String {
        switch self { case .none: return "仅导出字幕文件"; case .soft: return "可开关字幕的视频"; case .burned: return "字幕直接显示在画面中" }
    }
}

public enum SubtitlePosition: String, Codable, CaseIterable, Sendable {
    case bottom, center, top
    public var title: String {
        switch self { case .bottom: return "底部"; case .center: return "居中"; case .top: return "顶部" }
    }
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var fontScale: Double
    public var colorHex: String
    public var position: SubtitlePosition
    public static let `default` = SubtitleStyle()

    public init(fontScale: Double = 1, colorHex: String = "FFFFFF", position: SubtitlePosition = .bottom) {
        self.fontScale = fontScale
        self.colorHex = Self.isColorHex(colorHex) ? colorHex.uppercased() : colorHex
        self.position = position
    }

    /// UI edits remain cheap; all processing and serialization boundaries reject
    /// invalid values rather than silently substituting a different appearance.
    public func validated() throws -> SubtitleStyle {
        guard fontScale.isFinite, (0.6...2).contains(fontScale) else {
            throw SubtitleError.operation("字幕字号需在 0.6 到 2 倍之间。")
        }
        guard Self.isColorHex(colorHex) else {
            throw SubtitleError.operation("字幕颜色需要 6 位十六进制颜色值，例如 FFFFFF。")
        }
        return SubtitleStyle(fontScale: fontScale, colorHex: colorHex, position: position)
    }

    private static func isColorHex(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey { case fontScale, colorHex, position }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let candidate = SubtitleStyle(fontScale: try values.decode(Double.self, forKey: .fontScale),
                                      colorHex: try values.decode(String.self, forKey: .colorHex),
                                      position: try values.decode(SubtitlePosition.self, forKey: .position))
        do { self = try candidate.validated() }
        catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid subtitle style", underlyingError: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        let style = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(style.fontScale, forKey: .fontScale)
        try values.encode(style.colorHex, forKey: .colorHex)
        try values.encode(style.position, forKey: .position)
    }
}

public struct SubtitleWorkerEvent: Codable, Sendable {
    public let stage: String
    public let fraction: Double?
    public let detail: String?
    public init(stage: String, fraction: Double? = nil, detail: String? = nil) {
        self.stage = stage; self.fraction = fraction; self.detail = detail
    }
}

public enum SubtitleError: LocalizedError {
    case unsupportedSystem, unsupportedLanguage, noAudio, noSpeech, invalidMedia, invalidSubtitles
    case tooLong, tooManyCues, outputExists, operation(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "本机视频翻译需要 macOS 26 或更新版本。视频下载功能仍可正常使用。"
        case .unsupportedLanguage: return "系统暂不支持所选语言或这个翻译方向，请更换语言。"
        case .noAudio: return "这个视频没有可识别的音轨。"
        case .noSpeech: return "没有识别到可用的人声，请确认视频内容和源语言。"
        case .invalidMedia: return "无法读取这个视频，请确认文件完整且可播放。"
        case .invalidSubtitles: return "字幕内容或时间范围不完整，未导出视频。"
        case .tooLong: return "首版支持最长两小时的视频，请先截取需要处理的片段。"
        case .tooManyCues: return "字幕数量或文字量超过本次处理范围，请分段处理视频。"
        case .outputExists: return "目标文件已存在，请更换保存位置或文件名。"
        case .operation(let message): return message
        }
    }
}
