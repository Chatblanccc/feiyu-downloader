import Foundation
import AVFoundation
import Speech
import SubtitleCore

private final class SubtitleCLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SubtitleExportResult, Error>?
    private var requested = false
    func install(_ task: Task<SubtitleExportResult, Error>) {
        lock.lock(); self.task = task; let requested = requested; lock.unlock()
        if requested { task.cancel() }
    }
    func cancel() { lock.lock(); requested = true; let task = task; lock.unlock(); task?.cancel() }
    func clear() { lock.lock(); task = nil; lock.unlock() }
}

enum SubtitleCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func file(_ flag: String) throws -> URL {
            guard let path = argument(flag), !path.isEmpty else { throw SubtitleError.operation("处理参数不完整。") }
            return URL(fileURLWithPath: path)
        }
        func cues(_ url: URL) throws -> [SubtitleCue] {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 8 * 1_024 * 1_024 else { throw SubtitleError.invalidSubtitles }
            return try JSONDecoder().decode([SubtitleCue].self, from: Data(contentsOf: url))
        }
        func style() throws -> SubtitleStyle {
            if let path = argument("--style") {
                let url = URL(fileURLWithPath: path)
                guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0, bytes <= 4_096 else {
                    throw SubtitleError.operation("字幕样式文件不完整。")
                }
                return try JSONDecoder().decode(SubtitleStyle.self, from: Data(contentsOf: url)).validated()
            }
            let scale: Double
            if let raw = argument("--font-scale") {
                guard let value = Double(raw) else { throw SubtitleError.operation("字幕字号无效。") }
                scale = value
            } else { scale = 1 }
            let position: SubtitlePosition
            if let raw = argument("--subtitle-position") {
                guard let value = SubtitlePosition(rawValue: raw) else { throw SubtitleError.operation("字幕位置无效。") }
                position = value
            } else { position = .bottom }
            return try SubtitleStyle(fontScale: scale, colorHex: argument("--subtitle-color") ?? "FFFFFF", position: position).validated()
        }
        do {
            if let path = argument("--subtitle-integration-test") {
                let destination = try file("--destination")
                let request = SubtitleRequest(input: URL(fileURLWithPath: path), destination: destination,
                    source: argument("--source") ?? "en-US", target: argument("--target") ?? "zh",
                    textMode: argument("--text-mode").flatMap(SubtitleTextMode.init(rawValue:)) ?? .bilingual,
                    videoMode: argument("--video-mode").flatMap(SubtitleVideoMode.init(rawValue:)) ?? .burned,
                    style: try style())
                let engine = SubtitleEngine(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]), ffmpeg: AppTools.paths.ffmpeg)
                let cancellation = SubtitleCLICancellation(), cancelStage = argument("--cancel-at-stage")
                let task = Task.detached {
                    try await engine.run(request, receiptURL: destination.appendingPathComponent("test-completion.json")) { event in
                        if event.stage == cancelStage { cancellation.cancel() }
                        guard let data = try? JSONEncoder().encode(event) else { return }
                        fputs("FEATHER_SUBTITLE_EVENT:" + String(decoding: data, as: UTF8.self) + "\n", stderr)
                    }
                }
                cancellation.install(task)
                defer { cancellation.clear() }
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel() }
                print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                return 0
            }
            if arguments.contains("--subtitle-capabilities") {
                guard #available(macOS 26, *) else { throw SubtitleError.unsupportedSystem }
                let speech = await NativeSpeech.languages()
                let target = await NativeTranslation.languages()
                let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
                struct Capabilities: Encodable { let source: [SubtitleLanguage]; let target: [SubtitleLanguage]; let reservedSpeechLocales: [String] }
                print(String(decoding: try JSONEncoder().encode(Capabilities(source: speech, target: target, reservedSpeechLocales: reserved)), as: UTF8.self))
                return 0
            }
            guard let index = arguments.firstIndex(of: "--subtitle-worker"), arguments.indices.contains(index + 1) else { throw SubtitleError.operation("处理参数不完整。") }
            let mode = arguments[index + 1]
            let input = try file("--input"), output = try file("--output")
            guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL,
                  !FileManager.default.fileExists(atPath: output.path) else { throw SubtitleError.outputExists }
            let progress: @Sendable (SubtitleWorkerEvent) -> Void = { event in
                guard let data = try? JSONEncoder().encode(event), data.count <= 8 * 1_024 else { return }
                print("FEATHER_SUBTITLE_EVENT:" + String(decoding: data, as: UTF8.self))
                fflush(stdout)
            }
            switch mode {
            case "inspect":
                let info = try await SubtitleMedia.inspect(input)
                let audioTracks = try await AVURLAsset(url: input).loadTracks(withMediaType: .audio)
                let hasAudio = !audioTracks.isEmpty
                let object: [String: Any] = ["duration": info.duration, "width": info.width, "height": info.height, "hasAudio": hasAudio]
                try JSONSerialization.data(withJSONObject: object).write(to: output, options: .withoutOverwriting)
            case "speech":
                guard #available(macOS 26, *) else { throw SubtitleError.unsupportedSystem }
                let result = try await NativeSpeech.transcribe(audioFile: input, localeIdentifier: argument("--source") ?? "", onProgress: progress)
                try JSONEncoder().encode(result).write(to: output, options: .withoutOverwriting)
            case "translate":
                guard #available(macOS 26, *) else { throw SubtitleError.unsupportedSystem }
                let result = try await NativeTranslation.translate(cues: cues(input), source: argument("--source") ?? "",
                    target: argument("--target") ?? "", onProgress: progress)
                try JSONEncoder().encode(result).write(to: output, options: .withoutOverwriting)
            case "burn":
                let mode = argument("--text-mode").flatMap(SubtitleTextMode.init(rawValue:)) ?? .bilingual
                try await SubtitleMedia.burn(input: input, output: output, cues: cues(try file("--cues")), mode: mode, style: style()) { value in
                    progress(.init(stage: "exporting", fraction: value))
                }
            default: throw SubtitleError.operation("未知的视频处理阶段。")
            }
            return 0
        } catch {
            fputs(String(error.localizedDescription.prefix(1_200)) + "\n", stderr)
            return Task.isCancelled || error is CancellationError ? 130 : 1
        }
    }
}
