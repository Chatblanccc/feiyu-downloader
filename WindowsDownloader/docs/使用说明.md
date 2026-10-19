# 飞羽下载 Windows 版 0.3.0

适用于 Windows 10 / Windows 11 的 Intel、AMD 64 位电脑。安装包内置视频下载、媒体处理、离线语音识别程序和翻译运行时，无须另外安装 Python、Node.js 或 FFmpeg。Windows on ARM 的本机 ARM64 包尚未提供。

## 安装与使用

双击 `FeiyuDownload-0.3.0-Windows-x64-Setup.exe`，选择保存程序的位置即可。安装到当前用户，无须修改系统浏览器或替换 Mac 软件。安装包未使用商业代码签名证书，系统显示的发布者可能为未知；请核对随包的 SHA256SUMS.txt。不要关闭系统安全功能。

下载：粘贴链接或整段分享文案，可批量添加。选择画质、保存位置；需要登录时，由用户主动选择 Chrome、Edge、Firefox 或自己导出的 Cookie 文本。Chrome/Edge 的 Windows 加密或浏览器占用可能使读取失败，可关闭浏览器后再试，或选择 Firefox/自己导出的 Cookie。程序不会因为失败就自动读取浏览器凭据。

任务完成前会核对最终文件。退出后未完成任务保留中断状态，重新打开不会自行继续下载。移除任务仅移除历史记录，不删除已下载的视频。

如首次字幕处理检测到缺少 Microsoft Visual C++ x64 运行库，程序会提供微软官方下载页，由你自行安装后重开；已安装时无需此步骤。运行库不由程序自动安装。

## 视频翻译与字幕

打开“翻译与字幕”，选择本地视频或已下载视频，自由选择源语言和目标语言。提供中、英、日、韩、法、德、西、俄、葡、意、阿拉伯、印地、泰、越南、印度尼西亚、荷兰、土耳其、乌克兰语。

首次点击“准备语言包”后会下载约 685 MiB 的公开模型，显示进度，可取消。模型保存在本机应用数据目录，之后无需重复下载。源视频、提取的音频和字幕文本不上传至识别或翻译服务。下载模型需要能访问 Hugging Face；网络不可用时会明确失败，可联网后重试。翻译完全使用本机 CPU，翻译需要至少 8 GB 内存且启动时可用内存不少于 3.5 GB，推荐 16 GB，处理速度因电脑而异。翻译独立进程的内存监测上限为 3 GiB，识别为 2 GiB，媒体提取为 768 MiB；Windows 上采用定时采样及终止自有进程树，不能视为内核级硬隔离。

- 仅原文：语音识别后生成原语言字幕，不进行翻译。
- 仅译文 / 原文＋译文：本机生成翻译字幕。
- 仅 SRT：生成字幕文件。
- 可开关字幕：生成带字幕轨的 MKV，保留原视频和声音编码。
- 字幕直接显示在画面中：生成 MP4 和 SRT。字幕无黑色底板，保留细描边；可调 60%–200% 字号、自定义颜色和顶部/居中/底部位置，带预览且记住设置。SRT/可开关字幕的外观由播放器控制。

输入最长 2 小时。烧录视频最长边缩至 1920 像素，保留原声。每项识别/翻译/导出有 30 分钟时限；处理时可取消。识别与翻译会有错误，请检查字幕中的人名、数字和时间点后使用。

## 构建

构建需要 Node.js 24/26 和 Python 3，仅构建环境需要这些工具，使用安装包不需要。

固定版本依赖和上游工具的校验和在 package-lock.json、vendor/win-x64/tools-manifest.json 和 src/subtitles/model-manifest.json 中。

```
npm ci --ignore-scripts
node node_modules/electron/install.js
node scripts/fetch-windows-node-deps.cjs
python scripts/fetch-tools.py
npm test
npm run dist:win
```

打包使用 Electron + NSIS，默认不签名。macOS Apple Silicon 没有 Rosetta 时，需要 ARM 原生 NSIS 编译器，通过 ELECTRON_BUILDER_NSIS_DIR 指向私有 NSIS 工具包；不需要修改系统缓存。源码包包含构建说明及第三方许可。模型按固定提交和 SHA256 校验，无需 API Key。

## 验证范围

开发机为 Apple Silicon Mac。真实下载、字幕识别/翻译/导出和窗口交互在这台开发机的跨平台实现上验证；Windows 安装器和依赖另外做静态检查。Windows 实机安装、系统编码器、浏览器登录及真实 Windows 资源上限必须在 Windows 上验收，不能用开发机结果替代。详见随包验收报告。
