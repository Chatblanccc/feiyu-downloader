import Foundation

public struct VideoRepairRuntime: Sendable {
    public let python: URL
    public let worker: URL
    public let ffmpeg: URL
    public let ffprobe: URL
    public let environment: [String: String]
    public let engine: VideoRepairEngineKind
    public let modelsDirectory: URL?
    public let upstreamDirectory: URL?

    public init(python: URL, worker: URL, ffmpeg: URL, ffprobe: URL, environment: [String: String] = [:],
                engine: VideoRepairEngineKind = .realesrgan, modelsDirectory: URL? = nil, upstreamDirectory: URL? = nil) {
        self.python = python; self.worker = worker; self.ffmpeg = ffmpeg; self.ffprobe = ffprobe
        self.environment = environment
        self.engine = engine; self.modelsDirectory = modelsDirectory; self.upstreamDirectory = upstreamDirectory
    }

    public init(directory: URL, toolsDirectory: URL) {
        self.init(python: directory.appendingPathComponent("python/bin/python3"),
                  worker: directory.appendingPathComponent("worker.py"),
                  ffmpeg: toolsDirectory.appendingPathComponent("ffmpeg"),
                  ffprobe: toolsDirectory.appendingPathComponent("ffprobe"))
    }

    public static func discover(bundle: Bundle = .main, engine: VideoRepairEngineKind = .realesrgan) throws -> VideoRepairRuntime {
        let environment = ProcessInfo.processInfo.environment
        let resources = bundle.resourceURL ?? bundle.bundleURL
        let tools = environment["FEATHER_TOOLS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resources.appendingPathComponent("tools", isDirectory: true)
        if engine == .seedvr2 {
            let store = VideoRepairComponentStore(supportDirectory: VideoRepairComponentStore.applicationSupportDirectory, resourcesDirectory: resources)
            try store.validatePlatform()
            let override = environment["FEATHER_SEEDVR2_DIR"].flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
            let installed = override == nil ? try store.installedDirectory() : nil
            guard let directory = override ?? installed else { throw VideoRepairError.runtimeUnavailable }
            let runtime = VideoRepairRuntime(python: directory.appendingPathComponent("python/bin/python3"),
                worker: resources.appendingPathComponent("SeedVR2Worker/worker.py"),
                ffmpeg: tools.appendingPathComponent("ffmpeg"), ffprobe: tools.appendingPathComponent("ffprobe"),
                environment: ["MPLCONFIGDIR": directory.appendingPathComponent(".cache/matplotlib").path,
                    "HF_HOME": directory.appendingPathComponent(".cache/huggingface").path,
                    "TORCH_HOME": directory.appendingPathComponent(".cache/torch").path,
                    "XDG_CACHE_HOME": directory.appendingPathComponent(".cache").path],
                engine: engine, modelsDirectory: directory.appendingPathComponent("models"), upstreamDirectory: directory.appendingPathComponent("upstream"))
            try runtime.validate()
            return runtime
        }
        let store = VideoRepairComponentStore(supportDirectory: VideoRepairComponentStore.applicationSupportDirectory,
                                               resourcesDirectory: resources, engine: .realesrgan)
        let installed = try? store.installedDirectory()
        let directory = environment["FEATHER_VIDEO_REPAIR_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? installed ?? resources.appendingPathComponent("VideoRepair", isDirectory: true)
        let runtime = VideoRepairRuntime(directory: directory, toolsDirectory: tools)
        try runtime.validate()
        return runtime
    }

    public func validate() throws {
        let fm = FileManager.default
        guard [python, ffmpeg, ffprobe].allSatisfy({ $0.isFileURL && fm.isExecutableFile(atPath: $0.path) }),
              worker.isFileURL, fm.isReadableFile(atPath: worker.path) else { throw VideoRepairError.runtimeUnavailable }
        if engine == .seedvr2 {
            guard let modelsDirectory, let upstreamDirectory,
                  fm.isReadableFile(atPath: upstreamDirectory.appendingPathComponent("inference_cli.py").path),
                  fm.isReadableFile(atPath: modelsDirectory.appendingPathComponent("seedvr2_ema_3b_fp16.safetensors").path),
                  fm.isReadableFile(atPath: modelsDirectory.appendingPathComponent("ema_vae_fp16.safetensors").path) else { throw VideoRepairError.runtimeUnavailable }
        }
    }
}
