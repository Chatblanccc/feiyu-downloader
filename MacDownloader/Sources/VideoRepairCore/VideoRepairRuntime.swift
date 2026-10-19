import Foundation

public struct VideoRepairRuntime: Sendable {
    public let python: URL
    public let worker: URL
    public let ffmpeg: URL
    public let ffprobe: URL
    public let environment: [String: String]

    public init(python: URL, worker: URL, ffmpeg: URL, ffprobe: URL, environment: [String: String] = [:]) {
        self.python = python; self.worker = worker; self.ffmpeg = ffmpeg; self.ffprobe = ffprobe
        self.environment = environment
    }

    public init(directory: URL, toolsDirectory: URL) {
        self.init(python: directory.appendingPathComponent("python/bin/python3"),
                  worker: directory.appendingPathComponent("worker.py"),
                  ffmpeg: toolsDirectory.appendingPathComponent("ffmpeg"),
                  ffprobe: toolsDirectory.appendingPathComponent("ffprobe"))
    }

    public static func discover(bundle: Bundle = .main) throws -> VideoRepairRuntime {
        let environment = ProcessInfo.processInfo.environment
        let resources = bundle.resourceURL ?? bundle.bundleURL
        let directory = environment["FEATHER_VIDEO_REPAIR_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resources.appendingPathComponent("VideoRepair", isDirectory: true)
        let tools = environment["FEATHER_TOOLS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resources.appendingPathComponent("tools", isDirectory: true)
        let runtime = VideoRepairRuntime(directory: directory, toolsDirectory: tools)
        try runtime.validate()
        return runtime
    }

    public func validate() throws {
        let fm = FileManager.default
        guard [python, ffmpeg, ffprobe].allSatisfy({ $0.isFileURL && fm.isExecutableFile(atPath: $0.path) }),
              worker.isFileURL, fm.isReadableFile(atPath: worker.path) else { throw VideoRepairError.runtimeUnavailable }
    }
}
