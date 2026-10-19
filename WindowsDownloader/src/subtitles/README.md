# Windows subtitle engine

The pipeline runs entirely on the local computer. `prepareModels()` is the only network operation, and downloads only fixed public model assets after the user chooses to prepare language packs. Neither audio, source videos nor subtitle text are uploaded. Inference refuses remote model loading. No API credentials are required.

`createSubtitleEngine({ tools, modelDirectory, runProcess?, encoder? })` exports:

- `modelsStatus()` → `{ ready, bytesTotal, bytesInstalled, files, languages, localOnly }`
- `prepareModels({ signal, onProgress, useMirror = false })` → model status. A mirror is used only when explicitly selected.
- `run(request, { signal, onProgress })` → `{ directory, files, receiptPath, cueCount, duration, style, peakMemoryBytes }`

`request` fields: `id`, absolute `inputPath` and `outputDirectory`, `sourceLanguage` and `targetLanguage` from `LANGUAGES`, `textMode: original | translated | bilingual`, `outputMode: srt | soft | burn`, and `style: { fontScale: 0.6…2, colorHex: six RGB hex characters, position: bottom | center | top }`. `validateRequest()` produces a canonical request. Persist this and `outputDirectoryFor(canonicalRequest)` before starting work. The deterministic result directory contains `completion.json`; it is written and size-checked before the directory is committed with a rename. A controller may recover a completed task only when the receipt request, expected directory, file names and actual file sizes match. A partially written hidden staging directory is not completion evidence.

`tools` supplies physical `ffmpeg`, `ffprobe`, `whisper` and `node` executables. The translation worker and its npm dependencies must be accessible as physical files, not buried in an Electron ASAR. The installed ONNX Runtime package must include `win32/x64` native libraries. The tested dependency is `@huggingface/transformers@3.8.1` with its pinned ONNX Runtime native CPU backend. A `device: wasm` option alone does not select the browser backend in Node.

Whisper recognizes 300-second disk chunks with 4 CPU threads, a 30-minute overall recognition budget, and no GPU backend. Translation processes one short cue at a time in a separate Node process, with 4 ONNX threads, 512 MiB V8 heap and a 3 GiB process-tree memory watchdog threshold enforced by the injected process runner (polling may briefly overshoot; this is not a kernel Job Object). ASR remains limited to 2 GiB and FFmpeg to 768 MiB. Native ONNX initialization is serialized and loads direct file paths to avoid duplicate JS model buffers; observed short startup working sets are approximately 2.3 GiB on macOS. Metadata is limited to 30 seconds. Export is limited to 30 minutes. Cancellation terminates the owned process tree and removes staging files. Video duration is limited to 2 hours; burned output has a maximum longest side of 1920 pixels. A task never overwrites its input.

SRT exports translated, original or bilingual plain text. Soft subtitles use an MKV container with copied original video/audio codecs and an independent SRT track. Burned subtitles use ASS `BorderStyle=1`, transparent `BackColour`, a thin outline and zero shadow, so no black background box is drawn. Windows uses the LGPL FFmpeg `h264_mf` encoder; a controlled test can override `encoder` to `mpeg4` or `libx264`. Encoding availability and Windows Media Foundation behavior require an actual Windows runtime check.

Public source evidence checked 2026-10-19:

- Whisper CPU releases: https://github.com/ggml-org/whisper.cpp/releases
- Whisper multilingual tiny model and MIT metadata: https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1
- M2M100 base model, MIT license and language coverage: https://huggingface.co/facebook/m2m100_418M
- Transformers.js-compatible ONNX conversion: https://huggingface.co/Xenova/m2m100_418M/tree/9c374f0b7aca709787cea97b047bfbbd1559d177
- Node versus browser ONNX backend: https://huggingface.co/docs/transformers.js/en/api/backends/onnx

`model-manifest.json` pins 8 files (717,669,301 bytes), exact repository commits, sizes and SHA-256 hashes. Large-file hashes were corroborated with the model host's Git LFS pointer records, and all acquired bytes are independently hashed before use. Model output may contain recognition or translation errors; users should review exported subtitles.
