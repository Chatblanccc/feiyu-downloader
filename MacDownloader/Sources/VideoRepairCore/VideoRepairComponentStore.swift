import CryptoKit
import Darwin
import DownloadCore
import Foundation

public struct VideoRepairComponentCatalog: Decodable, Sendable {
    public struct Download: Decodable, Sendable {
        public let id: String
        public let kind: String
        public let filename: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64
    }
    public let schemaVersion: Int
    public let id: String
    public let revision: String
    public let architecture: String
    public let minimumMacOS: String
    public let pythonRelativePath: String
    public let upstreamRelativePath: String
    public let downloads: [Download]
    public var totalDownloadBytes: Int64 { downloads.reduce(0) { $0 + $1.bytes } }

    public static func load(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1_024 * 1_024 else { throw VideoRepairError.runtimeUnavailable }
        let value = try JSONDecoder().decode(Self.self, from: data)
        func simple(_ string: String) -> Bool {
            !string.isEmpty && string.count < 180 && string != "." && string != ".." &&
                string.range(of: "^[A-Za-z0-9_.+\\-]+$", options: .regularExpression) != nil
        }
        guard value.schemaVersion == 1, value.architecture == "arm64",
              simple(value.id), simple(value.revision),
              value.pythonRelativePath == "python/bin/python3", value.upstreamRelativePath == "upstream",
              !value.downloads.isEmpty, value.downloads.count <= 200,
              Set(value.downloads.map { $0.filename.lowercased() }).count == value.downloads.count,
              Set(value.downloads.map(\.id)).count == value.downloads.count,
              value.downloads.filter({ $0.kind == "python" }).count == 1 else { throw VideoRepairError.runtimeUnavailable }
        for file in value.downloads {
            guard simple(file.id), simple(file.filename), file.bytes > 0, file.bytes < 16_000_000_000,
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  file.url.scheme == "https", file.url.host?.isEmpty == false, file.url.user == nil, file.url.password == nil,
                  ["python", "wheel", "source", "model"].contains(file.kind) else { throw VideoRepairError.runtimeUnavailable }
        }
        return value
    }
}

private final class ComponentDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let callback: @Sendable (Int64) -> Void
    init(_ callback: @escaping @Sendable (Int64) -> Void) { self.callback = callback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        callback(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}

/// Installs into a versioned private prefix. An incomplete transaction can never become active.
public struct VideoRepairComponentStore: Sendable {
    public let supportDirectory: URL
    public let resourcesDirectory: URL
    public let engine: VideoRepairEngineKind
    private var catalogURL: URL { resourcesDirectory.appendingPathComponent(engine == .seedvr2 ? "AIComponents/catalog.json" : "AIComponents/catalog-realesrgan.json") }
    public var catalog: VideoRepairComponentCatalog { get throws { try .load(catalogURL) } }
    public var componentRoot: URL { supportDirectory.appendingPathComponent("AI", isDirectory: true) }

    public init(supportDirectory: URL, resourcesDirectory: URL, engine: VideoRepairEngineKind = .seedvr2) {
        self.supportDirectory = supportDirectory; self.resourcesDirectory = resourcesDirectory
        self.engine = engine
    }

    public static var applicationSupportDirectory: URL {
        if let value = ProcessInfo.processInfo.environment["FEATHER_TEST_DATA"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FeatherDownloader", isDirectory: true)
    }

    private func destination(_ catalog: VideoRepairComponentCatalog) -> URL {
        let parent = componentRoot.appendingPathComponent(catalog.id, isDirectory: true)
        if let data = try? Data(contentsOf: parent.appendingPathComponent("active.json")), data.count < 4_096,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let name = object["directory"], name == catalog.revision || name.hasPrefix(catalog.revision + "-"),
           name.range(of: "^[A-Za-z0-9_.+\\-]+$", options: .regularExpression) != nil {
            return parent.appendingPathComponent(name, isDirectory: true)
        }
        return parent.appendingPathComponent(catalog.revision, isDirectory: true)
    }

    public func installedDirectory() throws -> URL? {
        let value = try catalog, directory = destination(value)
        let marker = directory.appendingPathComponent("feather-component.json")
        guard let data = try? Data(contentsOf: marker), data.count < 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["catalogSHA256"] as? String == (try Self.sha256(catalogURL)),
              FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(value.pythonRelativePath).path),
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("component-receipt.json").path) else { return nil }
        let entry = engine == .seedvr2 ? "upstream/inference_cli.py" : "worker.py"
        guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(entry).path),
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("python/lib/python3.11/encodings/__init__.py").path) else { return nil }
        for file in value.downloads where file.kind == "model" {
            let model = directory.appendingPathComponent("models").appendingPathComponent(file.filename)
            guard let size = try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes else { return nil }
        }
        return directory
    }

    public func validatePlatform() throws {
        #if !arch(arm64)
        throw VideoRepairError.operation("SeedVR2 需要 Apple 芯片的 Mac。")
        #endif
        guard engine != .seedvr2 || ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 0, patchVersion: 0)) else {
            throw VideoRepairError.operation("SeedVR2 需要 macOS 14 或更新版本，可继续使用常规增强。")
        }
        guard engine != .seedvr2 || ProcessInfo.processInfo.physicalMemory >= 32 * 1_024 * 1_024 * 1_024 else {
            throw VideoRepairError.operation("本地 SeedVR2 需要至少 32 GB 内存，可继续使用常规增强。")
        }
    }

    public func ensureInstalled(forceRepair: Bool = false, onProgress: @escaping @Sendable (VideoRepairWorkerEvent) -> Void) async throws -> URL {
        try validatePlatform()
        if !forceRepair, let directory = try installedDirectory() { return directory }
        let value = try catalog, fm = FileManager.default
        try fm.createDirectory(at: componentRoot, withIntermediateDirectories: true)
        let lockFD = open(componentRoot.appendingPathComponent(".install.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw VideoRepairError.operation("无法准备 AI 组件目录。") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw VideoRepairError.operation("另一个飞羽进程正在准备 AI 组件，请稍后重试。") }
        defer { flock(lockFD, LOCK_UN) }
        if !forceRepair, let directory = try installedDirectory() { return directory }
        // The exclusive lock proves no other installer can own one of these incomplete prefixes.
        for leftover in try fm.contentsOfDirectory(at: componentRoot, includingPropertiesForKeys: nil)
            where leftover.lastPathComponent.range(of: "^\\.staging-[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil {
            try fm.removeItem(at: leftover)
        }
        let cache = componentRoot.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let missingBytes = value.downloads.reduce(Int64(0)) { sum, file in
            let size = (try? cache.appendingPathComponent(file.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + (Int64(size) == file.bytes ? 0 : file.bytes)
        }
        if let capacity = try? componentRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < missingBytes + 3_000_000_000 {
            throw VideoRepairError.operation("AI 组件和模型还需要约 \(ByteCountFormatter.string(fromByteCount: missingBytes + 3_000_000_000, countStyle: .file)) 可用空间，请清理空间后重试。")
        }
        var completed: Int64 = 0
        for file in value.downloads {
            try Task.checkCancellation()
            let base = completed
            onProgress(.init(stage: "component-downloading", fraction: 0.8 * Double(base) / Double(value.totalDownloadBytes),
                             detail: "正在校验或下载 \(file.filename)…"))
            try await download(file, to: cache.appendingPathComponent(file.filename)) { bytes in
                onProgress(.init(stage: "component-downloading", fraction: 0.8 * Double(base + min(bytes, file.bytes)) / Double(value.totalDownloadBytes),
                    detail: "正在下载 AI 组件：\(ByteCountFormatter.string(fromByteCount: base + min(bytes, file.bytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: value.totalDownloadBytes, countStyle: .file))"))
            }
            completed += file.bytes
        }
        try Task.checkCancellation()
        let staging = componentRoot.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        onProgress(.init(stage: "component-installing", fraction: 0.81, detail: "正在准备独立 Python 和本地 AI 组件…"))
        let python = value.downloads.first { $0.kind == "python" }!
        let runner = FoundationProcessRunner()
        // This exact immutable archive is SHA checked above and fully path/link audited by build-ai-catalog.py.
        let extracted = try await runner.run(.init(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments:
            ["-xzf", cache.appendingPathComponent(python.filename).path, "-C", staging.path, "--no-same-owner"], timeout: 180,
            maximumOutputBytes: 1_024 * 1_024, maximumMemoryBytes: 512 * 1_024 * 1_024))
        guard extracted.exitCode == 0 else { throw VideoRepairError.operation("独立 Python 解压失败，请重新准备组件。") }
        let bootstrap = resourcesDirectory.appendingPathComponent("AIComponents/bootstrap.py")
        let requirements = resourcesDirectory.appendingPathComponent(engine == .seedvr2 ? "AIComponents/locked-requirements.txt" : "AIComponents/locked-requirements-realesrgan.txt")
        var bootstrapArguments = ["-I", bootstrap.path, "install", "--catalog", catalogURL.path, "--downloads", cache.path,
            "--destination", staging.path, "--requirements", requirements.path]
        if engine == .realesrgan { bootstrapArguments += ["--worker-directory", resourcesDirectory.appendingPathComponent("VideoRepairWorker").path] }
        let installed = try await runner.run(.init(executable: staging.appendingPathComponent(value.pythonRelativePath), arguments:
            bootstrapArguments,
            environment: ["PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "PIP_NO_INDEX": "1", "PYTHONPATH": "", "PYTHONHOME": ""],
            timeout: 1_800, maximumOutputBytes: 4 * 1_024 * 1_024, maximumStandardErrorBytes: 1_024 * 1_024,
            maximumMemoryBytes: 3 * 1_024 * 1_024 * 1_024)) { output in
                guard output.channel == .stdout, let data = output.line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (object["type"] as? String ?? object["event"] as? String) == "progress" else { return }
                let stage = object["stage"] as? String ?? "install"
                let phases: [String: (Double, String)] = [
                    "verify": (0.83, "正在校验下载文件…"), "install": (0.86, "正在安装本地运行环境…"),
                    "sign": (0.91, "正在准备本地组件…"), "self-check": (0.95, "正在验证离线运行…"),
                    "manifest": (0.98, "正在保存组件校验记录…")]
                let phase = phases[stage] ?? (0.85, "正在安装和校验本地 AI 组件…")
                onProgress(.init(stage: "component-installing", fraction: phase.0, detail: phase.1))
            }
        guard installed.exitCode == 0,
              fm.isReadableFile(atPath: staging.appendingPathComponent("component-receipt.json").path) else {
            throw VideoRepairError.operation("AI 组件安装或离线自检未通过：" + String(decoding: installed.stderr.suffix(900), as: UTF8.self))
        }
        try Task.checkCancellation()
        let marker: [String: Any] = ["catalogSHA256": try Self.sha256(catalogURL), "id": value.id, "revision": value.revision, "protocol": 1]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: staging.appendingPathComponent("feather-component.json"), options: .atomic)
        let preferred = destination(value)
        let target = fm.fileExists(atPath: preferred.path)
            ? preferred.deletingLastPathComponent().appendingPathComponent(value.revision + "-" + UUID().uuidString)
            : preferred
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Existing paths remain stable for other running processes; switch only this small pointer.
        try fm.moveItem(at: staging, to: target)
        let active = ["directory": target.lastPathComponent]
        try JSONSerialization.data(withJSONObject: active, options: .sortedKeys)
            .write(to: target.deletingLastPathComponent().appendingPathComponent("active.json"), options: .atomic)
        onProgress(.init(stage: "component-ready", fraction: 1, detail: "本地 AI 组件已准备好，之后可离线使用。"))
        return target
    }

    private func download(_ file: VideoRepairComponentCatalog.Download, to destination: URL,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if try await matches(file, at: destination) { progress(file.bytes); return }
            try fm.removeItem(at: destination)
        }
        let resumeURL = destination.appendingPathExtension("resume")
        let delegate = ComponentDownloadProgress(progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90; configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let temporary: URL, response: URLResponse
            if let data = try? Data(contentsOf: resumeURL), data.count <= 2 * 1_024 * 1_024 {
                (temporary, response) = try await session.download(resumeFrom: data, delegate: delegate)
            } else {
                (temporary, response) = try await session.download(from: file.url, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                throw VideoRepairError.operation("组件下载失败，请检查网络后重试。")
            }
            defer { try? fm.removeItem(at: temporary) }
            guard try await matches(file, at: temporary) else {
                try? fm.removeItem(at: resumeURL)
                throw VideoRepairError.operation("组件下载不完整或校验不符：\(file.filename)，请重试。")
            }
            try Task.checkCancellation()
            try fm.moveItem(at: temporary, to: destination)
            try? fm.removeItem(at: resumeURL)
        } catch {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, data.count <= 2 * 1_024 * 1_024 {
                try? data.write(to: resumeURL, options: .atomic)
            } else { try? fm.removeItem(at: resumeURL) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func matches(_ file: VideoRepairComponentCatalog.Download, at url: URL) async throws -> Bool {
        let task = Task.detached(priority: .utility) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(size) == file.bytes else { return false }
            return try Self.sha256(url) == file.sha256
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
