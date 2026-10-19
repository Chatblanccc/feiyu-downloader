import Darwin
import Foundation

/// A last resort for an unresponsive, memory-growing GUI. It never touches
/// WebKit, another application's processes, or the user's downloaded files.
public final class AppEmergencyGuard: @unchecked Sendable {
    private static let production = AppEmergencyGuard()

    /// Call once when starting the GUI. Production thresholds cannot be changed
    /// through environment variables or command-line arguments.
    public static func start() { production.startMonitoring() }

    struct Policy: Sendable {
        var interval: TimeInterval = 1
        var unresponsiveSeconds: TimeInterval = 15
        var residentByteBudget: UInt64 = 512 * 1_024 * 1_024
        var resetGapSeconds: TimeInterval = 10
        var cleanupSeconds: TimeInterval = 1.8
    }

    private let policy: Policy
    private let clock: @Sendable () -> TimeInterval
    private let residentBytes: @Sendable () -> UInt64
    private let enqueueHeartbeat: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let beginShutdown: @Sendable () -> Void
    private let killRemaining: @Sendable () -> Void
    private let terminate: @Sendable (Int32) -> Void
    private let diagnosticURL: URL
    private let queue = DispatchQueue(label: "io.feather.emergency-guard", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var started = false
    private var stopped = false
    private var tripped = false
    private var heartbeatOutstanding = false
    private var lastHeartbeat: TimeInterval
    private var lastSample: TimeInterval

    init(policy: Policy = Policy(),
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         residentBytes: @escaping @Sendable () -> UInt64 = { currentResidentBytes() },
         enqueueHeartbeat: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         beginShutdown: @escaping @Sendable () -> Void = { OwnedDownloadProcesses.beginEmergencyShutdown() },
         killRemaining: @escaping @Sendable () -> Void = { OwnedDownloadProcesses.killRemaining() },
         terminate: @escaping @Sendable (Int32) -> Void = { Darwin._exit($0) },
         diagnosticURL: URL? = nil) {
        self.policy = policy; self.clock = clock; self.residentBytes = residentBytes
        self.enqueueHeartbeat = enqueueHeartbeat; self.beginShutdown = beginShutdown
        self.killRemaining = killRemaining; self.terminate = terminate
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diagnosticURL = diagnosticURL ?? support.appendingPathComponent("FeatherDownloader", isDirectory: true)
            .appendingPathComponent("emergency-stop.json")
        let now = clock(); lastHeartbeat = now; lastSample = now
    }

    deinit { timer?.cancel() }

    func startMonitoring() {
        lock.lock(); defer { lock.unlock() }
        guard !started, !stopped else { return }
        started = true
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + policy.interval, repeating: policy.interval,
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source; source.resume()
    }

    func stopMonitoring() {
        lock.lock(); stopped = true; let source = timer; timer = nil; lock.unlock()
        source?.cancel()
    }

    /// The timer owns sampling; tests may call this directly with an injected clock.
    func sample() {
        let now = clock(), bytes = residentBytes()
        lock.lock()
        guard !stopped, !tripped else { lock.unlock(); return }
        if now < lastSample || now - lastSample > policy.resetGapSeconds {
            // A suspended machine or delayed timer is not evidence of a GUI hang.
            lastHeartbeat = now
        }
        lastSample = now
        let lag = max(0, now - lastHeartbeat)
        let shouldStop = lag >= policy.unresponsiveSeconds && bytes >= policy.residentByteBudget
        let shouldPing = !heartbeatOutstanding && !shouldStop
        if shouldPing { heartbeatOutstanding = true }
        if shouldStop { tripped = true }
        lock.unlock()
        if shouldPing {
            // At most one queued closure, even if the main thread never responds.
            enqueueHeartbeat { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.lastHeartbeat = self.clock(); self.heartbeatOutstanding = false
                self.lock.unlock()
            }
        }
        if shouldStop { emergencyStop(bytes: bytes, lag: lag) }
    }

    private func emergencyStop(bytes: UInt64, lag: TimeInterval) {
        stopMonitoring()
        // The hard deadline is independent of diagnostic I/O and helper cleanup.
        let terminate = self.terminate
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + min(1.8, max(0, policy.cleanupSeconds))) {
            terminate(70)
        }
        let beginShutdown = self.beginShutdown, killRemaining = self.killRemaining
        DispatchQueue.global(qos: .userInitiated).async { beginShutdown() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.45) { killRemaining() }
        writeDiagnostic(bytes: bytes, lag: lag)
    }

    private func writeDiagnostic(bytes: UInt64, lag: TimeInterval) {
        // Fixed keys and numeric values only: no titles, URLs, argv, or cookies.
        let object: [String: Any] = ["reason": "unresponsive_gui_memory_budget", "exitCode": 70,
            "pid": getpid(), "residentBytes": bytes, "residentByteBudget": policy.residentByteBudget,
            "heartbeatLagSeconds": min(lag, 86_400), "heartbeatLimitSeconds": policy.unresponsiveSeconds]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= 4_096 else { return }
        let directory = diagnosticURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Refuse symlinks and atomically create a private replacement file.
        let temporary = directory.appendingPathComponent(".emergency-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        Darwin.close(descriptor)
        if written == data.count { _ = Darwin.rename(temporary.path, diagnosticURL.path) }
        _ = Darwin.unlink(temporary.path)
    }

    static func currentResidentBytes() -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage.ri_resident_size : 0
    }
}
