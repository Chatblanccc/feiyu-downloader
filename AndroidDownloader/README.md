# 飞羽下载 Android 0.1.0-alpha02

面向 Android 10+、ARM64 手机的内部测试版，首测目标为小米 17 Pro Max。首版提供视频下载；六个平台的实际结果见 [验收报告](docs/验收报告.md)，未通过或未执行的项目不表示已支持完成。

本轮在 Android 16 ARM64 模拟器上完成六个平台各两条、共 12 条真实视频下载验证，逐条核验音视频、首中尾解码及公共媒体保存；详细链接和文件回执见随包验收报告。小米真机尚未连接，真实账号登录和 HyperOS 行为仍需后续验收。

## 安装与使用

将 `FeiyuDownload-0.1.0-alpha02-Android-arm64.apk` 传到手机，核对同目录 SHA256SUMS.txt 后打开安装。已安装 alpha01 的手机可直接覆盖安装；新包沿用原签名，versionCode 从 1 升为 2。按 Android 系统提示仅对本次使用的文件管理器授权安装来源，保留系统安全检查。

粘贴链接或整段分享文案，也可在其他应用中选择“分享 → 飞羽下载”。选择最佳画质、1080p 以下、720p 以下或仅音频，解析预览后点击开始下载；多个链接可一起加入串行队列。

画质上限按视频短边计算，例如 720×1280 的竖屏视频属于 720p。网站可用画质以预览返回的信息为准；TikTok 匿名方式使用其官网提供的可下载媒体流。

默认仅使用非计费网络，可在设置中允许移动网络。下载期间显示前台通知，可从任务页或通知中取消。拒绝通知权限时仍可在应用任务页操作，通知的可见位置由 Android 系统决定。系统强停、进程退出、断网或后台时限中断后，需要回到应用手动重试；首版不提供暂停／断点恢复界面。

完成文件保存至系统公共媒体库：视频位于 `Movies/飞羽下载`，音频位于 `Music/飞羽下载`。只有下载组件成功退出、真实媒体时长及流类型核验通过、公共媒体保存核验成功，才显示“已完成”。可打开或通过系统分享面板分享文件；移除记录不删除媒体。

默认不使用任何登录状态。如需登录，在设置中打开对应网站并自行完成登录，再在下载页主动选择“应用内网站会话”。网站拒绝内嵌登录时，可自行导入 Netscape Cookie 文件并选择“导入的 Cookie”；不会读取 Chrome 或其他应用的登录状态。退出网页会话和删除导入文件分别提供入口。

CookieManager 只能获取指定 URL 的 Cookie 请求头，应用内会话快照保守限定为当前网站主机，并不等同于完整浏览器 Cookie 导出。某些网站可能仍需原始 Netscape 文件或无法使用。Cookie 及临时媒体只存手机私有目录，不写入报告或源码。

抖音匿名网页解析需要较新的 Android System WebView；组件过旧时会提示更新。网页解析在独立匿名目录运行，使用限定网站来源的主框架消息，不读取已保存的网站会话。

当前版本不含字幕识别／翻译、直播、播放列表、云同步、组件热更新和自动安装更新。覆盖安装必须使用同一签名的更高 versionCode APK；签名密钥单独保管，不要先卸载旧版本。

## 构建

需要 JDK 21、Android SDK Platform 37.0 / Build Tools 37.0.0。设置 local.properties 的 sdk.dir，或配置 ANDROID_HOME。Gradle Wrapper 固定 8.13 并验证官方 SHA256；Google Maven 提供阿里云镜像回退。

```sh
python3 scripts/setup_macos.py  # Apple Silicon Mac 可选：安装项目内固定工具链
python3 scripts/fetch_runtime.py
./gradlew testDebugUnitTest assembleDebug lintDebug
./gradlew connectedDebugAndroidTest
python3 scripts/build_internal.py --verify
```

fetch_runtime.py 下载固定组件，核对 SHA256，并替换上游 5 个未按 16 KB 对齐的 WebP 库，再检查压缩包内全部 ELF。文件清单见 runtime-lock.json；无须在手机额外安装 Python、FFmpeg 或语言模型。

setup_macos.py 使用 Google 官方校验值验证 SDK（可从镜像下载相同字节），只将 SDK 37.0 的旧版属性元数据归一化以兼容当前固定 sdklib，保留 android.jar 原始内容。工具链均安装在仓库 work/android-toolchain 中。

build_internal.py 首次在 `~/.local/share/feiyu-android/signing/` 创建内测密钥和凭据，以后复用它们。请私下备份整个目录；密钥、密码、本机 SDK、下载的视频及 Cookie 均不提交 Git。产物输出到仓库 outputs/android。

原创安卓集成采用 [GPL-3.0](LICENSE)，第三方来源与补丁见 [THIRD_PARTY.md](docs/THIRD_PARTY.md)。桌面代码的原有许可继续保留。公开发行前还须完成第三方对应源码材料归档及更广泛设备验收。
