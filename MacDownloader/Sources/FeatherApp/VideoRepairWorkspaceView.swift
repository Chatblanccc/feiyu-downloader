import AppKit
import SwiftUI
import VideoRepairCore

struct VideoRepairWorkspaceView: View {
    @ObservedObject var model: VideoRepairApplicationModel
    let downloads: [DownloadItem]

    private var completedVideos: [DownloadItem] {
        Array(downloads.filter {
            $0.state == .completed && $0.fileURL.map {
                ["mp4", "mov", "m4v", "mkv", "webm", "avi", "ts"].contains($0.pathExtension.lowercased())
            } == true
        }.prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let current = model.current, current.state.active { status(current) }
            settings
            if let current = model.current, !current.state.active { status(current) }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle")
                    Text(notice).frame(maxWidth: .infinity, alignment: .leading).lineLimit(4)
                    Button("关闭提示") { DispatchQueue.main.async { model.notice = nil } }.buttonStyle(.borderless)
                }
                .font(.system(size: 12)).padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.records.count > 1 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近的修复任务").font(.system(size: 14, weight: .semibold))
                    ForEach(Array(model.records.dropFirst().prefix(19))) { item in history(item) }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("AI 视频修复", systemImage: "wand.and.stars").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text("整片自动处理").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.blue)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.07), in: Capsule())
            }
            Text("选择视频后，自动检查整个视频并输出修复版本，无需选择片段或框选区域。视频在本机处理。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Picker("修复引擎", selection: $model.engine) {
                    ForEach(VideoRepairEngineKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(model.isBusy)
                Text(model.engine.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label(model.componentReady ? "组件已准备好 · 可离线使用" : "首次使用下载约 " + model.componentDownloadSize,
                          systemImage: model.componentReady ? "checkmark.circle" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if !model.componentReady && !model.isPreparingComponent {
                        Button("下载组件") { DispatchQueue.main.async { model.prepareComponents() } }.disabled(model.isBusy)
                    } else if model.componentReady && !model.isPreparingComponent {
                        Button("重新准备组件") { DispatchQueue.main.async { model.prepareComponents(forceRepair: true) } }.disabled(model.isBusy)
                    }
                }
                if model.isPreparingComponent {
                    if let fraction = model.componentFraction { ProgressView(value: fraction, total: 1) }
                    else { ProgressView().progressViewStyle(.linear) }
                    HStack {
                        Text(model.componentDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        Spacer()
                        Button("取消下载") { DispatchQueue.main.async { model.cancel() } }
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "film").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.inputURL?.lastPathComponent ?? "选择一个需要修复的视频")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(model.inputURL?.deletingLastPathComponent().path ?? "支持本地视频，也可从已下载任务中选择")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("选择视频…") { DispatchQueue.main.async { model.chooseFile() } }.disabled(model.isBusy)
                Menu("已下载") {
                    if completedVideos.isEmpty { Text("暂无已完成的视频") }
                    ForEach(completedVideos) { item in
                        Button(String(item.title.prefix(80))) {
                            DispatchQueue.main.async { if let url = item.fileURL { model.selectFile(url) } }
                        }
                    }
                }.disabled(model.isBusy || completedVideos.isEmpty).fixedSize()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                Picker("增强规格", selection: $model.outputSize) {
                    ForEach(VideoRepairOutputSize.allCases.filter { model.engine == .seedvr2 || $0 != .hd720 }, id: \.self) { size in
                        Text(model.engine == .seedvr2 && size == .source ? "保留原尺寸" : size.title).tag(size)
                    }
                }.pickerStyle(.segmented).disabled(model.isBusy)
                Text(model.engine == .seedvr2 && model.outputSize != .fullHD
                     ? "按 720P 范围重建细节，保留原片比例。保留原尺寸只保留输出尺寸，较大原片的细节可能减少；高分辨率素材建议选 1080P 或常规增强。"
                     : model.outputSize.detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if model.engine == .realesrgan {
              VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.enhance) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.outputSize == .fullHD ? "AI 精细增强（已开启）" : "画质增强").font(.system(size: 13, weight: .medium))
                        Text(model.outputSize == .fullHD ? "AI 生成更高分辨率画面，保留原片比例和方向。" : "使用 AI 改善低清、模糊与压缩噪点，保持原视频尺寸。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).disabled(model.outputSize == .fullHD)
                Divider().opacity(0.6)
                Toggle(isOn: $model.repairMosaic) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("局部 AI 修复（实验）").font(.system(size: 13, weight: .medium))
                        Text("自动识别整片中的疑似马赛克区域并用 AI 补画，可能漏检或误检。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
            }.disabled(model.isBusy)

            if model.outputSize == .source {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("处理模式", selection: $model.performance) {
                        ForEach(VideoRepairPerformance.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.segmented).disabled(model.isBusy)
                    Text(model.performance.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.performance == .quiet
                     ? "1080P 精细增强 · 低负载：减少 CPU 线程并安排短暂休息，整片处理时间会更久。"
                     : "1080P 精细增强 · 画质优先：逐帧运行 AI 超分辨率，计算量高于原尺寸轻度增强。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            } else {
                Text("SeedVR2 按相邻画面推测清晰细节。720P 计算量低于 1080P；本机处理可能远慢于视频时长，任务开始后可以取消。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Text(model.engine == .seedvr2 ? "人脸、文字、小图案和运动纹理可能改变或闪烁，请与原片对照检查。" : "马赛克遮挡的细节由 AI 推测，无法保证真实还原。建议对照原视频检查结果。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.destination.path).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button("更改…") { DispatchQueue.main.async { model.chooseDestination() } }.disabled(model.isBusy)
            }
            HStack(alignment: .center, spacing: 12) {
                Text("导出独立 MP4 · 保留原视频和声音")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(model.isPreparingComponent ? "正在准备组件…" : model.isBusy ? "正在处理…" : model.componentReady ? "开始整片 AI 修复" : "下载组件并开始修复") { DispatchQueue.main.async { model.start() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
            }
            if !model.enhance && !model.repairMosaic {
                Text("请至少开启一种修复方式。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.06)))
    }

    private func status(_ item: VideoRepairHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.state.title, systemImage: item.state == .completed ? "checkmark.circle.fill" : "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let fraction = item.fraction {
                    Text("\(Int(min(1, max(0, fraction.isFinite ? fraction : 0)) * 100))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                if item.state.active {
                    Button("取消处理") { DispatchQueue.main.async { model.cancel() } }
                        .disabled(item.state == .cancelling)
                }
            }
            Text(item.request.input.lastPathComponent + " · " + modeDescription(item.request)).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if item.state.active {
                Group {
                    if let fraction = item.fraction { ProgressView(value: fraction, total: 1) }
                    else { ProgressView() }
                }.progressViewStyle(.linear).frame(height: 6)
            }
            Text(item.error ?? item.detail).font(.system(size: 12))
                .foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            if let result = item.result, item.state == .completed { resultButtons(result) }
            if !item.state.active {
                HStack(spacing: 14) {
                    Button("使用这个视频再次处理") { DispatchQueue.main.async { model.reuse(item) } }
                        .disabled(model.isBusy)
                    removeButton(item)
                }
                .font(.system(size: 11)).buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func history(_ item: VideoRepairHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.request.input.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(item.state.title) · \(modeDescription(item.request)) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("再次处理") { DispatchQueue.main.async { model.reuse(item) } }.disabled(model.isBusy)
                removeButton(item)
            }
            if let result = item.result, item.state == .completed { resultButtons(result) }
            else { Text(item.error ?? item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(13)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private func removeButton(_ item: VideoRepairHistoryItem) -> some View {
        Button("移除记录", role: .destructive) { DispatchQueue.main.async { model.remove(item.id) } }
            .buttonStyle(.borderless)
            .disabled(!model.canRemove(item.id))
            .help("仅移除任务记录，保留原视频、修复视频和处理报告")
            .accessibilityLabel("移除修复任务记录：\(item.request.input.lastPathComponent)")
    }

    private func modeDescription(_ request: VideoRepairRequest) -> String {
        if request.engine == .seedvr2 { return "SeedVR2 深度清晰 · " + (request.outputSize == .source ? "保留原尺寸" : request.outputSize.title) }
        let features = request.enhance && request.repairMosaic ? "画质增强 + 局部修复" : request.enhance ? "画质增强" : "局部修复"
        if request.outputSize == .fullHD {
            return features + " · " + request.outputSize.title + (request.performance == .quiet ? " · 低负载" : " · 画质优先")
        }
        return features + " · " + request.outputSize.title + " · " + request.performance.title
    }

    private func resultButtons(_ result: VideoRepairExportResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(result.inputInfo.width)×\(result.inputInfo.height) → \(result.outputInfo.width)×\(result.outputInfo.height)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 14) {
            Button("在 Finder 中显示") { DispatchQueue.main.async { model.reveal(result) } }
            Button("播放视频") { DispatchQueue.main.async { model.openVideo(result) } }
            Button("查看处理报告") { DispatchQueue.main.async { model.openReport(result) } }
            }.font(.system(size: 11)).buttonStyle(.borderless)
        }
    }
}
