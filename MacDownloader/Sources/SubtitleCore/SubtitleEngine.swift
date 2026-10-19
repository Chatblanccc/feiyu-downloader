import DownloadCore
import Foundation

public struct SubtitleRequest: Codable, Sendable {
    public let id: UUID
    public let input: URL
    public let destination: URL
    public let source: String
    public let target: String
    public let textMode: SubtitleTextMode
    public let videoMode: SubtitleVideoMode
    public let style: SubtitleStyle
    public init(id: UUID = UUID(), input: URL, destination: URL, source: String, target: String,
                textMode: SubtitleTextMode, videoMode: SubtitleVideoMode, style: SubtitleStyle = .default) {
        self.id = id; self.input = input; self.destination = destination
        self.source = source; self.target = target; self.textMode = textMode; self.videoMode = videoMode
        self.style = style
    }
    private enum CodingKeys: String, CodingKey { case id, input, destination, source, target, textMode, videoMode, style }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        input = try values.decode(URL.self, forKey: .input)
        destination = try values.decode(URL.self, forKey: .destination)
        source = try values.decode(String.self, forKey: .source)
        target = try values.decode(String.self, forKey: .target)
        textMode = try values.decode(SubtitleTextMode.self, forKey: .textMode)
        videoMode = try values.decode(SubtitleVideoMode.self, forKey: .videoMode)
        style = try values.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? .default
    }
}

public struct SubtitleExportResult: Codable, Sendable {
    public let folder: URL
    public let subtitles: URL
    public let video: URL?
    public let subtitleBytes: Int
    public let videoBytes: Int?
    public let cueCount: Int
    public let receiptSaved: Bool
    public func filesExist() -> Bool {
        func matches(_ url: URL, _ size: Int) -> Bool {
            guard size > 0, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.fileSize == size
        }
        guard matches(subtitles, subtitleBytes) else { return false }
        if let video { return matches(video, videoBytes ?? 0) }
        return videoBytes == nil
    }
}

public struct SubtitleReceipt: Codable, Sendable {
    public let request: SubtitleRequest
    public let result: SubtitleExportResult
}

private final class SubtitleOutputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: TimeInterval = 0
    private var lastStage = ""
    private var lastFraction: Double = 0
    private let callback: @Sendable (SubtitleWorkerEvent) -> Void
    init(_ callback: @escaping @Sendable (SubtitleWorkerEvent) -> Void) { self.callback = callback }
    func emit(_ event: SubtitleWorkerEvent) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let fraction = event.fraction.flatMap { $0.isFinite ? max(lastFraction, min(1, max(0, $0))) : nil }
        if let fraction { lastFraction = fraction }
        let filtered = SubtitleWorkerEvent(stage: event.stage, fraction: fraction, detail: event.detail)
        let allowed = event.stage != lastStage || now - lastEmission >= 0.2 || fraction == 1
        if allowed { lastStage = event.stage; lastEmission = now }
        lock.unlock()
        if allowed { callback(filtered) }
    }
}

public struct SubtitleEngine: Sendable {
    public let executable: URL
    public let ffmpeg: URL
    private let runner = FoundationProcessRunner()
    public init(executable: URL, ffmpeg: URL) { self.executable = executable; self.ffmpeg = ffmpeg }

    public func run(_ request: SubtitleRequest, receiptURL: URL,
                    onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void) async throws -> SubtitleExportResult {
        let fm = FileManager.default
        let style = try request.style.validated()
        let relay = SubtitleOutputRelay(onProgress)
        relay.emit(.init(stage: "inspecting", fraction: 0.01, detail: "正在检查视频…"))
        let info = try await inspect(request.input)
        guard info.duration.isFinite, info.duration > 0 else { throw SubtitleError.invalidMedia }
        guard info.duration <= 7_200 else { throw SubtitleError.tooLong }
        let original = try request.input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try Task.checkCancellation()
        try fm.createDirectory(at: request.destination, withIntermediateDirectories: true)
        let stem = String(request.input.deletingPathExtension().lastPathComponent.prefix(40))
            .replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let suffix = String(request.id.uuidString.prefix(8))
        let finalFolder = request.destination.appendingPathComponent(stem + " · 字幕 [" + suffix + "]", isDirectory: true)
        guard !fm.fileExists(atPath: finalFolder.path) else { throw SubtitleError.outputExists }
        let staging = request.destination.appendingPathComponent(".feather-subtitles-" + request.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: staging.path) else { throw SubtitleError.outputExists }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let audio = staging.appendingPathComponent("speech.wav")
        relay.emit(.init(stage: "extracting", fraction: 0.03, detail: "正在读取视频中的声音…"))
        try await command(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", request.input.path,
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-y", audio.path], timeout: 180)
        guard fm.fileExists(atPath: audio.path) else { throw SubtitleError.noAudio }
        let transcript = staging.appendingPathComponent("transcript.json")
        relay.emit(.init(stage: "speechAssets", fraction: 0.08, detail: "正在准备本机语音识别…"))
        try await helper(["speech", "--input", audio.path, "--output", transcript.path, "--source", request.source], timeout: 1_800) { event in
            let fraction = event.fraction.map { event.stage == "speechAssets" ? 0.08 + min(1, max(0, $0)) * 0.1 : 0.18 + min(1, max(0, $0)) * 0.34 }
            relay.emit(.init(stage: event.stage, fraction: fraction, detail: event.detail))
        }
        var cues = try readCues(transcript)
        try SubtitleDocument.validate(cues, duration: info.duration)
        try Task.checkCancellation()
        if request.textMode != .original {
            let translated = staging.appendingPathComponent("translated.json")
            relay.emit(.init(stage: "translating", fraction: 0.53, detail: "正在翻译字幕…"))
            try await helper(["translate", "--input", transcript.path, "--output", translated.path,
                              "--source", request.source, "--target", request.target], timeout: 1_800) { event in
                relay.emit(.init(stage: event.stage, fraction: event.fraction.map { 0.53 + min(1, max(0, $0)) * 0.24 }, detail: event.detail))
            }
            cues = try readCues(translated)
        }
        try SubtitleDocument.validate(cues, duration: info.duration)
        let srt = staging.appendingPathComponent("字幕.srt")
        try SubtitleDocument.srt(cues: cues, mode: request.textMode).write(to: srt, atomically: true, encoding: .utf8)
        var videoName: String?
        if request.videoMode != .none {
            relay.emit(.init(stage: "exporting", fraction: 0.78, detail: request.videoMode == .soft ? "正在嵌入可开关字幕…" : "正在将字幕绘制到视频画面…"))
            videoName = "带字幕视频.mp4"
            let output = staging.appendingPathComponent(videoName!)
            if request.videoMode == .soft {
                try await command(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", request.input.path,
                    "-i", srt.path, "-map", "0:v:0", "-map", "0:a?", "-map", "1:0", "-c:v", "copy", "-c:a", "copy",
                    "-c:s", "mov_text", "-metadata:s:s:0", "title=飞羽字幕", "-disposition:s:0", "default", "-movflags", "+faststart", "-y", output.path], timeout: 300)
            } else {
                let json = staging.appendingPathComponent("render.json")
                try JSONEncoder().encode(cues).write(to: json, options: .atomic)
                let styleFile = staging.appendingPathComponent("style.json")
                try JSONEncoder().encode(style).write(to: styleFile, options: .atomic)
                try await helper(["burn", "--input", request.input.path, "--output", output.path, "--cues", json.path,
                                  "--text-mode", request.textMode.rawValue, "--style", styleFile.path], timeout: 1_800) { event in
                    relay.emit(.init(stage: "exporting", fraction: event.fraction.map { 0.78 + min(1, max(0, $0)) * 0.2 }, detail: "正在生成带字幕视频…"))
                }
            }
            _ = try await inspect(output)
        }
        try Task.checkCancellation()
        let current = try request.input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard current.fileSize == original.fileSize, current.contentModificationDate == original.contentModificationDate else {
            throw SubtitleError.operation("原视频在处理期间发生了变化，请重新选择后再试。")
        }
        let subtitleBytes = try srt.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let videoBytes = try videoName.map { try staging.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        guard subtitleBytes > 0, videoName == nil || (videoBytes ?? 0) > 0 else { throw SubtitleError.invalidMedia }
        // Intermediate audio/transcripts stay private and are never exported with the result.
        for file in ["speech.wav", "transcript.json", "translated.json", "render.json", "style.json"] { try? fm.removeItem(at: staging.appendingPathComponent(file)) }
        let provisional = SubtitleExportResult(folder: finalFolder, subtitles: finalFolder.appendingPathComponent("字幕.srt"),
            video: videoName.map { finalFolder.appendingPathComponent($0) }, subtitleBytes: subtitleBytes,
            videoBytes: videoBytes, cueCount: cues.count, receiptSaved: true)
        // Prepare recovery before committing files. Recovery still verifies every final file,
        // so a crash before the move cannot claim success, and a crash after it is recoverable.
        do {
            try fm.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(SubtitleReceipt(request: request, result: provisional)).write(to: receiptURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        } catch {
            try? fm.removeItem(at: receiptURL)
            throw SubtitleError.operation("无法保存字幕任务记录，请检查保存位置的权限和磁盘空间后重试。")
        }
        do { try fm.moveItem(at: staging, to: finalFolder) }
        catch {
            try? fm.removeItem(at: receiptURL)
            throw error
        }
        relay.emit(.init(stage: "completed", fraction: 1, detail: "字幕已保存"))
        return SubtitleExportResult(folder: provisional.folder, subtitles: provisional.subtitles, video: provisional.video,
            subtitleBytes: provisional.subtitleBytes, videoBytes: provisional.videoBytes, cueCount: provisional.cueCount, receiptSaved: true)
    }

    private func readCues(_ url: URL) throws -> [SubtitleCue] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 8 * 1_024 * 1_024 else { throw SubtitleError.invalidSubtitles }
        let cues = try JSONDecoder().decode([SubtitleCue].self, from: Data(contentsOf: url))
        guard !cues.isEmpty, cues.count <= 10_000 else { throw SubtitleError.noSpeech }
        return cues
    }

    private func inspect(_ url: URL) async throws -> SubtitleMediaInfo {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherMediaInfo-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await helper(["inspect", "--input", url.path, "--output", temporary.path], timeout: 30) { _ in }
        guard let bytes = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0, bytes <= 4_096,
              let data = try? Data(contentsOf: temporary),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = object["duration"] as? Double, let width = object["width"] as? Int,
              let height = object["height"] as? Int else { throw SubtitleError.invalidMedia }
        guard object["hasAudio"] as? Bool == true else { throw SubtitleError.noAudio }
        return SubtitleMediaInfo(duration: duration, width: width, height: height)
    }

    private func helper(_ args: [String], timeout: Double,
                        onProgress: @escaping @Sendable (SubtitleWorkerEvent) -> Void) async throws {
        let result = try await runner.run(ProcessCommand(executable: executable, arguments: ["--subtitle-worker"] + args,
            timeout: timeout, maximumOutputBytes: 4 * 1_024 * 1_024, maximumStandardErrorBytes: 128 * 1_024,
            maximumLineBytes: 16 * 1_024, captureStandardOutput: false, maximumMemoryBytes: 2 * 1_024 * 1_024 * 1_024)) { line in
                let prefix = "FEATHER_SUBTITLE_EVENT:"
                guard line.line.hasPrefix(prefix), let data = line.line.dropFirst(prefix.count).data(using: .utf8),
                      let event = try? JSONDecoder().decode(SubtitleWorkerEvent.self, from: data) else { return }
                onProgress(event)
            }
        try check(result)
    }

    private func command(_ executable: URL, _ args: [String], timeout: Double) async throws {
        let result = try await runner.run(ProcessCommand(executable: executable, arguments: args, timeout: timeout,
            maximumOutputBytes: 256 * 1_024, maximumStandardErrorBytes: 128 * 1_024, captureStandardOutput: false))
        try check(result)
    }
    private func check(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            let message = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SubtitleError.operation(message.isEmpty ? "本次处理未完成，请重试或更换视频。" : String(message.suffix(1_200)))
        }
    }
}
