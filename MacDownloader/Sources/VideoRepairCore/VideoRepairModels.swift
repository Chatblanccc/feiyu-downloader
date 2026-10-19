import Foundation

/// Every request processes the complete file. No time range or manual region is accepted.
public struct VideoRepairRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let input: URL
    public let destination: URL
    public let enhance: Bool
    public let repairMosaic: Bool

    public init(id: UUID = UUID(), input: URL, destination: URL, enhance: Bool = true, repairMosaic: Bool = true) {
        self.id = id; self.input = input; self.destination = destination
        self.enhance = enhance; self.repairMosaic = repairMosaic
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
        try VideoRepairMedia.validateOutput(current, against: receipt.result.inputInfo)
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
        case .runtimeUnavailable: return "AI 修复组件不完整，请重新安装飞羽下载。"
        case .invalidReceipt: return "修复结果记录不完整，未将任务标记为完成。"
        case .invalidWorkerOutput: return "AI 修复没有生成经过验证的整片视频，请重试。"
        case .sourceChanged: return "原视频在处理期间发生了变化，请重新选择后再试。"
        case .operation(let message): return message
        }
    }
}
