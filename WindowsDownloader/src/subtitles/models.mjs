import fs from 'node:fs/promises';
import { readFileSync, createReadStream } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { LANGUAGES } from './document.mjs';

export const MODEL_ASSETS = Object.freeze(JSON.parse(readFileSync(new URL('./model-manifest.json', import.meta.url), 'utf8')));
const TOTAL_BYTES = MODEL_ASSETS.reduce((total, asset) => total + asset.size, 0);

async function digest(file, signal) {
  const hash = createHash('sha256');
  for await (const block of createReadStream(file, { highWaterMark: 1024 * 1024, signal })) { signal?.throwIfAborted(); hash.update(block); }
  return hash.digest('hex');
}

export function createModelManager({ directory, fetchImpl = fetch, assets = MODEL_ASSETS } = {}) {
  if (typeof directory !== 'string' || !path.isAbsolute(directory)) throw new Error('语言包目录无效。');
  const verified = new Map();
  let preparing = false;
  const fullPath = asset => path.join(directory, ...asset.path.split('/'));
  async function valid(asset, signal, verify = false) {
    try {
      const file = fullPath(asset);
      const stat = await fs.stat(file);
      if (!stat.isFile() || stat.size !== asset.size) return false;
      const key = `${stat.size}:${stat.mtimeMs}`;
      if (!verify || verified.get(asset.path) === key) return true;
      if (await digest(file, signal) !== asset.sha256) return false;
      verified.set(asset.path, key);
      return true;
    } catch (error) { if (signal?.aborted) throw error; return false; }
  }
  async function status() {
    const files = await Promise.all(assets.map(async asset => ({ path: asset.path, size: asset.size, installed: await valid(asset) })));
    return { ready: files.every(x => x.installed), bytesTotal: assets.reduce((n, a) => n + a.size, 0), bytesInstalled: files.filter(x => x.installed).reduce((n, a) => n + a.size, 0), files, languages: LANGUAGES, localOnly: true };
  }
  async function requireReady({ signal, translation = true } = {}) {
    for (const asset of assets.filter(x => translation || x.path.startsWith('whisper/'))) {
      signal?.throwIfAborted();
      if (!(await valid(asset, signal, true))) throw new Error('请先点击「准备语言包」。语言包只需下载一次，视频和字幕会留在本机。');
    }
  }
  async function prepare({ signal, onProgress = () => {}, useMirror = false } = {}) {
    if (preparing) throw new Error('语言包正在准备中，请稍候。');
    signal?.throwIfAborted();
    preparing = true;
    const timeout = AbortSignal.timeout(30 * 60 * 1000);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    let installed = 0;
    try {
      await fs.mkdir(directory, { recursive: true });
      for (const asset of assets) {
        combined.throwIfAborted();
        if (await valid(asset, combined, true)) { installed += asset.size; onProgress({ fraction: installed / assets.reduce((n, a) => n + a.size, 0), bytes: installed, totalBytes: assets.reduce((n, a) => n + a.size, 0), message: '已验证本机语言包' }); continue; }
        const dest = fullPath(asset);
        await fs.mkdir(path.dirname(dest), { recursive: true });
        const temp = `${dest}.partial-${randomUUID()}`;
        let handle;
        try {
          const url = new URL(asset.url);
          if (url.protocol !== 'https:' || url.hostname !== 'huggingface.co' || !/^[a-f0-9]{64}$/.test(asset.sha256) || !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size > 400000000) throw new Error('语言包清单校验失败。');
          // Mirror selection is explicit. Only public model files are downloaded; no local media is sent.
          if (useMirror) url.hostname = 'hf-mirror.com';
          const response = await fetchImpl(url, { signal: combined, redirect: 'follow', headers: { 'User-Agent': 'Feather-Downloader/0.3.0' } });
          if (!response.ok) throw new Error(response.status === 429 ? '语言包服务器暂时限流，请稍后重试。' : `语言包下载失败（${response.status}），请检查网络后重试。`);
          if (!response.body) throw new Error('语言包服务器没有返回文件。');
          const hash = createHash('sha256');
          let received = 0;
          let lastProgress = 0;
          handle = await fs.open(temp, 'wx', 0o600);
          for await (const block of response.body) {
            combined.throwIfAborted();
            received += block.byteLength;
            if (received > asset.size) throw new Error('语言包文件大小异常，已停止下载。');
            hash.update(block);
            await handle.writeFile(block);
            if (Date.now() - lastProgress >= 100) {
              lastProgress = Date.now();
              onProgress({ fraction: (installed + received) / assets.reduce((n, a) => n + a.size, 0), bytes: installed + received, totalBytes: assets.reduce((n, a) => n + a.size, 0), message: '正在下载本机语言包' });
            }
          }
          await handle.sync();
          await handle.close(); handle = null;
          if (received !== asset.size || hash.digest('hex') !== asset.sha256) throw new Error('语言包校验失败，请重试。');
          combined.throwIfAborted();
          // Replacing an incomplete/corrupt language pack never touches user media.
          await fs.rm(dest, { force: true });
          await fs.rename(temp, dest);
          const stat = await fs.stat(dest);
          verified.set(asset.path, `${stat.size}:${stat.mtimeMs}`);
          installed += asset.size;
          onProgress({ fraction: installed / assets.reduce((n, a) => n + a.size, 0), bytes: installed, totalBytes: assets.reduce((n, a) => n + a.size, 0), message: '语言包已校验' });
        } finally { await handle?.close().catch(() => {}); await fs.rm(temp, { force: true }).catch(() => {}); }
      }
      return await status();
    } finally { preparing = false; }
  }
  return { status, prepare, requireReady, whisperPath: path.join(directory, 'whisper', 'ggml-tiny.bin'), totalBytes: TOTAL_BYTES };
}
