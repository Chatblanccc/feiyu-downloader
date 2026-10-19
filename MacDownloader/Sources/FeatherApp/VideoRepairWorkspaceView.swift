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

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.enhance) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("画质增强").font(.system(size: 13, weight: .medium))
                        Text("使用 AI 改善低清、模糊与压缩噪点，保持原视频尺寸。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch)
                Divider().opacity(0.6)
                Toggle(isOn: $model.repairMosaic) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("局部 AI 修复（实验）").font(.system(size: 13, weight: .medium))
                        Text("自动识别整片中的疑似马赛克区域并用 AI 补画，可能漏检或误检。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
            }.disabled(model.isBusy)

            Text("马赛克遮挡的细节由 AI 推测，无法保证真实还原。建议对照原视频检查结果。")
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
                Button(model.isBusy ? "正在处理…" : "开始整片 AI 修复") { DispatchQueue.main.async { model.start() } }
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
            Text(item.request.input.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
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
                Button("使用这个视频再次处理") { DispatchQueue.main.async { model.reuse(item) } }
                    .font(.system(size: 11)).buttonStyle(.borderless).disabled(model.isBusy)
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
            }
            if let result = item.result, item.state == .completed { resultButtons(result) }
            else { Text(item.error ?? item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(13)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private func modeDescription(_ request: VideoRepairRequest) -> String {
        if request.enhance && request.repairMosaic { return "画质增强 + 局部修复" }
        return request.enhance ? "画质增强" : "局部修复"
    }

    private func resultButtons(_ result: VideoRepairExportResult) -> some View {
        HStack(spacing: 14) {
            Button("在 Finder 中显示") { DispatchQueue.main.async { model.reveal(result) } }
            Button("播放视频") { DispatchQueue.main.async { model.openVideo(result) } }
            Button("查看处理报告") { DispatchQueue.main.async { model.openReport(result) } }
        }.font(.system(size: 11)).buttonStyle(.borderless)
    }
}
