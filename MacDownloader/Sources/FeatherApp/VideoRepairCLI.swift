import Darwin
import Foundation
import VideoRepairCore

private final class VideoRepairCLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<VideoRepairExportResult, Error>?
    private var requested = false
    func install(_ task: Task<VideoRepairExportResult, Error>) {
        lock.lock(); self.task = task; let shouldCancel = requested; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func cancel() { lock.lock(); requested = true; let task = task; lock.unlock(); task?.cancel() }
    func clear() { lock.lock(); task = nil; lock.unlock() }
}

enum VideoRepairCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func emit(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        let started = Date()
        do {
            guard let path = argument("--video-repair-integration-test"), !path.isEmpty,
                  let destinationPath = argument("--destination"), !destinationPath.isEmpty else {
                throw VideoRepairError.operation("Usage: --video-repair-integration-test INPUT --destination PATH [--mode both|enhance|mosaic] [--performance balanced|quality|quiet] [--output-size source|fullHD] [--cancel-after SECONDS]")
            }
            let mode = argument("--mode") ?? "both"
            guard let performance = VideoRepairPerformance(rawValue: argument("--performance") ?? "balanced") else {
                throw VideoRepairError.operation("--performance must be balanced, quality, or quiet")
            }
            guard let outputSize = VideoRepairOutputSize(rawValue: argument("--output-size") ?? "source") else {
                throw VideoRepairError.operation("--output-size must be source or fullHD")
            }
            guard ["both", "enhance", "mosaic"].contains(mode) else { throw VideoRepairError.operation("--mode must be both, enhance, or mosaic") }
            let cancelAfter: Double?
            if let raw = argument("--cancel-after") {
                guard let seconds = Double(raw), seconds.isFinite, seconds >= 0, seconds <= 7 * 24 * 60 * 60 else {
                    throw VideoRepairError.operation("--cancel-after must be a finite number from 0 to 604800")
                }
                cancelAfter = seconds
            } else { cancelAfter = nil }
            let request = VideoRepairRequest(input: URL(fileURLWithPath: path), destination: URL(fileURLWithPath: destinationPath, isDirectory: true),
                enhance: mode != "mosaic", repairMosaic: mode != "enhance", performance: performance, outputSize: outputSize)
            let runtime = try VideoRepairRuntime.discover(bundle: .main)
            let engine = VideoRepairEngine(runtime: runtime)
            let receiptURL = request.destination.appendingPathComponent("completion-" + request.id.uuidString + ".json")
            let cancellation = VideoRepairCLICancellation()
            let cancelStage = argument("--cancel-at-stage")
            let task = Task.detached(priority: .utility) {
                try await engine.run(request, receiptURL: receiptURL) { event in
                    if let cancelStage, event.stage == cancelStage { cancellation.cancel() }
                    guard let data = try? JSONEncoder().encode(event) else { return }
                    fputs("FEATHER_VIDEO_REPAIR_EVENT:" + String(decoding: data, as: UTF8.self) + "\n", stderr)
                    fflush(stderr)
                }
            }
            cancellation.install(task)
            let timer: Task<Void, Never>?
            if let seconds = cancelAfter {
                timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); cancellation.cancel() }
                    catch { }
                }
            } else { timer = nil }
            defer { timer?.cancel(); cancellation.clear() }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel() }
            let recovered = try await VideoRepairReceipt.recover(at: receiptURL)
            guard recovered.request == request, result.filesExist() else { throw VideoRepairError.invalidReceipt }
            let encoded = try JSONEncoder().encode(result)
            let resultObject = try JSONSerialization.jsonObject(with: encoded)
            emit(["success": true, "result": resultObject, "receipt": receiptURL.path,
                  "elapsedSeconds": Date().timeIntervalSince(started), "mode": mode,
                  "outputSize": outputSize.rawValue, "performance": request.performance.rawValue, "wholeVideo": true])
            return 0
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            emit(["success": false, "cancelled": cancelled, "error": error.localizedDescription,
                  "elapsedSeconds": Date().timeIntervalSince(started)])
            return cancelled ? 130 : 1
        }
    }
}
