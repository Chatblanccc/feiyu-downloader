import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { LANGUAGES, validateStyle, validateCues, parseSrt, toSrt, toAss } from './document.mjs';
import { createModelManager } from './models.mjs';

const require = createRequire(import.meta.url);
const { runProcess: defaultRunProcess } = require('../core/process.js');
const WORKER = fileURLToPath(new URL('./translation-worker.mjs', import.meta.url));
const MAX_SECONDS = 7200;
const STAGE_MS = 30 * 60 * 1000;
const MEMORY = 2 * 1024 ** 3;

async function boundedJson(file, limit = 2000000) {
  if ((await fs.stat(file)).size > limit) throw new Error('字幕处理结果超出大小限制。');
  return JSON.parse(await fs.readFile(file, 'utf8'));
}

export function validateRequest(value) {
  if (!value || typeof value !== 'object') throw new Error('字幕任务格式不正确。');
  const validLanguage = code => LANGUAGES.some(x => x.code === code);
  if (!validLanguage(value.sourceLanguage) || !validLanguage(value.targetLanguage)) throw new Error('请选择支持的源语言和目标语言。');
  if (!['srt', 'soft', 'burn'].includes(value.outputMode)) throw new Error('请选择字幕导出方式。');
  const textMode = value.textMode ?? (value.bilingual ? 'bilingual' : 'translated');
  if (!['original', 'translated', 'bilingual'].includes(textMode)) throw new Error('请选择字幕内容。');
  if (typeof value.inputPath !== 'string' || !path.isAbsolute(value.inputPath) || typeof value.outputDirectory !== 'string' || !path.isAbsolute(value.outputDirectory)) throw new Error('请选择本机视频和输出文件夹。');
  return { id: typeof value.id === 'string' && /^[a-z0-9-]{1,64}$/i.test(value.id) ? value.id : randomUUID(), inputPath: path.resolve(value.inputPath), outputDirectory: path.resolve(value.outputDirectory), sourceLanguage: value.sourceLanguage, targetLanguage: value.targetLanguage, outputMode: value.outputMode, textMode, bilingual: textMode === 'bilingual', style: validateStyle(value.style) };
}

export function outputDirectoryFor(value) {
  const request = validateRequest(value);
  const stem = path.basename(request.inputPath, path.extname(request.inputPath)).replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').slice(0, 60) || '视频';
  return path.join(request.outputDirectory, `${stem}_字幕_${request.id}`);
}

export function createSubtitleEngine({ tools, modelDirectory, runProcess = defaultRunProcess, modelManager = createModelManager({ directory: modelDirectory }), encoder = process.platform === 'win32' ? 'h264_mf' : 'mpeg4' }) {
  if (!tools?.ffmpeg || !tools.ffprobe || !tools.whisper || !tools.node) throw new Error('字幕工具尚未安装完整。');
  if (!['h264_mf', 'mpeg4', 'libx264'].includes(encoder)) throw new Error('不支持的视频编码器。');
  let busy = false;

  async function run(rawRequest, { signal, onProgress = () => {} } = {}) {
    if (busy) throw new Error('请等待当前字幕任务完成，或先取消它。');
    const request = validateRequest(rawRequest);
    signal?.throwIfAborted();
    busy = true;
    let staging;
    let committed = false;
    let peakMemoryBytes = 0;
    const progress = (stage, fraction, message) => onProgress({ stage, fraction: Math.max(0, Math.min(1, fraction)), message });
    async function child(executable, args, options = {}) {
      signal?.throwIfAborted();
      const result = await runProcess({ executable, args, cwd: staging, signal, captureStdout: true, ...options,
        limits: { totalTimeoutMs: STAGE_MS, maximumMemoryBytes: MEMORY, maximumOutputBytes: 4 * 1024 ** 2, maximumStandardErrorBytes: 128 * 1024, maximumLineBytes: 65536, resourceSampleIntervalMs: process.platform === 'win32' ? 1000 : 250, ...options.limits } });
      peakMemoryBytes = Math.max(peakMemoryBytes, result.peakMemoryBytes || 0);
      signal?.throwIfAborted();
      if (result.exitCode !== 0) {
        const detail = String(result.stderr || '').trim().split('\n').slice(-3).join(' ').slice(0, 500);
        throw new Error(`字幕处理未能完成${detail ? `：${detail}` : '，请重试。'}`);
      }
      return result;
    }
    try {
      progress('models', 0, '检查本机语言包');
      const needsTranslation = request.textMode !== 'original' && request.sourceLanguage !== request.targetLanguage;
      await modelManager.requireReady({ signal, translation: needsTranslation });
      const source = await fs.stat(request.inputPath);
      if (!source.isFile() || source.size === 0) throw new Error('请选择可读取的视频文件。');
      await fs.mkdir(request.outputDirectory, { recursive: true });
      staging = await fs.mkdtemp(path.join(request.outputDirectory, '.feather-subtitle-'));
      const probe = await child(tools.ffprobe, ['-v', 'error', '-show_entries', 'format=duration:stream=codec_type,width,height', '-of', 'json', request.inputPath], { limits: { totalTimeoutMs: 30000, maximumMemoryBytes: 512 * 1024 ** 2, maximumOutputBytes: 262144 } });
      const metadata = JSON.parse(probe.stdout);
      const duration = Number(metadata.format?.duration);
      const video = metadata.streams?.find(x => x.codec_type === 'video');
      if (!video || !metadata.streams?.some(x => x.codec_type === 'audio')) throw new Error('这个视频没有可识别的音轨。');
      if (!Number.isFinite(duration) || duration <= 0 || duration > MAX_SECONDS) throw new Error('首版字幕功能支持最长 2 小时的视频。');
      if (!Number.isInteger(video.width) || !Number.isInteger(video.height) || Math.min(video.width, video.height) < 2 || Math.max(video.width, video.height) > 32768) throw new Error('无法读取这个视频的画面尺寸。');
      const ratio = Math.min(1, 1920 / Math.max(video.width, video.height));
      const width = Math.max(2, Math.floor(video.width * ratio / 2) * 2);
      const height = Math.max(2, Math.floor(video.height * ratio / 2) * 2);
      const cues = [];
      // whisper-cli uses narrow C++ file streams for its output on Windows.
      // Keep every path it opens relative and ASCII, even with a Chinese user
      // name/output folder. Node sets cwd through the Unicode process API.
      await fs.copyFile(modelManager.whisperPath, path.join(staging, 'whisper-model.bin'), constants.COPYFILE_FICLONE);
      const asrDeadline = Date.now() + STAGE_MS;
      for (let offset = 0; offset < duration; offset += 300) {
        const seconds = Math.min(300, duration - offset);
        const remaining = () => {
          const milliseconds = asrDeadline - Date.now();
          if (milliseconds <= 0) throw new Error('语音识别超过 30 分钟，已停止并释放资源。请改用较短的视频。');
          return milliseconds;
        };
        progress('transcribing', 0.05 + 0.45 * offset / duration, '正在本机识别语音');
        await child(tools.ffmpeg, ['-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-threads', '4', '-ss', String(offset), '-i', request.inputPath, '-t', String(seconds), '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', 'audio.wav'], { limits: { totalTimeoutMs: Math.min(remaining(), 180000), maximumMemoryBytes: 768 * 1024 ** 2 } });
        await child(tools.whisper, ['-m', 'whisper-model.bin', '-f', 'audio.wav', '-l', request.sourceLanguage, '-t', '4', '-p', '1', '-bs', '1', '-bo', '1', '-ng', '-osrt', '-of', 'recognized'], { limits: { totalTimeoutMs: remaining(), maximumMemoryBytes: MEMORY } });
        const srtFile = path.join(staging, 'recognized.srt');
        if ((await fs.stat(srtFile)).size > 10000000) throw new Error('语音识别结果过大，已停止。');
        cues.push(...parseSrt(await fs.readFile(srtFile, 'utf8'), offset));
        if (cues.length > 20000) throw new Error('字幕数量超出限制。');
        await Promise.all([fs.rm(path.join(staging, 'audio.wav'), { force: true }), fs.rm(srtFile, { force: true })]);
      }
      await fs.rm(path.join(staging, 'whisper-model.bin'), { force: true });
      let checkedCues = validateCues(cues, duration);
      if (needsTranslation) {
        progress('translating', 0.5, '正在本机翻译字幕');
        const translationRequest = { modelDirectory, sourceLanguage: request.sourceLanguage, targetLanguage: request.targetLanguage, texts: checkedCues.map(x => x.text), outputPath: path.join(staging, 'translated.json') };
        await fs.writeFile(path.join(staging, 'translate-request.json'), JSON.stringify(translationRequest), { mode: 0o600 });
        await child(tools.node, ['--max-old-space-size=512', WORKER, path.join(staging, 'translate-request.json')], {
          env: { ELECTRON_RUN_AS_NODE: '1', OMP_NUM_THREADS: '4', OPENBLAS_NUM_THREADS: '4', NODE_OPTIONS: '' },
          limits: { maximumMemoryBytes: 3 * 1024 ** 3, resourceSampleIntervalMs: process.platform === 'win32' ? 1000 : 100, tickIntervalMs: process.platform === 'win32' ? 250 : 100 },
          onLine(line, channel) {
            if (channel !== 'stdout') return;
            try { const event = JSON.parse(line); if (event.type === 'progress' && event.total === checkedCues.length && event.completed <= event.total) progress('translating', 0.5 + 0.25 * event.completed / event.total, '正在本机翻译字幕'); } catch {}
          },
        });
        const translations = await boundedJson(path.join(staging, 'translated.json'), 6000000);
        if (!Array.isArray(translations) || translations.length !== checkedCues.length || translations.some(x => typeof x !== 'string' || !x.trim() || x.length > 8000)) throw new Error('翻译结果不完整，请重试。');
        checkedCues = checkedCues.map((cue, index) => ({ ...cue, translation: translations[index] }));
      }
      const outputs = ['字幕.srt'];
      await fs.writeFile(path.join(staging, outputs[0]), '\uFEFF' + toSrt(checkedCues, request.bilingual), { flag: 'wx', mode: 0o600 });
      if (request.outputMode === 'burn') {
        progress('exporting', 0.75, '正在生成带字幕视频');
        await fs.writeFile(path.join(staging, 'captions.ass'), toAss(checkedCues, { width, height, style: request.style, bilingual: request.bilingual }), { flag: 'wx', mode: 0o600 });
        let fontsFilter = '';
        if (tools.fonts) {
          const fontsDirectory = path.join(staging, 'fonts');
          await fs.mkdir(fontsDirectory);
          const fontNames = (await fs.readdir(tools.fonts)).filter(name => /\.(?:ttf|otf|ttc)$/i.test(name));
          if (!fontNames.length || fontNames.length > 20) throw new Error('内置字幕字体不完整，请重新安装软件。');
          let totalFontBytes = 0;
          for (const name of fontNames) {
            const stat = await fs.stat(path.join(tools.fonts, name));
            totalFontBytes += stat.size;
            if (!stat.isFile() || totalFontBytes > 50 * 1024 ** 2) throw new Error('内置字幕字体文件异常。');
            await fs.copyFile(path.join(tools.fonts, name), path.join(fontsDirectory, name));
          }
          fontsFilter = ':fontsdir=fonts';
        }
        const quality = encoder === 'libx264' ? ['-preset', 'fast', '-crf', '20'] : encoder === 'mpeg4' ? ['-q:v', '3'] : ['-b:v', '6M'];
        await child(tools.ffmpeg, ['-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-threads', '4', '-i', request.inputPath, '-map', '0:v:0', '-map', '0:a:0?', '-vf', `scale=${width}:${height},ass=captions.ass${fontsFilter}`, '-c:v', encoder, ...quality, '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', '-threads', '4', '带字幕视频.mp4'], { limits: { maximumMemoryBytes: 768 * 1024 ** 2 } });
        outputs.push('带字幕视频.mp4');
      } else if (request.outputMode === 'soft') {
        progress('exporting', 0.75, '正在封装可开关字幕');
        // Matroska safely copies existing codecs without a full video transcode.
        await child(tools.ffmpeg, ['-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-threads', '4', '-i', request.inputPath, '-i', path.join(staging, '字幕.srt'), '-map', '0:v:0', '-map', '0:a:0?', '-map', '1:0', '-c', 'copy', '-c:s', 'copy', '-metadata:s:s:0', `language=${request.textMode === 'original' ? request.sourceLanguage : request.targetLanguage}`, '-disposition:s:0', 'default', '可开关字幕视频.mkv'], { limits: { maximumMemoryBytes: 768 * 1024 ** 2 } });
        outputs.push('可开关字幕视频.mkv');
      }
      signal?.throwIfAborted();
      const currentSource = await fs.stat(request.inputPath);
      if (currentSource.size !== source.size || currentSource.mtimeMs !== source.mtimeMs) throw new Error('源视频在处理期间发生变化，请重新选择后重试。');
      const files = await Promise.all(outputs.map(async name => { const stat = await fs.stat(path.join(staging, name)); if (!stat.isFile() || stat.size === 0) throw new Error('导出文件不完整。'); return { name, size: stat.size }; }));
      // Remove private working texts/audio before committing the result directory.
      for (const name of await fs.readdir(staging)) if (!outputs.includes(name)) await fs.rm(path.join(staging, name), { recursive: true, force: true });
      const receipt = { schemaVersion: 1, id: request.id, completedAt: new Date().toISOString(), request, files, cueCount: checkedCues.length, duration, peakMemoryBytes, source: { size: source.size, mtimeMs: source.mtimeMs } };
      await fs.writeFile(path.join(staging, 'completion.json'), JSON.stringify(receipt, null, 2), { flag: 'wx', mode: 0o600 });
      const directory = outputDirectoryFor(request);
      signal?.throwIfAborted();
      await fs.rename(staging, directory);
      committed = true;
      progress('completed', 1, '字幕处理完成');
      return { directory, files: files.map(x => path.join(directory, x.name)), receiptPath: path.join(directory, 'completion.json'), cueCount: checkedCues.length, duration, style: request.style, peakMemoryBytes };
    } finally {
      if (staging && !committed) await fs.rm(staging, { recursive: true, force: true }).catch(() => {});
      busy = false;
    }
  }
  return { run, prepareModels: options => modelManager.prepare(options), modelsStatus: () => modelManager.status(), languages: LANGUAGES };
}

export { LANGUAGES } from './document.mjs';
