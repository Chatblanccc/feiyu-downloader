# Android 第三方组件与补丁

Android 模块按 GPL-3.0-only 提供；桌面原创代码的 MIT 声明继续保留。

| 组件 | 固定来源 | 许可与源码 |
| --- | --- | --- |
| Android Python / FFmpeg / QuickJS 运行时 | youtubedl-android 0.18.1 的 arm64 Maven AAR，SHA256 见 runtime-lock.json | [GPL-3.0 / 原始封装](https://github.com/yausername/youtubedl-android/tree/0.18.1)，[Python 构建](https://github.com/yausername/youtubedl-android/blob/0.18.1/BUILD_PYTHON.md)，[FFmpeg 构建](https://github.com/yausername/youtubedl-android/blob/0.18.1/BUILD_FFMPEG.md) |
| yt-dlp / yt-dlp-ejs | 2026.08.19 官方 Unix 包，SHA256 经官方 SHA2-256SUMS 核对 | [yt-dlp 源码及许可](https://github.com/yt-dlp/yt-dlp/tree/2026.08.19)，[EJS 源码](https://github.com/yt-dlp/ejs) |
| WebP / SharpYUV | Termux 官方 libwebp 1.6.0.0.0.1+really1.6.0 aarch64；SHA256 经仓库 Packages 索引核对 | [WebP BSD 源码](https://github.com/webmproject/libwebp/tree/v1.6.0)，[Termux 构建与补丁](https://github.com/termux/termux-packages/tree/master/packages/libwebp) |
| AndroidX / Compose / Kotlin / Coroutines | app/build.gradle.kts 固定版本 | AndroidX、Kotlin、Coroutines 为 Apache-2.0；保留 APK 中依赖许可元数据 |
| 飞羽标志、分享文案解析与抖音观察脚本 | 本仓库桌面实现 | 原始 MIT 声明保留，Android 集成模块按 GPL-3.0 提供 |

Android 补丁没有调用上游在线更新 API。NativeRuntime.kt 参考上游初始化布局后重写执行器：校验原生文件、原子解压、只读库、独立进程组、有界输出、超时与取消。

上游 FFmpeg 压缩包中的 5 个 WebP ELF 不满足 16 KB LOAD 对齐。fetch_runtime.py 只替换这 5 个库，并递归检查包括压缩包内的每一个 ELF；完整文件 SHA256 与检查结果保存在 APK assets/runtime/manifest.json。

FFmpeg、Python、QuickJS 与其链接库继续遵循各自上游许可，Android 模块许可不替代它们。运行时来源、构建入口、确切包和校验值随源码提供；本内测包不代表已完成面向公开发行的完整第三方对应源码归档审计。
