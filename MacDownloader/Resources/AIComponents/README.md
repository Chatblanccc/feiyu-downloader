# 本地 AI 按需组件

应用仅携带清单、安装脚本、修复源码和许可说明。Python、依赖 wheel 和模型由用户首次启用功能时下载到应用私有目录；不上传视频，不使用全局 Python。

## 清单

- `catalog.json` / `locked-requirements.txt`：SeedVR2 3B FP16，Apple Silicon、macOS 14 及以上；CPython 3.11.16、PyTorch 2.14.1。权重独立下载。
- `catalog-realesrgan.json` / `locked-requirements-realesrgan.txt`：原有 Real-ESRGAN / LaMa，Apple Silicon、macOS 13 及以上；CPython 3.11.10、PyTorch 2.6.0。保持旧引擎版本边界。

每个下载项包含固定 URL、SHA-256、精确字节数、许可和版本。GitHub 源码与 Hugging Face 模型使用固定 commit；wheel 来自官方 PyPI 的版本文件地址。解释器 archiveAudit 审核全部成员路径、符号链接、硬链接、特殊文件、重复条目和链接循环。

维护时使用 `MacDownloader/scripts/build-ai-catalog.py`，在已验收环境中生成。应用运行时不解析最新版本，也不执行此维护脚本。重新生成清单后必须重新验收对应组件。

## 安装接口

1. 宿主校验清单内所有下载的精确字节数和 SHA-256。
2. 将清单中唯一 `kind: python` 的已审计固定归档解压到空 staging 目录，得到 `staging/python`。宿主只能解压清单所固定的官方归档。
3. 使用 `staging/python/bin/python3 -I -B bootstrap.py install --catalog … --downloads … --destination staging --requirements …`。标准引擎另外传 `--worker-directory`，指向应用内仅包含小源码的 VideoRepairWorker 目录。
4. 安装脚本重新验哈希，用 `--no-index --require-hashes --only-binary=:all:` 安装本地 wheel。模型优先硬链接，跨卷时复制。随后对所有原生 Mach-O 文件执行 ad-hoc 签名，运行 CPU 导入/算子握手，最后生成包含 receipt 的完整文件摘要。
5. 宿主验证完成后原子激活 staging。取消、失败或校验错误的 staging 不能激活。运行中任务应固定本次组件路径。

标准输出是 NDJSON，事件字段 `event` 为 `progress`、`completed` 或 `error`。progress 的 stage 为 verify/install/sign/self-check/manifest；verify 包含 completed/total/filename。宿主应同时检查进程退出码，不能只凭进度消息判定安装成功。

`bootstrap.py verify --catalog … --destination …` 会逐文件复核最终摘要并重新运行 CPU 握手，可在整体目录移动后验收。`component-manifest.json` 对签名后的文件记录摘要，包含 `component-receipt.json`，不包含 manifest 自身。receipt 内原安装路径仅供诊断；实际启动只使用相对路径。

## 验收边界

开发用 venv 不随应用或组件分发。运行依赖的许可证保留在 Python、wheel 的 dist-info 和组件 licenses 目录中。私有 Python 以 `-I` 运行、pip 禁用索引和配置、Hugging Face 设离线；视频修复阶段不应下载缺失权重。

解释器/依赖安装和移位自检使用 CPU，不等于视频画质、GPU 性能或 macOS 13 实机验收。新引擎不能自动替换旧引擎的 PyTorch 或依赖。
