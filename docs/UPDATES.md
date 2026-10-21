# GitHub 更新发布流程

飞羽使用公开仓库 `Chatblanccc/feiyu-downloader` 的 GitHub Releases 分发更新。客户端不包含 GitHub Token，也不需要用户登录 GitHub。

## 用户体验

用户从菜单、设置或“关于”中点击“检查更新”，确认新版本后下载，校验成功后选择重启更新。程序不在启动时自动检查，不自动下载，也不在普通退出时偷偷安装。下载失败或取消时保持现有安装；有下载、解析、字幕、语言包准备等工作时延后或阻止重启安装。

更新仅替换程序。macOS 保持 `io.feather.videodownloader` 与 Application Support/FeatherDownloader，Windows 保持原 appId、产品名和 userData 路径。不要在后续版本随意修改这些标识；数据格式发生变化时提供兼容迁移。

macOS 0.5.4 起，本地 AI 运行环境和模型按需安装到 Application Support/FeatherDownloader/AI，基础 app 不再内嵌这些大文件。组件下载和安装也属于正在进行的工作，更新时需等待结束或取消。组件有独立版本与完整性清单，更新 app 不删除已安装组件或用户媒体；新清单需要新组件时，先验证并安装成功再使用，旧任务记录未保存引擎字段时继续按常规增强读取。

没有更新功能的旧版本，需要覆盖安装一次带更新功能的版本，无需先卸载。Windows ARM64 和 Intel Mac 暂不提供独立安装包。

## 两个平台

- **macOS**：Sparkle 2.10.0。更新源固定为 `https://raw.githubusercontent.com/Chatblanccc/feiyu-downloader/main/updates/macos/appcast.xml`。应用内固定 Ed25519 公钥，更新压缩包和整个 appcast 都必须经过签名；解压前验证。支持的程序位置需可写，从只读 DMG 运行时应先复制到 Applications。
- **Windows**：electron-updater 6.8.9 + NSIS，使用公开 GitHub provider。发布完整 EXE、`latest.yml` 和构建产生的 `.blockmap`；客户端默认完整下载并验证 SHA512。检查只接受稳定版本。安装前保存任务并退出，再由 NSIS 在原位置升级。

默认的双平台正式发布从 **0.4.0** 起共用版本号，使用一个正式 Release（如 `v0.4.0`）。单独更新 macOS 时必须使用下文的 `--mac-only` 流程。不要把只有某个平台资产的 Release 设为 GitHub Latest，否则另一平台的客户端可能找不到更新描述文件。只修改源码或建立 tag 不构成完整更新发布。

## 签名与密钥

`updates/macos/public-key.txt` 是公开公钥，可以进入 Git。对应私钥保存在发布者本机的 `~/Library/Application Support/FeiyuRelease/keys/macos-ed25519.seed`，权限应为 600；离线加密备份，不上传仓库或 Release，也不随程序分发。发布脚本支持 `--key-file` 指定其它安全位置，且复核它与程序公钥相匹配。遗失或更换密钥可能使现有客户端无法验证后续更新，轮换前遵循 Sparkle 的密钥轮换流程。

Sparkle 更新签名与 Apple Developer ID 签名不同。目前 Mac 包仍为 ad-hoc 签名、未经 Apple 公证；Windows 包尚无 Authenticode 发布者签名。Windows 当前依赖 HTTPS GitHub 来源及 SHA512 完整性验证，尚无独立发布者真实性保证。签名不会替代实际系统升级测试，也不要要求用户关闭系统安全功能。准备面向更多用户正式发布时，应补齐平台签名与 Mac 公证。

## 准备一个更新

1. 更新 `MacDownloader/Release.json` 的版本和递增 build，以及 Windows `package.json` / lock 中的版本。两端版本必须一致。
2. 构建、测试两端并检查真实界面，特别是旧版 → 新版、任务记录和设置保留。Windows CI 单元测试不能替代 Windows 实机覆盖升级验收。
3. 准备本次更新说明，确认不含个人信息。
4. 使用官方 Sparkle 2.10.0 的 `bin/sign_update`。其分发包 `Sparkle-2.10.0.tar.xz` 的 SHA256 为 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`；更新工具版本时重新核对官方来源。
5. 在仓库根目录运行：

```sh
python3 scripts/prepare-release.py \
  --mac-app outputs/飞羽下载.app \
  --windows-dir work/windows-build \
  --sparkle-tools work/update-tools/bin \
  --notes docs/releases/0.4.0.md \
  --third-party-source work/ffmpeg-build/ffmpeg-9.0.2.tar.xz \
  --third-party-source work/windows-sources/ffmpeg-669f5ab083.tar.gz
```

脚本复核 Mac 包版本、公钥和代码签名，以及 Windows 安装包的实际字节数/SHA512。生成 Mac ZIP、签名 appcast、Windows 安装文件、第三方对应源码、SHA256SUMS 和资产清单到 `outputs/releases/v版本/`；不上传任何文件。输出目录要为空；若构建变化，使用新目录重新生成，不修改已签名文件。

## 单独准备 macOS 更新

本次 macOS 更新到 **0.5.4（build 16）**，Windows 继续使用 0.4.1，Android 继续使用 0.1.0-alpha02，保持它们的版本与安装包原样。先验收 Mac 应用、DMG 和对应源码包，提交本次源码及[发布说明](releases/0.5.4.md)，然后显式指定：

```sh
python3 scripts/prepare-release.py \
  --mac-only \
  --mac-app /Applications/飞羽下载.app \
  --sparkle-tools work/update-tools/bin \
  --notes docs/releases/0.5.4.md \
  --output work/releases/v0.5.4-online \
  --third-party-source work/ffmpeg-build/ffmpeg-9.0.2.tar.xz \
  --extra-asset outputs/releases/v0.5.4/FeiyuDownload-0.5.4-macOS-arm64.dmg \
  --extra-asset outputs/releases/v0.5.4/FeiyuDownload-0.5.4-macOS-Source.zip
```

以上 app、DMG、源码、签名工具与第三方源码路径须与本次已验收文件的实际位置一致。0.5.4 的本地交付目录已有已验收 DMG 和源码，因此示例使用另一个空目录生成线上更新资产，不覆盖本地交付文件。`--extra-asset` 可以重复提供，也可加入适合公开的验收证据；文件必须为常规文件，不能使用符号链接、隐藏或含控制字符的文件名，且不得与生成的资产重名。`--third-party-source` 仍然必需。输出目录必须为空，包含已签名文件的目录不会被覆盖。

此模式只检查 Mac 的版本、build、应用身份、公钥及签名，生成并验证更新 ZIP 和整个 appcast 的 Ed25519 签名，并将附加资产纳入 SHA256 清单。它不会读取或改写 Windows 更新描述文件。清单包含 `platforms: ["macos"]`、`prerelease: true`、`makeLatest: false` 和精确的 `sourceCommit`。

`stage-release.py` 会按清单的平台检查对应提交中的版本。Mac 单平台清单只能建立带 `--prerelease --latest=false` 的草稿。发布草稿时保留这两个设置，例如在后续验收完成后使用 `gh release edit v0.5.4 --repo Chatblanccc/feiyu-downloader --draft=false --prerelease --latest=false`。不要把 Mac 单平台发布改成 GitHub Latest，也不要把 Windows 0.4.1 的版本或哈希改写成 0.5.4。

Mac 是否收到更新由固定地址的签名 appcast 决定，GitHub 的预发行标签不会阻止 appcast 中列出的版本更新；Windows 稳定版则继续读取现有 GitHub Latest 的 `latest.yml`。必须先公开验证新的 Mac 资产，再把同批已签名 appcast 原样更新到 main。随后核对 Mac 更新源的显示版本为 0.5.4、build 为 16，更新归档的 URL、字节数及 Ed25519 签名均与公开文件匹配；GitHub Latest 仍指向 Windows 所在的正式版，Android 独立发布仍可下载。新安装包和对应源码公开验收后，再按每个平台仅保留最新已验收安装版本的规则清理旧交付资产。

0.5.4 的基础 DMG 约 89 MB，常规 AI 组件首次另下约 492 MB，SeedVR2 组件首次另下约 7.56 GB；不得将用户本机已安装的模型、缓存或私有验收日志追加为 Release 资产。SeedVR2 是有较高内存要求、可能改写细节且耗时较长的实验选项；公开说明需保留系统要求、性能实测和未公证边界。安装、运行与记录保留验收不能替代线上 appcast、公开资产及旧客户端检查更新的验证。

不指定 `--mac-only` 时，`--windows-dir` 仍为必需参数，双平台版本、Windows SHA512／实际字节数和更新文件名等现有验证全部保留。没有 `platforms` 字段的旧清单仍按 Mac + Windows 双平台验证。

## 上传与上线

先提交并推送对应源码，再运行：

```sh
python3 scripts/stage-release.py outputs/releases/v0.4.0
```

这只创建 **Draft Release**，检查更新的用户看不到草稿。上传清单之外的文件不会自动被带上去。

确认安装包、源码许可和验收结果后，双平台发布可将草稿发布为正式稳定 Release；Mac 单平台发布保留预发行和 `latest=false`，按上一节处理。再把同一批资产中的已签名 `appcast.xml` 原样更新到 `updates/macos/appcast.xml` 并合并到 main。最后使用较旧版本的真实安装检查更新，核对版本、更新说明及原数据。检查更新、下载或实际安装各自记录验收范围；用户仅要求准备更新入口时，不代替用户确认安装。不要先更新线上 appcast 再上传不存在的安装包，也不要编辑签名后的 XML。若发布失败，旧安装继续可用；下载源无法连接时应明确报错，不能显示为“已是最新”。

第一版仅提供完整更新包；差分更新、镜像、后台定期提醒可在完成真实升级验收后另行添加。

## 参考

- [Sparkle 安装、更新签名和 appcast](https://sparkle-project.org/documentation/)
- [electron-updater v26 指南](https://www.electron.build/v26/docs/features/auto-update/)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
