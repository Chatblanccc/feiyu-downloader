# 飞羽下载 · Feiyu Downloader

开源桌面视频下载工具，提供视频下载、本地语音识别、翻译和字幕导出。

## 平台

| 版本 | 技术 | 系统要求 | 说明 |
| --- | --- | --- | --- |
| [macOS 0.4.1](MacDownloader/README.md) | SwiftUI / Foundation | Apple Silicon，下载 macOS 13+，字幕 macOS 26+ | 使用 Apple 系统语音识别与翻译 |
| [Windows 0.4.1](WindowsDownloader/README.md) | Electron / Node.js | Windows 10/11 x64 | 使用本地语音识别与翻译模型 |

- 支持粘贴视频链接或完整分享文案，选择画质和保存位置。
- 下载任务、进度、取消与重试；完成时核对实际输出文件。
- 生成 SRT、可开关字幕轨或直接显示在画面中的字幕。
- 可调整字幕字号、颜色与位置。
- 浏览器登录状态仅在用户主动选择后使用。

各网站能否下载取决于内容权限、网站变化和网络环境，不保证所有链接可用。请仅下载自己拥有或已获得许可的内容，并遵守网站条款。

## 检查更新

0.4.0 新增用户主动检查 GitHub Releases 更新，确认下载后重启覆盖升级，保留原数据。Mac 使用 Sparkle 签名更新；Windows 使用 electron-updater / NSIS。发布流程和签名边界见 [更新说明](docs/UPDATES.md)。当前更新包处于发布候选阶段，正式 Release 上线后客户端才会获得更新。

## 从源码构建

克隆本仓库后，在仓库根目录执行 macOS 构建：

```sh
python3 MacDownloader/scripts/fetch-tools.py
python3 MacDownloader/scripts/build-ffmpeg.py
python3 MacDownloader/scripts/build-app.py
python3 MacDownloader/scripts/package-dmg.py
```

macOS 构建需要 Apple Silicon Mac、Xcode Command Line Tools 和 Python 3；字幕开发需要提供相关系统框架的 macOS 26 SDK。

Windows 构建需要 Node.js 24/26 和 Python 3：

```sh
cd WindowsDownloader
npm ci --ignore-scripts
node node_modules/electron/install.js
node scripts/fetch-windows-node-deps.cjs
python scripts/fetch-tools.py
npm test
npm run dist:win
```

构建依赖需从上游下载并通过校验，具体说明见各平台 README。仓库保留字幕字体和第三方许可，不提交依赖缓存、二进制工具、模型、安装包、用户视频或本机验证报告。

## 测试与已知限制

Windows 单元测试：在 `WindowsDownloader` 内运行 `npm test`。macOS 核心测试见 [MacDownloader/README.md](MacDownloader/README.md)。

Windows 0.3.2 已有 Windows 实机下载验证；0.4.0 更新功能的 Windows 真实覆盖升级仍需验收。macOS 安装包使用本地 ad-hoc 签名，尚未进行 Developer ID 签名与公证。测试包和源码不代表已经提供经平台签名的正式安装版本。

## 许可

本项目原创代码采用 [MIT License](LICENSE)。第三方工具、运行时、字体和模型遵循各自许可；MIT 不替代这些许可。来源与声明见 [Windows 第三方说明](WindowsDownloader/docs/third-party/组件来源.md)、[字体许可](WindowsDownloader/docs/fonts-notices/README.md)和各平台依赖获取脚本。

欢迎通过 Issues 报告问题，或提交 Pull Request。报告问题时请注明系统版本、软件版本、复现步骤及已去除个人信息的错误提示；请勿提交 Cookie、账号凭据或私人媒体。
