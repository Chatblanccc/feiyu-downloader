import Foundation

public enum VideoRepairEngineKind: String, Codable, CaseIterable, Sendable {
    case realesrgan, seedvr2
    public var title: String { self == .seedvr2 ? "SeedVR2 深度清晰（实验）" : "常规增强" }
    public var detail: String {
        self == .seedvr2
        ? "首次使用下载本地组件和约 7.3 GB 模型，之后可离线处理。需要 Apple 芯片、macOS 14 和至少 32 GB 内存；速度较慢，细节由 AI 推测，可能改变小图案或产生闪烁。"
        : "使用现有本地引擎改善画面，支持轻度增强和局部修复。"
    }
}

public enum VideoRepairOutputSize: String, Codable, CaseIterable, Sendable {
    case source, hd720, fullHD

    public var title: String {
        switch self {
        case .source: return "原尺寸轻度增强"
        case .hd720: return "720P 深度增强"
        case .fullHD: return "1080P 精细增强"
        }
    }

    public var detail: String {
        switch self {
        case .source: return "保持原视频尺寸，改善噪点和模糊；可选择更快或更低负载的处理方式。"
        case .hd720: return "保持原片比例，将低清视频增强至 720P 范围；较大的原片保留尺寸。本机深度修复计算量大，建议先处理较短视频。"
        case .fullHD: return "使用 AI 超分辨率补充画面细节，按原比例放大至 1080P 范围；高分辨率原片不缩小。以画质优先，长视频处理时间和负载会增加；严重模糊的细节无法保证真实还原。"
        }
    }
}

public enum VideoRepairPerformance: String, Codable, CaseIterable, Sendable {
    case balanced, quality, quiet

    public var title: String {
        switch self {
        case .balanced: return "快速修复（推荐）"
        case .quality: return "原画精修"
        case .quiet: return "低负载"
        }
    }

    public var detail: String {
        switch self {
        case .balanced: return "AI 增强按最长边 960 像素计算后融合回原片，保留原尺寸；细节修复力度低于原画精修。"
        case .quality: return "按原画分辨率逐帧增强，细节修复更充分，长视频耗时更久。"
        case .quiet: return "AI 增强按最长边 640 像素计算，减少 CPU 线程并安排短暂休息，以降低持续负载。"
        }
    }
}

/// Every request processes the complete file. No time range or manual region is accepted.
public struct VideoRepairRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let input: URL
    public let destination: URL
    public let enhance: Bool
    public let repairMosaic: Bool
    public let performance: VideoRepairPerformance
    public let outputSize: VideoRepairOutputSize
    public let engine: VideoRepairEngineKind

    public init(id: UUID = UUID(), input: URL, destination: URL, enhance: Bool = true, repairMosaic: Bool = true,
                performance: VideoRepairPerformance = .balanced, outputSize: VideoRepairOutputSize = .source,
                engine: VideoRepairEngineKind = .realesrgan) {
        self.id = id; self.input = input; self.destination = destination
        self.engine = engine
        self.enhance = engine == .seedvr2 ? true : enhance
        self.repairMosaic = engine == .seedvr2 ? false : repairMosaic
        self.outputSize = outputSize
        self.performance = engine == .seedvr2 || (outputSize == .fullHD && performance == .balanced) ? .quality : performance
    }

    private enum CodingKeys: String, CodingKey { case id, input, destination, enhance, repairMosaic, performance, outputSize, engine }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        input = try values.decode(URL.self, forKey: .input)
        destination = try values.decode(URL.self, forKey: .destination)
        engine = try values.decodeIfPresent(VideoRepairEngineKind.self, forKey: .engine) ?? .realesrgan
        let savedEnhance = try values.decode(Bool.self, forKey: .enhance)
        let savedMosaic = try values.decode(Bool.self, forKey: .repairMosaic)
        enhance = engine == .seedvr2 ? true : savedEnhance
        repairMosaic = engine == .seedvr2 ? false : savedMosaic
        // Existing exports preserve their source dimensions, including receipt recovery.
        outputSize = try values.decodeIfPresent(VideoRepairOutputSize.self, forKey: .outputSize) ?? .source
        // Records from 0.5.0 describe native-resolution enhancement.
        let savedPerformance = try values.decodeIfPresent(VideoRepairPerformance.self, forKey: .performance) ?? .quality
        performance = engine == .seedvr2 || (outputSize == .fullHD && savedPerformance == .balanced) ? .quality : savedPerformance
    }
}

public struct VideoRepairWorkerEvent: Codable, Sendable {
    public let stage: String
    public let fraction: Double?
    public let detail: String?
    public init(stage: String, fraction: Double? = nil, detail: String? = nil) {
        self.stage = stage; self.fraction = fraction; self.detail = detail
    }
}

public struct VideoRepairMediaInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let videoDuration: Double
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let videoFrameCount: Int
    public let audioDurations: [Double]
    public var hasAudio: Bool { !audioDurations.isEmpty }
    public var audioTrackCount: Int { audioDurations.count }
}

public struct VideoRepairExportResult: Codable, Sendable {
    public let folder: URL
    public let video: URL
    public let report: URL
    public let videoBytes: Int
    public let reportBytes: Int
    public let inputInfo: VideoRepairMediaInfo
    public let outputInfo: VideoRepairMediaInfo
    /// Counts per-frame repair operations, not unique locations or people.
    public let detectedRegions: Int?
    public let receiptSaved: Bool

    public func filesExist() -> Bool {
        func matches(_ url: URL, _ size: Int) -> Bool {
            guard url.isFileURL, size > 0,
                  let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let bytes = values[.size] as? NSNumber else { return false }
            // URL.resourceValues may reuse cached file sizes after a later overwrite.
            return bytes.intValue == size
        }
        guard video.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              report.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return false }
        return matches(video, videoBytes) && matches(report, reportBytes)
    }
}

public struct VideoRepairReceipt: Codable, Sendable {
    public let request: VideoRepairRequest
    public let result: VideoRepairExportResult
    public init(request: VideoRepairRequest, result: VideoRepairExportResult) {
        self.request = request; self.result = result
    }

    /// A receipt written before commit is recoverable only once the complete files exist.
    public static func recover(at url: URL) async throws -> VideoRepairReceipt {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= 1_024 * 1_024 else { throw VideoRepairError.invalidReceipt }
        let receipt = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard receipt.result.receiptSaved, receipt.result.filesExist() else { throw VideoRepairError.invalidReceipt }
        let current = try await VideoRepairMedia.inspect(receipt.result.video)
        try VideoRepairMedia.validateOutput(current, against: receipt.result.inputInfo, outputSize: receipt.request.outputSize)
        guard current == receipt.result.outputInfo else { throw VideoRepairError.invalidReceipt }
        return receipt
    }
}

public enum VideoRepairError: LocalizedError {
    case invalidMedia, outputExists, runtimeUnavailable, invalidReceipt, invalidWorkerOutput, sourceChanged
    case operation(String)
    public var errorDescription: String? {
        switch self {
        case .invalidMedia: return "无法读取完整视频，请确认文件完整且可以正常播放。"
        case .outputExists: return "本次修复的保存位置已存在，请重新开始一个任务。"
        case .runtimeUnavailable: return "AI 修复组件尚未准备好，请下载或重新准备组件后重试。"
        case .invalidReceipt: return "修复结果记录不完整，未将任务标记为完成。"
        case .invalidWorkerOutput: return "AI 修复没有生成经过验证的整片视频，请重试。"
        case .sourceChanged: return "原视频在处理期间发生了变化，请重新选择后再试。"
        case .operation(let message): return message
        }
    }
}
