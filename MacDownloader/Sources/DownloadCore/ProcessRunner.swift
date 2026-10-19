import Foundation
import Darwin

public struct ProcessCommand: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let maximumLineBytes: Int
    public let captureStandardOutput: Bool
    public let maximumMemoryBytes: UInt64?
    public let preparationTimeout: TimeInterval?
    public let inactivityTimeout: TimeInterval?
    public let processingTimeout: TimeInterval?
    public let progressJSONPrefix: String?

    public init(executable: URL, arguments: [String], environment: [String: String] = [:],
                timeout: TimeInterval = 120, maximumOutputBytes: Int = 32 * 1_024 * 1_024,
                maximumStandardErrorBytes: Int = 1_024 * 1_024, maximumLineBytes: Int = 64 * 1_024,
                captureStandardOutput: Bool = true, maximumMemoryBytes: UInt64? = 768 * 1_024 * 1_024,
                preparationTimeout: TimeInterval? = nil, inactivityTimeout: TimeInterval? = nil,
                processingTimeout: TimeInterval? = nil, progressJSONPrefix: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.timeout = timeout; self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
        self.maximumLineBytes = max(1, maximumLineBytes); self.captureStandardOutput = captureStandardOutput
        self.maximumMemoryBytes = maximumMemoryBytes; self.preparationTimeout = preparationTimeout
        self.inactivityTimeout = inactivityTimeout; self.processingTimeout = processingTimeout
        self.progressJSONPrefix = progressJSONPrefix
    }
}

public struct ProcessOutput: Sendable {
    public enum Channel: Sendable { case stdout, stderr }
    public let channel: Channel
    public let line: String
    public init(channel: Channel, line: String) { self.channel = channel; self.line = line }
}
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}
public protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand, onOutput: @escaping @Sendable (ProcessOutput) -> Void) async throws -> ProcessResult
}

/// Direct argv execution in a separately verified process group. No shell is introduced.
public final class FoundationProcessRunner: ProcessRunning, @unchecked Sendable {
    public init() {}
    public func run(_ command: ProcessCommand,
                    onOutput: @escaping @Sendable (ProcessOutput) -> Void = { _ in }) async throws -> ProcessResult {
        let state = ProcessState(command: command, onOutput: onOutput)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { state.start($0) }
        } onCancel: { state.stop(CancellationError()) }
    }
}

/// Only successfully isolated helper groups enter this registry. The lock spans
/// spawn/registration and final removal before reaping, so emergency signals can
/// never target a recycled group ID or miss a concurrent launch.
enum OwnedDownloadProcesses {
    private static let lock = NSLock()
    private static var shuttingDown = false
    private static var states: [ObjectIdentifier: ProcessState] = [:]

    static func launch(_ state: ProcessState, operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { throw CancellationError() }
        try operation()
        states[ObjectIdentifier(state)] = state
    }

    static func remove(_ state: ProcessState) {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: ObjectIdentifier(state))
    }

    static func beginEmergencyShutdown() {
        lock.lock()
        shuttingDown = true
        let active = Array(states.values)
        // The leader has not been reaped while it remains registered.
        active.forEach { $0.emergencySignal(SIGTERM) }
        lock.unlock()
        // Never acquire a ProcessState lock while holding the registry lock:
        // start() takes these locks in the opposite order.
        active.forEach { $0.stop(CancellationError()) }
    }

    static func killRemaining() {
        lock.lock(); defer { lock.unlock() }
        states.values.forEach { $0.emergencySignal(SIGKILL) }
    }
}

private final class OutputPipe {
    var fd: Int32
    let channel: ProcessOutput.Channel
    let maximumBytes: Int
    let capture: Bool
    var receivedBytes = 0
    var captured = Data()
    var line = Data()
    init(fd: Int32, channel: ProcessOutput.Channel, maximumBytes: Int, capture: Bool) {
        self.fd = fd; self.channel = channel; self.maximumBytes = maximumBytes; self.capture = capture
    }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 }; line.removeAll(keepingCapacity: false) }
    deinit { close() }
}

final class ProcessState: @unchecked Sendable {
    private let command: ProcessCommand
    private let onOutput: @Sendable (ProcessOutput) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var failure: Error?
    private var finished = false
    private var pid: pid_t = 0
    private var ownsProcessGroup = false
    private var streams: [OutputPipe] = []
    private var rootExitCode: Int32?
    private var rootExitedAt: TimeInterval?
    private var cleanupStartedAt: TimeInterval?
    private var sentKill = false
    private var lastResourceSample: TimeInterval = 0
    private var phase = "preparing"
    private var phaseStartedAt: TimeInterval = 0
    private var lastByteProgressAt: TimeInterval = 0
    private var byteCounts: [String: Int64] = [:]
    private var postprocessors = Set<String>()

    init(command: ProcessCommand, onOutput: @escaping @Sendable (ProcessOutput) -> Void) {
        self.command = command; self.onOutput = onOutput
    }
    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock(); self.continuation = continuation
        if let failure {
            finished = true; self.continuation = nil; lock.unlock()
            continuation.resume(throwing: failure); return
        }
        do {
            try OwnedDownloadProcesses.launch(self) { try spawn() }; lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in runLoop() }
        } catch {
            finished = true; self.continuation = nil; lock.unlock()
            continuation.resume(throwing: error)
        }
    }
    func stop(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if !finished && failure == nil { failure = error }
    }
    private var currentFailure: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    private func spawn() throws {
        guard command.executable.isFileURL,
              !command.executable.path.contains("\0"), !command.arguments.contains(where: { $0.contains("\0") }) else {
            throw DownloadError.launchFailed("Invalid executable or argument")
        }
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard Darwin.pipe(&out) == 0 else { throw DownloadError.launchFailed("Cannot open output pipe") }
        guard Darwin.pipe(&err) == 0 else {
            out.forEach { Darwin.close($0) }; throw DownloadError.launchFailed("Cannot open error pipe")
        }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        let flagsResult = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard groupResult == 0 && flagsResult == 0 else {
            (out + err).forEach { Darwin.close($0) }
            throw DownloadError.launchFailed("Could not configure the download process group")
        }
        let values = [command.executable.path] + command.arguments
        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        var argv = values.map { strdup($0) } + [nil]
        var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let result = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { variables in
                posix_spawn(&pid, command.executable.path, &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        Darwin.close(out[1]); Darwin.close(err[1])
        guard result == 0 else {
            Darwin.close(out[0]); Darwin.close(err[0])
            throw DownloadError.launchFailed(String(cString: strerror(result)))
        }
        ownsProcessGroup = pid > 1 && getpgid(pid) == pid && pid != getpgrp()
        if !ownsProcessGroup && pid > 1 && pid != getpgrp() {
            // A fast /usr/bin/true can already be a zombie: Darwin getpgid then
            // returns ESRCH. Successful SETPGROUP plus an unreaped exit confirms
            // the same isolation guarantee without rejecting a completed child.
            var exited = siginfo_t()
            if waitid(P_PID, id_t(pid), &exited, WEXITED | WNOHANG | WNOWAIT) == 0 && exited.si_pid == pid {
                ownsProcessGroup = true
                rootExitCode = exited.si_code == CLD_EXITED ? exited.si_status : 128 + exited.si_status
                rootExitedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        guard ownsProcessGroup else {
            Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0; _ = waitpid(pid, &status, 0)
            Darwin.close(out[0]); Darwin.close(err[0])
            throw DownloadError.launchFailed("Could not isolate the download process group")
        }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        streams = [OutputPipe(fd: out[0], channel: .stdout, maximumBytes: command.maximumOutputBytes, capture: command.captureStandardOutput),
                   OutputPipe(fd: err[0], channel: .stderr, maximumBytes: command.maximumStandardErrorBytes, capture: true)]
    }

    private func runLoop() {
        let started = ProcessInfo.processInfo.systemUptime
        phaseStartedAt = started; lastByteProgressAt = started
        while true {
            // Release Foundation JSON/NSString temporaries during long-running downloads.
            autoreleasepool { iteration(started: started) }
            let now = ProcessInfo.processInfo.systemUptime
            if rootExitCode != nil && streams.allSatisfy({ $0.fd < 0 }) && liveGroupMembers().isEmpty { break }
            if let cleanup = cleanupStartedAt, now - cleanup >= 1.2 { signalOwnedGroup(SIGKILL); break }
        }
        streams.forEach { $0.close() }
        // Remove before waitpid releases the PID reservation. Emergency registry
        // signals and removal share a lock, preventing signals after PID reuse.
        OwnedDownloadProcesses.remove(self)
        // WNOWAIT reserves the leader PID until the last signal, preventing group-ID reuse.
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == 0 {
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                var finalStatus: Int32 = 0
                while waitpid(child, &finalStatus, 0) < 0 && errno == EINTR { }
            }
        }
        let result = ProcessResult(exitCode: rootExitCode ?? -1, stdout: streams[0].captured, stderr: streams[1].captured)
        lock.lock(); finished = true
        let pending = continuation; continuation = nil; let error = failure
        lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume(returning: result) }
    }

    private func iteration(started: TimeInterval) {
        var now = ProcessInfo.processInfo.systemUptime
        observeRootExit(now: now)
        if currentFailure == nil {
            if command.timeout > 0 && now - started >= command.timeout { stop(DownloadError.timedOut) }
            if phase == "preparing", let limit = command.preparationTimeout, now - phaseStartedAt >= limit { stop(DownloadError.stalled) }
            if phase == "downloading", let limit = command.inactivityTimeout, now - lastByteProgressAt >= limit { stop(DownloadError.stalled) }
            if phase == "processing", let limit = command.processingTimeout, now - phaseStartedAt >= limit { stop(DownloadError.stalled) }
            if phase == "preparing", command.preparationTimeout == nil, let limit = command.inactivityTimeout,
               now - lastByteProgressAt >= limit { stop(DownloadError.stalled) }
        }
        if now - lastResourceSample >= 0.5 {
            lastResourceSample = now
            if let limit = command.maximumMemoryBytes {
                var total: UInt64 = 0
                for member in liveGroupMembers() {
                    let rss = Self.residentBytes(member)
                    if rss > limit || total > limit - min(limit, rss) { total = limit + 1; break }
                    total += rss
                }
                if total > limit { stop(DownloadError.memoryLimitExceeded) }
            }
        }
        if let exited = rootExitedAt, now - exited >= 0.25,
           (!streams.allSatisfy({ $0.fd < 0 }) || !liveGroupMembers().isEmpty) { stop(DownloadError.helperDidNotExit) }
        if currentFailure != nil && cleanupStartedAt == nil { cleanupStartedAt = now; signalOwnedGroup(SIGTERM) }
        if let cleanup = cleanupStartedAt, !sentKill && now - cleanup >= 0.35 { sentKill = true; signalOwnedGroup(SIGKILL) }
        var descriptors = streams.map { pollfd(fd: $0.fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
        let ready = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 100) }
        if ready < 0 && errno != EINTR { stop(DownloadError.processFailed(-1, "Output pipe read failed")) }
        for (index, descriptor) in descriptors.enumerated() where descriptor.revents != 0 { drain(streams[index]) }
        now = ProcessInfo.processInfo.systemUptime; observeRootExit(now: now)
    }

    private func drain(_ stream: OutputPipe) {
        guard stream.fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        // Bound work per iteration so log flooding cannot starve watchdog/RSS checks.
        for _ in 0..<8 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(stream.fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stop(DownloadError.processFailed(-1, "Output pipe read failed")); stream.close() }
                return
            }
            if count == 0 {
                if !stream.line.isEmpty && currentFailure == nil { emit(stream, bytes: stream.line) }
                stream.close(); return
            }
            if currentFailure != nil { continue }
            guard count <= stream.maximumBytes - stream.receivedBytes else { stop(DownloadError.outputTooLarge); return }
            stream.receivedBytes += count
            let data = Data(buffer.prefix(count))
            if stream.capture { stream.captured.append(data) }
            var beginning = data.startIndex
            for index in data.indices where data[index] == 0x0A {
                let part = data[beginning..<index]
                guard part.count <= command.maximumLineBytes - stream.line.count else { stop(DownloadError.outputTooLarge); return }
                stream.line.append(part); emit(stream, bytes: stream.line)
                stream.line.removeAll(keepingCapacity: true); beginning = data.index(after: index)
                if currentFailure != nil { return }
            }
            let tail = data[beginning...]
            guard tail.count <= command.maximumLineBytes - stream.line.count else { stop(DownloadError.outputTooLarge); return }
            stream.line.append(tail)
        }
    }
    private func emit(_ stream: OutputPipe, bytes: Data) {
        guard bytes.count <= command.maximumLineBytes, currentFailure == nil else { return }
        autoreleasepool {
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            observeProgress(line); onOutput(ProcessOutput(channel: stream.channel, line: line))
        }
    }
    private func observeProgress(_ line: String) {
        guard let prefix = command.progressJSONPrefix, line.hasPrefix(prefix), line.utf8.count <= 8_192,
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              let progress = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let bytes = (progress["downloaded_bytes"] as? NSNumber)?.int64Value, bytes >= 0 {
            let item = String((progress["item"] as? String ?? "default").prefix(128))
            guard byteCounts[item] != nil || byteCounts.count < 16 else { return }
            if bytes > (byteCounts[item] ?? 0) { byteCounts[item] = bytes; phase = "downloading"; lastByteProgressAt = now }
        }
        if let processor = progress["postprocessor"] as? String, !processor.isEmpty, processor.utf8.count <= 128,
           postprocessors.count < 16, postprocessors.insert(processor).inserted { phase = "processing"; phaseStartedAt = now }
    }
    private func observeRootExit(now: TimeInterval) {
        guard rootExitCode == nil else { return }
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 && info.si_pid == pid {
            rootExitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status; rootExitedAt = now
        } else if result < 0 && errno != EINTR { stop(DownloadError.helperDidNotExit); rootExitCode = -1; rootExitedAt = now }
    }
    private func signalOwnedGroup(_ signal: Int32) {
        guard ownsProcessGroup, pid > 1, pid != getpgrp() else { return }
        // Darwin returns ESRCH for getpgid(zombieLeader) even with WNOWAIT. The PID
        // remains reserved; verify a surviving member still has our recorded PGID.
        guard getpgid(pid) == pid || (rootExitCode != nil && liveGroupMembers().contains(where: { getpgid($0) == pid })) else { return }
        Darwin.kill(-pid, signal)
    }

    /// Called only under the registry lock, before removal/reaping. Does not
    /// depend on the main actor or a potentially blocked output callback.
    func emergencySignal(_ signal: Int32) {
        guard ownsProcessGroup, pid > 1, pid != getpgrp(),
              getpgid(pid) == pid || liveGroupMembers().contains(where: { getpgid($0) == pid }) else { return }
        Darwin.kill(-pid, signal)
    }
    private func liveGroupMembers() -> [pid_t] {
        guard ownsProcessGroup else { return [] }
        var values = [pid_t](repeating: 0, count: 4_096)
        let count = values.withUnsafeMutableBytes { proc_listpgrppids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return values.prefix(Int(count)).filter { member in
            guard member > 0 else { return false }
            var info = proc_bsdinfo()
            let size = withUnsafeMutablePointer(to: &info) { proc_pidinfo(member, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size)) }
            return size == MemoryLayout<proc_bsdinfo>.size && info.pbi_status != UInt32(SZOMB)
        }
    }
    private static func residentBytes(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage.ri_resident_size : 0
    }
}
