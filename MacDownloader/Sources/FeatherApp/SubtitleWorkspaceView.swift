import AppKit
import SwiftUI
import SubtitleCore

@available(macOS 26.0, *)
struct SubtitleWorkspaceView: View {
    @ObservedObject var model: SubtitleApplicationModel
    let downloads: [DownloadItem]
    private var completedVideos: [DownloadItem] {
        Array(downloads.filter { $0.state == .completed && $0.fileURL.map { ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains($0.pathExtension.lowercased()) } == true }.prefix(100))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settings
            if let current = model.current { status(current) }
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(notice).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    Button("关闭提示") { DispatchQueue.main.async { model.notice = nil } }.buttonStyle(.borderless)
                }.font(.system(size: 12)).padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !model.records.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近的字幕任务").font(.system(size: 14, weight: .semibold))
                    ForEach(model.records.prefix(20)) { item in history(item) }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("视频翻译与字幕", systemImage: "captions.bubble").font(.system(size: 16, weight: .semibold))
            Text("在本机识别人声、翻译内容并添加字幕，保留视频原声。首次使用所选语言时，系统可能需要联网准备语言资源。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 10) {
                Image(systemName: "film").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.inputURL?.lastPathComponent ?? "选择一个需要处理的视频").font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(model.inputURL?.deletingLastPathComponent().path ?? "支持本地视频，也可从已下载任务中选择")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("选择视频…") { DispatchQueue.main.async { model.chooseFile() } }.disabled(model.isBusy)
                Menu("已下载") {
                    if completedVideos.isEmpty { Text("暂无已完成的视频") }
                    ForEach(completedVideos) { item in
                        Button(String(item.title.prefix(80))) { DispatchQueue.main.async { if let url = item.fileURL { model.selectFile(url) } } }
                    }
                }.disabled(model.isBusy || completedVideos.isEmpty).fixedSize()
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("视频中的语言").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("视频中的语言", selection: $model.source) {
                        if !model.sourceLanguages.contains(where: { $0.id == model.source }) { Text(model.languagesLoading ? "正在检查本机语言…" : "请选择").tag(model.source) }
                        ForEach(model.sourceLanguages) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("翻译成").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("翻译成", selection: $model.target) {
                        if !model.targetLanguages.contains(where: { $0.id == model.target }) { Text(model.languagesLoading ? "正在检查本机语言…" : "请选择").tag(model.target) }
                        ForEach(model.targetLanguages) { Text($0.name).tag($0.id) }
                    }.labelsHidden().disabled(model.textMode == .original)
                }
            }.disabled(model.isBusy || model.languagesLoading)

            Picker("字幕内容", selection: $model.textMode) {
                ForEach(SubtitleTextMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.isBusy)
            Picker("输出方式", selection: $model.videoMode) {
                ForEach(SubtitleVideoMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(model.isBusy)
            Text(outputExplanation).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).frame(minHeight: 30, alignment: .topLeading)
            SubtitleStyleEditor(style: $model.style, textMode: model.textMode,
                                isEnabled: model.videoMode == .burned && !model.isBusy,
                                appliesToVideo: model.videoMode == .burned)
            if model.sameLanguage && model.textMode != .original {
                Text("源语言和目标语言相同，将生成同语字幕，不进行跨语言翻译。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.destination.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("更改…") { DispatchQueue.main.async { model.chooseDestination() } }.disabled(model.isBusy)
            }
            HStack {
                Text("最长 2 小时 · 原视频保持完整").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.isBusy {
                    Button("取消处理") { DispatchQueue.main.async { model.cancel() } }
                        .disabled(model.current?.state == .cancelling)
                }
                Button(model.isBusy ? "正在处理…" : "开始生成字幕") { DispatchQueue.main.async { model.start() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.06)))
    }

    private var outputExplanation: String {
        switch model.videoMode {
        case .none: return "导出 SRT 字幕文件，可导入播放器或剪辑软件。"
        case .soft: return "导出 SRT 和带可开关字幕的视频；若没有显示字幕，请在播放器中打开字幕轨道。画面和声音保留原编码。"
        case .burned: return "导出 SRT 和字幕直接显示在画面中的视频，方便直接观看和分享。画面会重新编码，最长边 1920 像素；原视频和原声保留。"
        }
    }

    private func status(_ item: SubtitleHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(item.state.title, systemImage: item.state == .completed ? "checkmark.circle.fill" : "captions.bubble")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let fraction = item.fraction { Text("\(Int(min(1, max(0, fraction.isFinite ? fraction : 0)) * 100))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
                removeButton(item)
            }
            if item.state.active {
                ProgressView(value: item.fraction ?? 0, total: 1).progressViewStyle(.linear).frame(height: 6)
            }
            Text(item.error ?? item.detail).font(.system(size: 12)).foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            if let result = item.result, item.state == .completed { resultButtons(result) }
        }.padding(16).background(Color.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func history(_ item: SubtitleHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.request.input.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(item.state.title) · \(item.request.textMode.title) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("再次处理") { DispatchQueue.main.async { model.reuse(item) } }.disabled(model.isBusy)
                removeButton(item)
            }
            if let result = item.result, item.state == .completed { resultButtons(result) }
            else if let error = item.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(13).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private func removeButton(_ item: SubtitleHistoryItem) -> some View {
        Button("移除记录", role: .destructive) { DispatchQueue.main.async { model.remove(item.id) } }
            .buttonStyle(.borderless)
            .disabled(!model.canRemove(item.id))
            .help(model.canRemove(item.id) ? "仅移除任务记录，保留原视频、字幕和导出视频。" : "请先取消处理，等待任务停止后再移除记录。")
            .accessibilityLabel("移除字幕任务记录：\(item.request.input.lastPathComponent)")
    }

    private func resultButtons(_ result: SubtitleExportResult) -> some View {
        HStack(spacing: 12) {
            Button("在 Finder 中显示") { DispatchQueue.main.async { model.reveal(result) } }
            Button("打开字幕") { DispatchQueue.main.async { model.openSubtitles(result) } }
            if result.video != nil { Button("播放视频") { DispatchQueue.main.async { model.openVideo(result) } } }
        }.font(.system(size: 11)).buttonStyle(.borderless)
    }
}
