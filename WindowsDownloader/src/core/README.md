# Download core

CommonJS entry point: `require('./src/core')`.

```js
const manager = new DownloadManager({
  tools: { ytDlp: absoluteYtDlp, ffmpeg: absoluteFFmpeg, deno: absoluteDeno },
  dataDirectory: applicationDataDirectory,
  downloadDirectory: userSelectedDirectory,
  concurrency: 1,
});
manager.on('change', snapshot => sendToRenderer(snapshot));
manager.on('warning', text => showWarning(text));
await manager.init();
await manager.setOptions({ authentication: { type: 'none' } }); // Default; no browser credentials.
const metadata = await manager.preview(shareText); // Optional. add resolves afresh.
const id = await manager.add(shareText, { quality: 'best' });
await manager.cancel(id);
await manager.retry(id); // Uses the currently selected authentication; never automatic.
await manager.remove(id); // Removes history and completion receipt only. Keeps media.
await manager.close(); // Abort and await helper cleanup before app exit.
```

`setOptions`, `preview`, `add`, `retry`, `cancel`, `remove`, `init`, `close` return promises. `add` returns a task ID. `retry` returns the same ID. `snapshot()` is synchronous and returns an independent copy:

- `{tasks, options, activeCount, previewing}`.
- Options: `{downloadDirectory, quality, authentication, concurrency}`.
- Quality: `best`, `p1080`, `p720`, `audio` (M4A).
- Authentication: `{type:'none'}`, `{type:'browser',browser:'chrome'|'edge'|'firefox'|'brave'|'opera'|'vivaldi'}`, `{type:'file',path:absolutePath}`, or `{type:'session'}` with an injected `sessionAuthentication(sourceURL)` provider. None is the default. Cookies are never read from another browser automatically. On Windows only, a selected browser cookie-loading failure retries once with no cookies and reports a warning. A successful anonymous preview carries this decision into the download. Site/session, network, permission and other extraction failures are not retried by this rule. A selected Netscape cookie file is copied to a private temporary directory because yt-dlp can modify its cookie jar; the copy is removed after use.
- Task: `{id, sourceURL, title, metadata, quality, directory, authentication, status, progress, error, createdAt, updatedAt, filePath, fileSize, completedAt?}`.
- Status: `queued`, `resolving`, `downloading`, `processing`, `completed`, `failed`, `cancelled`, `interrupted`.
- Progress: `{fraction, downloadedBytes, totalBytes, speedBytesPerSecond, etaSeconds, status, item, postprocessor}`; unknown numeric fields are null. Fraction is 0–1. A processing task is not completed even when download fraction reaches 1.
- Error: `{code, message}` or null. Message is already sanitized Chinese text. Do not display raw extractor diagnostics.
- Metadata in history/snapshot excludes CDN stream URLs, thumbnail URLs and raw extractor data. Optional preview returns metadata with formats and thumbnail URL for the current view, without persisting it.

Windows 0.3.2 accepts an injected `anonymousMetadata(sourceURL, {signal})` provider through `DownloadManager` / `DownloadEngine`. For supported Douyin URLs, when yt-dlp exits unsuccessfully after an anonymous extraction attempt, the engine tries this provider automatically. This also applies after the single anonymous retry caused by a selected browser cookie-loading failure. Explicit site sessions, cookie-file authentication and site failures while using successfully loaded browser cookies do not trigger this fallback. Cancellation, resource limits, tool-launch failures and other errors that reject the runner do not trigger it either.

The Electron provider creates a fresh, nonpersistent, in-memory session for each anonymous request. It reads neither Chrome/Edge credentials nor the saved application website session. Extraction is bounded to 35 seconds, accepts cancellation, and destroys its hidden window on success or failure; it then clears session storage and cache. Returned `downloadInfo` supplies the current video's formats to the downloader without another site extraction. This fallback is limited to supported Douyin links and does not guarantee access to login-required, restricted or challenged content. The optional `sessionMetadata(sourceURL, {signal})` provider remains available only when `{type:'session'}` is explicitly selected.

`runProcess({executable,args,cwd?,env?,signal?,captureStdout?,onLine?,limits?,onResourceWarning?})` is shared with subtitle workers. `env` merges with the current process environment. `onLine(line,channel)` gets stdout/stderr independently. `captureStdout` defaults true. Return fields are `{exitCode, signal, stdout, stderr, peakMemoryBytes, durationMs}`. Nonzero exit is returned for the caller to classify; launch/cancel/limit failures reject with `DownloadError`. For Electron's executable as a Node worker set `env: {ELECTRON_RUN_AS_NODE:'1'}`. No shell is used.

Limits use milliseconds/bytes. Defaults: total 90 minutes, download preparation 90 seconds, no actual byte progress 60 seconds, postprocessing 10 minutes, own subprocess tree sampled memory 768 MiB, stdout 8 MiB total, stderr 512 KiB total, line 16 KiB. Metadata explicitly allows up to 16 MiB stdout and 90 seconds. Progress output is streamed rather than retained. Repeated identical byte counters and repeated finished messages do not extend timeouts. The memory monitor samples every 2.5 seconds; three consecutive failures stop the task instead of leaving it unguarded. `progressTracking:true` is only for the documented yt-dlp JSON channels. Subtitle workers should leave it false and select their own stage/byte/memory limits.

A task completes only after successful helper exit, an `after_move` filepath inside the real destination, and a nonempty regular file check. A flushed atomic completion receipt is saved before completion history. Recovery checks the actual file size; interrupted tasks become manual retries. Existing files already delivered at successful helper exit remain completed if cancellation arrives during final verification. No cleanup method deletes user media.

Windows uses a fixed numeric-only PowerShell process inventory and `taskkill /T /F` for the owned tree. POSIX uses a separate process group. The Windows cap is a sampled guard, not a kernel Job Object. A very fast parent exit before the first child sample can leave a descendant outside taskkill's discoverable parent tree; no claim of kernel-enforced isolation should be made. Root-exit inherited pipes, known sampled descendants, inactivity, total duration and output limits are bounded. Kernel Job Object support can replace the injected runner later.

Tests use temporary directories and owned Node children. They never touch user download folders, cookies or app history:

```sh
node --test test/core.test.js
```
