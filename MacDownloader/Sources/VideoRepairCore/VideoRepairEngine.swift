import DownloadCore
import Foundation

private struct RepairWorkerMessage: Decodable {
    let type: String
    let progress: Double?
    let stage: String?
    let message: String?
    let output: String?
    let framesProcessed: Int?
    let framesTotal: Int?
    let regionsRepaired: Int?
}

/// Retains one small completion event and throttles UI notifications, never frames or the video stream.
private final class RepairOutputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: TimeInterval = 0
    private var lastStage = ""
    private var lastFraction: Double = 0
    private var completion: RepairWorkerMessage?
    private var workerError: String?
    private let callback: @Sendable (VideoRepairWorkerEvent) -> Void

    init(_ callback: @escaping @Sendable (VideoRepairWorkerEvent) -> Void) { self.callback = callback }

    func consume(_ output: ProcessOutput) {
        guard output.channel == .stdout, output.line.utf8.count <= 16 * 1_024,
              let data = output.line.data(using: .utf8),
              let message = try? JSONDecoder().decode(RepairWorkerMessage.self, from: data) else { return }
        switch message.type {
        case "progress":
            let fraction = message.progress.flatMap { $0.isFinite ? 0.03 + min(1, max(0, $0)) * 0.92 : nil }
            emit(.init(stage: String((message.stage ?? "processing").prefix(80)), fraction: fraction,
                       detail: message.message.map { String($0.prefix(600)) }))
        case "completed": lock.lock(); completion = message; lock.unlock()
        case "error": lock.lock(); workerError = message.message.map { String($0.prefix(1_200)) }; lock.unlock()
        default: break
        }
    }

    func emit(_ event: VideoRepairWorkerEvent) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let fraction = event.fraction.flatMap { $0.isFinite ? max(lastFraction, min(1, max(0, $0))) : nil }
        if let fraction { lastFraction = fraction }
        let allowed = event.stage != lastStage || now - lastTime >= 0.2 || fraction == 1
        if allowed { lastStage = event.stage; lastTime = now }
        lock.unlock()
        if allowed { callback(.init(stage: event.stage, fraction: fraction, detail: event.detail)) }
    }

    func finished() throws -> RepairWorkerMessage {
        lock.lock(); defer { lock.unlock() }
        if let workerError { throw VideoRepairError.operation(workerError) }
        guard let completion else { throw VideoRepairError.invalidWorkerOutput }
        return completion
    }

    func errorDetail() -> String? { lock.lock(); defer { lock.unlock() }; return workerError }
}

private struct SourceFingerprint: Equatable {
    let size: Int
    let modified: Date
    let inode: UInt64
    let device: UInt64

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw VideoRepairError.invalidMedia }
        self.size = size.intValue; self.modified = modified; self.inode = inode.uint64Value; self.device = device.uint64Value
    }
}

private struct RepairReport: Encodable {
    let formatVersion = 1
    let completedAt: Date
    let inputFileName: String
    let wholeVideo = true
    let enhance: Bool
    let repairMosaic: Bool
    let performance: VideoRepairPerformance
    let outputSize: VideoRepairOutputSize
    let input: VideoRepairMediaInfo
    let output: VideoRepairMediaInfo
    let framesProcessed: Int?
    let framesTotal: Int?
    let perFrameRegionRepairs: Int?
    let limitations: [String]
}

public struct VideoRepairEngine: Sendable {
    public let runtime: VideoRepairRuntime
    private let runner: any ProcessRunning

    public init(runtime: VideoRepairRuntime, runner: any ProcessRunning = FoundationProcessRunner()) {
        self.runtime = runtime; self.runner = runner
    }

    public func run(_ request: VideoRepairRequest, receiptURL: URL,
                    onProgress: @escaping @Sendable (VideoRepairWorkerEvent) -> Void = { _ in }) async throws -> VideoRepairExportResult {
        try Task.checkCancellation()
        guard request.outputSize != .fullHD || request.enhance else {
            throw VideoRepairError.operation("1080P 精细增强需要开启画质增强，请开启后重试。")
        }
        guard request.enhance || request.repairMosaic else { throw VideoRepairError.operation("请至少开启一种 AI 修复方式。") }
        guard request.input.isFileURL, request.destination.isFileURL, receiptURL.isFileURL else { throw VideoRepairError.invalidMedia }
        try runtime.validate()
        let fm = FileManager.default
        let relay = RepairOutputRelay(onProgress)
        relay.emit(.init(stage: "inspecting", fraction: 0.01, detail: "正在检查整片视频、画面尺寸和音轨…"))
        let source = request.input.resolvingSymlinksInPath().standardizedFileURL
        let original = try SourceFingerprint(source)
        let info = try await VideoRepairMedia.inspect(source)
        try Task.checkCancellation()
        try fm.createDirectory(at: request.destination, withIntermediateDirectories: true)
        let destination = request.destination.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: destination.path) else { throw VideoRepairError.operation("AI 修复的保存文件夹不可写，请更换位置。") }
        let stem = String(request.input.deletingPathExtension().lastPathComponent.prefix(50))
            .replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let folder = destination.appendingPathComponent(stem + " · AI修复 [" + String(request.id.uuidString.prefix(8)) + "]", isDirectory: true)
        let staging = destination.appendingPathComponent(".feather-repair-" + request.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path), !fm.fileExists(atPath: staging.path),
              !fm.fileExists(atPath: receiptURL.path) else { throw VideoRepairError.outputExists }
        // The recovery record cannot be an exported file, source, or hidden intermediate.
        let resolvedReceipt = receiptURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedReceipt != source,
              !resolvedReceipt.path.hasPrefix(folder.path + "/"),
              !resolvedReceipt.path.hasPrefix(staging.path + "/") else { throw VideoRepairError.outputExists }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let output = staging.appendingPathComponent("AI修复视频.mp4")
        let report = staging.appendingPathComponent("修复报告.json")
        let workerReport = staging.appendingPathComponent("worker-detail.json")
        relay.emit(.init(stage: "preparing", fraction: 0.03, detail: "正在准备本机 AI，整片自动识别处理…"))
        let environment = runtime.environment.merging([
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
            "PYTHONPATH": "", "PYTHONHOME": "", "PYTHONSTARTUP": "",
            "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2", "VECLIB_MAXIMUM_THREADS": "2"
        ]) { _, fixed in fixed }
        let result: ProcessResult
        let memoryBudget = min(ProcessInfo.processInfo.physicalMemory / 4, 6 * 1_024 * 1_024 * 1_024)
        do {
            result = try await runner.run(ProcessCommand(executable: runtime.python, arguments: [runtime.worker.path,
            "repair", "--input", source.path, "--output", output.path,
            "--report", workerReport.path,
            "--ffmpeg", runtime.ffmpeg.path, "--ffprobe", runtime.ffprobe.path,
            "--enhance", request.enhance ? "true" : "false", "--repair-mosaic", request.repairMosaic ? "true" : "false",
            "--performance", request.performance.rawValue, "--output-size", request.outputSize.rawValue,
            "--memory-budget", String(memoryBudget)],
            environment: environment, timeout: 7 * 24 * 60 * 60,
            maximumOutputBytes: 64 * 1_024 * 1_024, maximumStandardErrorBytes: 512 * 1_024,
            maximumLineBytes: 16 * 1_024, captureStandardOutput: false,
            maximumMemoryBytes: memoryBudget)) { relay.consume($0) }
        } catch DownloadError.memoryLimitExceeded {
            throw VideoRepairError.operation("AI 修复占用内存超过本机预算，已停止并释放资源。请关闭其他占用内存的应用后重试。")
        } catch DownloadError.timedOut {
            throw VideoRepairError.operation("AI 修复超过运行时间预算，已停止并释放资源。")
        } catch DownloadError.outputTooLarge {
            throw VideoRepairError.operation("AI 修复组件返回的数据超过安全预算，已停止本次任务。")
        } catch DownloadError.launchFailed(let detail) {
            throw VideoRepairError.operation("AI 修复组件无法启动：" + String(detail.prefix(600)))
        } catch DownloadError.helperDidNotExit {
            throw VideoRepairError.operation("AI 修复组件未正常退出，已停止相关进程并释放资源。")
        }
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let detail = relay.errorDetail() ?? String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VideoRepairError.operation(detail?.isEmpty == false ? String(detail!.suffix(1_200)) : "AI 修复未完成，请重试或更换视频。")
        }
        let completion = try relay.finished()
        guard completion.output.map({ URL(fileURLWithPath: $0).standardizedFileURL == output.standardizedFileURL }) == true,
              completion.framesProcessed.map({ $0 > 0 }) == true,
              completion.framesTotal.map({ $0 > 0 }) == true,
              completion.framesProcessed == completion.framesTotal,
              completion.regionsRepaired.map({ $0 >= 0 }) ?? true else { throw VideoRepairError.invalidWorkerOutput }
        relay.emit(.init(stage: "validating", fraction: 0.96, detail: "正在校验完整时长、画面尺寸和全部音轨…"))
        let repaired = try await VideoRepairMedia.inspect(output)
        try VideoRepairMedia.validateOutput(repaired, against: info, outputSize: request.outputSize)
        guard completion.framesProcessed.map({ abs($0 - repaired.videoFrameCount) <= 1 }) == true else {
            throw VideoRepairError.invalidWorkerOutput
        }
        try Task.checkCancellation()
        guard request.input.resolvingSymlinksInPath().standardizedFileURL == source,
              try SourceFingerprint(source) == original else { throw VideoRepairError.sourceChanged }
        let verifiedReport = RepairReport(completedAt: Date(), inputFileName: request.input.lastPathComponent,
            enhance: request.enhance, repairMosaic: request.repairMosaic, performance: request.performance,
            outputSize: request.outputSize, input: info, output: repaired,
            framesProcessed: completion.framesProcessed, framesTotal: completion.framesTotal,
            perFrameRegionRepairs: completion.regionsRepaired, limitations: [
                "整片自动检测网格状马赛克，使用 LaMa 重建局部画面；自动检测可能漏检或误检。",
                "严重打码中丢失的细节由 AI 推测生成，无法保证与原始画面一致。",
                "区域次数按逐帧处理累计，不能视为独立位置或人数。"
            ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var reportObject = try JSONSerialization.jsonObject(with: encoder.encode(verifiedReport)) as! [String: Any]
        if fm.fileExists(atPath: workerReport.path) {
            guard let size = try workerReport.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 1_024 * 1_024,
                  let details = try JSONSerialization.jsonObject(with: Data(contentsOf: workerReport)) as? [String: Any] else {
                throw VideoRepairError.invalidWorkerOutput
            }
            reportObject["workerDetails"] = details
        }
        try JSONSerialization.data(withJSONObject: reportObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: report, options: .withoutOverwriting)
        let videoBytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let reportBytes = try report.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard videoBytes > 0, reportBytes > 0 else { throw VideoRepairError.invalidWorkerOutput }
        // Ensure no temporary decoded frames or model caches become user exports.
        let exportNames = Set([output.lastPathComponent, report.lastPathComponent])
        for file in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) where !exportNames.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
        }
        let exported = VideoRepairExportResult(folder: folder,
            video: folder.appendingPathComponent(output.lastPathComponent), report: folder.appendingPathComponent(report.lastPathComponent),
            videoBytes: videoBytes, reportBytes: reportBytes, inputInfo: info, outputInfo: repaired,
            detectedRegions: completion.regionsRepaired, receiptSaved: true)
        try Task.checkCancellation()
        // Prepare durable recovery before the atomic directory move. A pre-move crash has
        // no complete files and cannot appear successful; a post-move crash can recover.
        let receiptTemporary = receiptURL.deletingLastPathComponent()
            .appendingPathComponent(".feather-repair-receipt-" + UUID().uuidString)
        defer { try? fm.removeItem(at: receiptTemporary) }
        do {
            try fm.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(VideoRepairReceipt(request: request, result: exported)).write(to: receiptTemporary, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptTemporary.path)
            try fm.moveItem(at: receiptTemporary, to: receiptURL)
        } catch {
            throw VideoRepairError.operation("无法保存修复任务记录，请检查保存位置的权限和磁盘空间后重试。")
        }
        do { try fm.moveItem(at: staging, to: folder) }
        catch { try? fm.removeItem(at: receiptURL); throw error }
        // Once committed, completion wins a late cancellation: the export is already durable.
        relay.emit(.init(stage: "completed", fraction: 1, detail: "整片 AI 修复已完成并保存"))
        return exported
    }
}
