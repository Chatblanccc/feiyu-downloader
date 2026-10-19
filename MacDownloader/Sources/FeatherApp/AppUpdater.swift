import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns update discovery, download, signature verification and replacement.
/// This adapter only exposes user-initiated checks and protects the app's work.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status = "从 GitHub 检查新版本，确认后下载和重启更新。"
    @Published private(set) var isWaitingToRelaunch = false
    @Published private(set) var requiresRestart = false
    private weak var model: ApplicationModel?
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private var relaunchTask: Task<Void, Never>?
    private var relaunchID: UUID?
    private var shutdownStarted = false

    init(model: ApplicationModel) {
        self.model = model
        super.init()
    }

    func start() {
        guard controller == nil else { return }
        // CLI diagnostics and subtitle subprocesses never instantiate the updater.
        // A bare SwiftPM executable has no updateable application bundle.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            status = "请从完整安装包运行飞羽下载后检查更新。"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        controller.startUpdater()
    }

    func checkForUpdates() {
        start()
        guard canCheckForUpdates, !isWaitingToRelaunch, !requiresRestart else { return }
        status = "正在检查 GitHub 上的最新版本…"
        controller?.checkForUpdates(nil)
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)，可确认下载。"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Sparkle also reports OS/hardware-incompatible releases as no update;
        // retain its reason rather than claiming every case is already current.
        status = String(error.localizedDescription.prefix(240))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        handleUpdateAbort(error)
    }

    func handleUpdateAbort(_ error: Error) {
        relaunchID = nil
        relaunchTask?.cancel()
        relaunchTask = nil
        isWaitingToRelaunch = false
        if shutdownStarted {
            // Shutdown deliberately closes admission permanently. Do not leave a
            // seemingly usable window after a failed installer/termination step.
            requiresRestart = true
            status = "更新未完成。请退出后重新打开飞羽下载，再检查更新。"
            return
        }
        if (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] != nil { return }
        status = "更新未完成：\(String(error.localizedDescription.prefix(240)))"
    }

    func quitForRecovery() { NSApplication.shared.terminate(nil) }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        prepareToRelaunch(installHandler: installHandler)
        return true
    }

    /// Also exercised by the offline lifecycle checks without an update server or
    /// actual process replacement, using the app's real worker and shutdown paths.
    func prepareToRelaunch(installHandler: @escaping () -> Void) {
        guard relaunchTask == nil, !requiresRestart, !shutdownStarted else { return }
        let requestID = UUID()
        relaunchID = requestID
        isWaitingToRelaunch = true
        status = "更新已准备好，等待下载、解析和字幕任务结束后重启。"
        relaunchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep the current work and cancellation controls available while waiting.
            // The final idle check and shutdown flag run on the same main actor, so
            // no new work can slip between them and application replacement.
            while self.model?.hasActiveWorkForUpdate == true {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, self.relaunchID == requestID else { return }
            self.status = "正在保存记录并准备重启更新…"
            self.shutdownStarted = true
            await self.model?.shutdown()
            guard !Task.isCancelled, self.relaunchID == requestID else { return }
            installHandler()
            if self.relaunchID == requestID { self.relaunchTask = nil }
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if updater.requiresRestart {
            Button("退出飞羽下载") { updater.quitForRecovery() }
                .help("退出后重新打开飞羽下载，再检查更新。")
        } else {
            Button("检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates || updater.isWaitingToRelaunch)
        }
    }
}
