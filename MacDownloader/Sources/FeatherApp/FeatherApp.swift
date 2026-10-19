import AppKit
import DownloadCore
import Foundation
import SwiftUI
import Darwin

@main enum FeatherLauncher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--smoke-test") || arguments.contains("--integration-test") || arguments.contains("--diagnose") || arguments.contains("--ui-lifecycle-test") || arguments.contains("--subtitle-worker") || arguments.contains("--subtitle-capabilities") || arguments.contains("--subtitle-integration-test") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let task = Task {
                let status: Int32
                if arguments.contains("--subtitle-worker") || arguments.contains("--subtitle-capabilities") || arguments.contains("--subtitle-integration-test") {
                    status = await SubtitleCLI.run(arguments)
                } else { status = await FeatherCLI.run(arguments) }
                fflush(stdout)
                exit(status)
            }
            if arguments.contains("--subtitle-worker") {
                // Let native services cancel and release their language reservation
                // before the parent runner's bounded SIGKILL fallback.
                signal(SIGTERM, SIG_IGN)
                let cancellation = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
                cancellation.setEventHandler { task.cancel() }
                cancellation.resume()
                withExtendedLifetime(cancellation) { application.run() }
            } else { application.run() }
        } else {
            AppEmergencyGuard.start()
            FeatherApplication.main()
        }
    }
}

struct FeatherApplication: App {
    @NSApplicationDelegateAdaptor(FeatherAppDelegate.self) private var delegate
    @StateObject private var model = ApplicationModel()
    var body: some Scene {
        WindowGroup("飞羽下载") {
            FeatherRootView().environmentObject(model).environmentObject(model.updater).preferredColorScheme(.light)
                .onAppear {
                    delegate.model = model
                    model.updater.start()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1060, height: 770)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("关于飞羽下载") { model.showAbout = true } }
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: model.updater) }
            CommandGroup(replacing: .appSettings) { Button("下载设置…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command) }
            CommandGroup(after: .pasteboard) {
                Button("粘贴并解析视频链接") { model.paste(); model.resolvePreview() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("新建下载") { model.newDownload() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

@MainActor final class FeatherAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminationRequested = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum FeatherCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--ui-lifecycle-test") {
            let report = await UILifecycleChecks.run()
            emit(report)
            return report["success"] as? Bool == true ? 0 : 1
        }
        if arguments.contains("--smoke-test") || arguments.contains("--diagnose") { return smoke() }
        guard let index = arguments.firstIndex(of: "--integration-test"), arguments.indices.contains(index + 1) else {
            emit(["success": false, "error": "Usage: --integration-test URL [--destination PATH] [--resolve-only] [--quality p720]"])
            return 2
        }
        let input = arguments[index + 1]
        let destination = argument("--destination", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FeatherIntegrationTest", isDirectory: true)
        let quality = argument("--quality", in: arguments).flatMap(DownloadQuality.init(rawValue:)) ?? .p720
        let started = Date()
        do {
            let engine = AppTools.makeEngine()
            let auth: CookieSource
            if let path = argument("--cookies", in: arguments) { auth = .netscapeFile(URL(fileURLWithPath: path)) }
            else { auth = .none }
            let metadata = try await engine.resolve(shareText: input, authentication: auth)
            var report: [String: Any] = [
                "success": true, "stage": "resolved", "sourceURL": metadata.sourceURL.absoluteString,
                "title": metadata.title, "availableHeights": metadata.availableHeights,
                "formatCount": metadata.formats.count, "quality": quality.rawValue,
                "durationSeconds": metadata.duration as Any? ?? NSNull()
            ]
            if !arguments.contains("--resolve-only") {
                let result = try await engine.download(metadata: metadata, quality: quality, directory: destination,
                                                       authentication: auth, onProgress: { _ in })
                let attributes = try FileManager.default.attributesOfItem(atPath: result.fileURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw CLIError.emptyOutput }
                report["stage"] = "downloaded"
                report["file"] = result.fileURL.path
                report["bytes"] = size
            }
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            emit(report)
            return 0
        } catch {
            emit(["success": false, "sourceURL": input, "error": error.localizedDescription,
                  "elapsedSeconds": Date().timeIntervalSince(started)])
            return 1
        }
    }

    private static func smoke() -> Int32 {
        let tools = [
            ("yt-dlp", AppTools.paths.ytDLP, ["--version"]),
            ("ffmpeg", AppTools.paths.ffmpeg, ["-version"]),
            ("ffprobe", AppTools.directory.appendingPathComponent("ffprobe"), ["-version"]),
            ("deno", AppTools.directory.appendingPathComponent("deno"), ["--version"])
        ]
        var results: [[String: Any]] = []
        var success = true
        for (name, url, arguments) in tools {
            do {
                guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError.missingTool(name) }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = url
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                let toolOK = process.terminationStatus == 0 && !output.isEmpty
                success = success && toolOK
                results.append(["name": name, "path": url.path, "success": toolOK,
                                "exitCode": process.terminationStatus,
                                "version": output.split(separator: "\n").first.map(String.init) ?? ""])
            } catch {
                success = false
                results.append(["name": name, "path": url.path, "success": false, "error": error.localizedDescription])
            }
        }
        let sample = ShareLinkParser.urls(in: "分享视频 https://example.com/video/1 与 https://example.org/clip/2")
        success = success && sample.count == 2
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        emit(["success": success, "app": "飞羽下载", "version": AppTools.version, "architecture": architecture,
              "system": ProcessInfo.processInfo.operatingSystemVersionString, "tools": results,
              "shareParserURLCount": sample.count])
        return success ? 0 : 1
    }

    private static func argument(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    private static func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            print("{\"success\":false,\"error\":\"Could not serialize diagnostic output\"}")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
    enum CLIError: LocalizedError {
        case emptyOutput, missingTool(String)
        var errorDescription: String? {
            switch self {
            case .emptyOutput: return "The download did not produce a nonempty file."
            case .missingTool(let name): return "Missing bundled executable: \(name)"
            }
        }
    }
}

/// Offline regression checks use an injected engine and a private temporary history.
/// They never invoke platform tools, browser cookies, or the user's saved downloads.
private actor UILifecycleEngine: DownloadServing {
    private(set) var resolveCalls = 0
    private(set) var downloadCalls = 0
    private var liveResolvers = 0
    private(set) var maximumResolvers = 0
    func resolve(shareText: String, authentication: CookieSource) async throws -> VideoMetadata {
        resolveCalls += 1
        liveResolvers += 1
        maximumResolvers = max(maximumResolvers, liveResolvers)
        defer { liveResolvers -= 1 }
        // Simulate bounded cleanup which does not return immediately on cancellation.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { continuation.resume() }
        }
        let url = URL(string: shareText)!
        return VideoMetadata(id: url.lastPathComponent, sourceURL: url, title: "Offline lifecycle fixture")
    }
    func download(metadata: VideoMetadata, quality: DownloadQuality, directory: URL,
                  authentication: CookieSource, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        downloadCalls += 1
        if metadata.sourceURL.lastPathComponent == "fail" { throw DownloadError.processFailed(1, "offline fixture failure") }
        if metadata.sourceURL.lastPathComponent == "stopped" { throw DownloadError.memoryLimitExceeded }
        if metadata.sourceURL.lastPathComponent == "commit-on-cancel" {
            // Model the engine having already committed its output when cancellation
            // arrives: it still returns a successful result and that result must win.
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { }
            let output = directory.appendingPathComponent(metadata.id + ".mp4")
            try Data(repeating: 1, count: 1_024).write(to: output)
            return DownloadResult(fileURL: output)
        }
        for index in 0..<100_000 {
            onProgress(DownloadProgress(fraction: Double(index) / 100_000, downloadedBytes: Int64(index), totalBytes: 100_000))
        }
        onProgress(DownloadProgress(fraction: 0.99, speedBytesPerSecond: .greatestFiniteMagnitude,
                                    etaSeconds: .greatestFiniteMagnitude, downloadedBytes: 99_000, totalBytes: 100_000))
        try await Task.sleep(nanoseconds: 170_000_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(metadata.id + ".mp4")
        try Data(repeating: 0, count: 1_024).write(to: output)
        return DownloadResult(fileURL: output)
    }
}

@MainActor private enum UILifecycleChecks {
    static func run() async -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherUILifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String: Bool] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let mailbox = ProgressMailbox()
            for index in 0..<1_000_000 { mailbox.submit(DownloadProgress(downloadedBytes: Int64(index))) }
            checks["millionProgressEventsCoalesced"] = mailbox.take()?.downloadedBytes == 999_999 && mailbox.take() == nil
            mailbox.close()
            mailbox.submit(DownloadProgress(downloadedBytes: 1))
            checks["closedMailboxDropsFurtherEvents"] = mailbox.take() == nil
            checks["extremeDurationRejected"] = ApplicationModel.duration(.greatestFiniteMagnitude) == "--:--"
                && ApplicationModel.duration(.nan) == "--:--" && ApplicationModel.duration(178) == "2:58"

            let updatePreviewModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-preview.json"))
            let previewUpdater = AppUpdater(model: updatePreviewModel)
            var previewRelaunched = false
            updatePreviewModel.shareText = "https://example.com/update-preview"
            updatePreviewModel.resolvePreview()
            updatePreviewModel.cancelPreview()
            previewUpdater.prepareToRelaunch { previewRelaunched = true }
            try await Task.sleep(nanoseconds: 20_000_000)
            checks["updateWaitsForCancelledPreviewCleanup"] = updatePreviewModel.hasActiveWorkForUpdate && !previewRelaunched
            try await Task.sleep(nanoseconds: 350_000_000)
            checks["updateContinuesAfterPreviewCleanup"] = previewRelaunched && !updatePreviewModel.hasActiveWorkForUpdate

            let updateDownloadModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-download.json"))
            updateDownloadModel.destination = directory
            let downloadUpdater = AppUpdater(model: updateDownloadModel)
            var downloadRelaunched = false
            updateDownloadModel.shareText = "https://example.com/update-1 https://example.com/update-2"
            updateDownloadModel.enqueueInput()
            downloadUpdater.prepareToRelaunch { downloadRelaunched = true }
            try await Task.sleep(nanoseconds: 100_000_000)
            checks["updateWaitsForQueuedDownloads"] = updateDownloadModel.hasActiveWorkForUpdate && !downloadRelaunched
            try await Task.sleep(nanoseconds: 850_000_000)
            checks["updatePreservesCompletedDownloadsBeforeRelaunch"] = downloadRelaunched && updateDownloadModel.items.count == 2
                && updateDownloadModel.items.allSatisfy { $0.state == .completed && $0.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }

            let abortedModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-aborted.json"))
            abortedModel.destination = directory
            let abortedUpdater = AppUpdater(model: abortedModel)
            var abortedRelaunched = false
            abortedModel.shareText = "https://example.com/update-aborted"
            abortedModel.enqueueInput()
            abortedUpdater.prepareToRelaunch { abortedRelaunched = true }
            try await Task.sleep(nanoseconds: 20_000_000)
            abortedUpdater.handleUpdateAbort(NSError(domain: "OfflineUpdateFixture", code: 1))
            try await Task.sleep(nanoseconds: 600_000_000)
            abortedModel.shareText = "https://example.com/update-after-abort"
            abortedModel.resolvePreview()
            checks["abortedUpdateNeverInstallsAndKeepsTaskAdmissionOpen"] = !abortedRelaunched && !abortedUpdater.isWaitingToRelaunch
                && !abortedUpdater.requiresRestart && abortedModel.isResolving
            await abortedModel.shutdown()

            let recoveryModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-recovery.json"))
            let recoveryUpdater = AppUpdater(model: recoveryModel)
            var recoveryHandlerCalled = false
            recoveryUpdater.prepareToRelaunch { recoveryHandlerCalled = true }
            try await Task.sleep(nanoseconds: 100_000_000)
            recoveryUpdater.handleUpdateAbort(NSError(domain: "OfflineUpdateFixture", code: 2))
            checks["updateAbortAfterShutdownOffersRestartRecovery"] = recoveryHandlerCalled && recoveryUpdater.requiresRestart
                && !recoveryUpdater.isWaitingToRelaunch && recoveryUpdater.status.contains("退出后重新打开")

            let sheetModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-sheet.json"))
            let sheetUpdater = AppUpdater(model: sheetModel)
            sheetModel.showAbout = true
            sheetModel.showSettings = true
            sheetModel.notification = "Offline sheet fixture"
            var sheetStillAttached = true
            var sheetHandlerCalled = false
            sheetUpdater.prepareToRelaunch(presentationIsBlocking: { sheetStillAttached }) { sheetHandlerCalled = true }
            try await Task.sleep(nanoseconds: 150_000_000)
            checks["updateDismissesOwnedSheetsAndWaitsForActualDetachment"] = !sheetModel.showAbout && !sheetModel.showSettings
                && sheetModel.notification == nil && !sheetHandlerCalled && sheetUpdater.status.contains("关闭打开的对话框")
            sheetStillAttached = false
            try await Task.sleep(nanoseconds: 200_000_000)
            checks["updateInvokesInstallerOnlyAfterSheetDetaches"] = sheetHandlerCalled

            let modalAbortModel = ApplicationModel(engine: UILifecycleEngine(), historyFile: directory.appendingPathComponent("update-modal-abort.json"))
            let modalAbortUpdater = AppUpdater(model: modalAbortModel)
            var modalAbortHandlerCalled = false
            var modalAbortAttached = true
            modalAbortUpdater.prepareToRelaunch(presentationIsBlocking: { modalAbortAttached }) { modalAbortHandlerCalled = true }
            try await Task.sleep(nanoseconds: 150_000_000)
            modalAbortUpdater.handleUpdateAbort(NSError(domain: "OfflineUpdateFixture", code: 3))
            modalAbortAttached = false
            try await Task.sleep(nanoseconds: 200_000_000)
            checks["abortedUpdateCannotInstallAfterModalDetaches"] = !modalAbortHandlerCalled && modalAbortUpdater.requiresRestart

            let migrationHistory = directory.appendingPathComponent("legacy-x-errors.json")
            let oldFailure = "视频不可用，可能已删除、设为私密或限制了访问地区。"
            var legacy: [DownloadItem] = []
            for (platform, state, error) in [("X", DownloadItem.State.failed, oldFailure),
                                             ("抖音", .failed, oldFailure),
                                             ("X", .failed, "平台明确提示这个内容已被删除。"),
                                             ("X", .completed, oldFailure),
                                             ("X", .stopped, oldFailure),
                                             ("x", .failed, oldFailure)] {
                var item = DownloadItem(source: "https://example.com/legacy/" + String(legacy.count),
                                        title: "Preserve legacy row", platform: platform, quality: "720p", directory: directory)
                item.state = state
                item.error = error
                item.detail = "Preserve detail"
                item.fraction = 0.42
                item.fileURL = directory.appendingPathComponent("preserved-reference.mp4")
                item.thumbnailURL = URL(string: "https://example.com/thumbnail.jpg")
                legacy.append(item)
            }
            let stableEncoder = JSONEncoder()
            stableEncoder.outputFormatting = [.sortedKeys]
            try stableEncoder.encode(legacy).write(to: migrationHistory)
            let migrationEngine = UILifecycleEngine()
            let migrationModel = ApplicationModel(engine: migrationEngine, historyFile: migrationHistory)
            var expectedMigration = legacy
            expectedMigration[0].error = DownloadError.xMediaVisibilityMessage
            let expectedMigrationData = try stableEncoder.encode(expectedMigration)
            checks["legacyXErrorMigrationChangesOnlyExactFailedRowError"] = try stableEncoder.encode(migrationModel.items) == expectedMigrationData
            let persistedMigration = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: migrationHistory))
            let migrationResolveCalls = await migrationEngine.resolveCalls
            let migrationDownloadCalls = await migrationEngine.downloadCalls
            checks["legacyXErrorMigrationPersistsWithoutStartingRequests"] = try stableEncoder.encode(persistedMigration) == expectedMigrationData
                && migrationResolveCalls == 0 && migrationDownloadCalls == 0
            await migrationModel.shutdown()

            let history = directory.appendingPathComponent("history.json")
            var saved: [DownloadItem] = []
            for state in [DownloadItem.State.queued, .resolving, .downloading, .completed] {
                var item = DownloadItem(source: "https://example.com/restored", title: "Offline history fixture", platform: "Fixture", quality: "best", directory: directory)
                item.state = state
                saved.append(item)
            }
            try JSONEncoder().encode(saved).write(to: history)
            let engine = UILifecycleEngine()
            let model = ApplicationModel(engine: engine, historyFile: history)
            model.destination = directory
            try await Task.sleep(nanoseconds: 100_000_000)
            let startupCalls = await engine.resolveCalls
            checks["restoredWorkRequiresManualRetry"] = model.items.filter { $0.state == .interrupted }.count == 3 && startupCalls == 0
            checks["completedHistoryPreserved"] = model.items.filter { $0.state == .completed }.count == 1

            let restoredID = saved[0].id
            model.retry(restoredID)
            try await Task.sleep(nanoseconds: 400_000_000)
            let callsAfterRetry = await engine.resolveCalls
            checks["restoredRetryCompletesOnce"] = model.items.first(where: { $0.id == restoredID })?.state == .completed
                && callsAfterRetry == 1 && model.items.filter { $0.state == .interrupted }.count == 2

            model.shareText = "https://example.com/first"
            model.resolvePreview()
            try await Task.sleep(nanoseconds: 10_000_000)
            for index in 0..<100 {
                model.shareText = "https://example.com/request-" + String(index)
                model.resolvePreview()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            let maximumResolvers = await engine.maximumResolvers
            let replacementCalls = await engine.resolveCalls
            checks["previewReplacementNeverOverlapsResolvers"] = maximumResolvers == 1 && replacementCalls == callsAfterRetry + 2
            checks["latestPreviewWinsAndTaskFinishes"] = model.preview?.sourceURL.lastPathComponent == "request-99" && !model.isResolving

            model.newDownload()
            model.shareText = "https://example.com/fail"
            model.enqueueInput()
            try await Task.sleep(nanoseconds: 180_000_000)
            let failures = await engine.downloadCalls
            try await Task.sleep(nanoseconds: 200_000_000)
            let callsAfterFailure = await engine.downloadCalls
            checks["failedWorkDoesNotAutoRetry"] = model.items.first?.state == .failed && callsAfterFailure == failures

            model.shareText = "https://example.com/stopped"
            model.enqueueInput()
            try await Task.sleep(nanoseconds: 130_000_000)
            checks["resourceFailureShowsStopped"] = model.items.first?.state == .stopped && model.items.first?.state.canRetry == true

            model.shareText = "https://example.com/flood"
            model.enqueueInput()
            try await Task.sleep(nanoseconds: 10_000_000)
            model.shareText = "https://example.com/preview-during-worker"
            model.resolvePreview()
            try await Task.sleep(nanoseconds: 450_000_000)
            let sharedMaximum = await engine.maximumResolvers
            checks["previewAndWorkerShareResolverCapacity"] = sharedMaximum == 1
            checks["progressFloodTaskCompletes"] = model.items.first?.state == .completed && model.items.first?.fileURL != nil

            model.newDownload()
            model.shareText = "https://example.com/commit-on-cancel"
            model.enqueueInput()
            try await Task.sleep(nanoseconds: 150_000_000)
            let committedID = model.items[0].id
            model.cancel(committedID)
            try await Task.sleep(nanoseconds: 120_000_000)
            let receipts = DownloadCompletionStore(historyURL: history)
            let committedItem = model.items.first(where: { $0.id == committedID })!
            checks["committedSuccessWinsCancellationRace"] = committedItem.state == .completed
                && receipts.recover(id: committedID, source: committedItem.source) == committedItem.fileURL
            var interruptedSnapshot = model.items
            let committedIndex = interruptedSnapshot.firstIndex(where: { $0.id == committedID })!
            interruptedSnapshot[committedIndex].state = .downloading
            interruptedSnapshot[committedIndex].fileURL = nil
            try JSONEncoder().encode(interruptedSnapshot).write(to: history)
            let recovered = ApplicationModel(engine: engine, historyFile: history)
            checks["receiptRecoversCommittedCompletion"] = recovered.items.first(where: { $0.id == committedID })?.state == .completed
                && recovered.items.first(where: { $0.id == committedID })?.fileURL == committedItem.fileURL
            recovered.remove(committedID)
            checks["removingHistoryClearsOnlyItsReceipt"] = receipts.recover(id: committedID, source: committedItem.source) == nil

            var releasable: ApplicationModel? = ApplicationModel(engine: engine, historyFile: directory.appendingPathComponent("release.json"))
            weak var released = releasable
            releasable?.shareText = "https://example.com/release"
            releasable?.resolvePreview()
            try await Task.sleep(nanoseconds: 10_000_000)
            releasable = nil
            checks["pendingPreviewDoesNotRetainModel"] = released == nil
            try await Task.sleep(nanoseconds: 100_000_000)
            var workerOwner: ApplicationModel? = ApplicationModel(engine: engine, historyFile: directory.appendingPathComponent("worker-release.json"))
            weak var releasedWorker = workerOwner
            workerOwner?.shareText = "https://example.com/release-worker"
            workerOwner?.enqueueInput()
            try await Task.sleep(nanoseconds: 10_000_000)
            workerOwner = nil
            checks["pendingWorkerDoesNotRetainModel"] = releasedWorker == nil
            await model.shutdown()
            try await Task.sleep(nanoseconds: 100_000_000)
            return ["success": checks.values.allSatisfy { $0 }, "checks": checks,
                    "maximumConcurrentResolvers": await engine.maximumResolvers,
                    "scope": "offline injected engine; temporary history; no cookies or real downloads"]
        } catch { return ["success": false, "checks": checks, "error": error.localizedDescription] }
    }
}
