// Opt-in integration check. Requires prepared models, native tools and a short
// synthetic English video; never selects or uploads a user's media automatically.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import assert from 'node:assert/strict';
import { runProcess } from '../src/core/process.js';
import { createModelManager } from '../src/subtitles/models.mjs';
import { createSubtitleEngine } from '../src/subtitles/engine.mjs';

const values = new Map();
for (let index = 2; index < process.argv.length; index += 2) values.set(process.argv[index], process.argv[index + 1]);
for (const flag of ['--models', '--input', '--ffmpeg', '--ffprobe', '--whisper', '--output', '--report']) if (!values.get(flag)) throw new Error(`Missing ${flag}`);
const resolve = flag => path.resolve(values.get(flag));
const base = resolve('--output');
await fs.mkdir(base, { recursive: true });
const temporary = await fs.mkdtemp(path.join(base, 'fixed-text-'));
const modelDirectory = resolve('--models');
await createModelManager({ directory: modelDirectory }).requireReady();
const worker = fileURLToPath(new URL('../src/subtitles/translation-worker.mjs', import.meta.url));
const translations = [];
for (const [sourceLanguage, targetLanguage, text] of [
  ['en', 'zh', 'Hello. This is a local video translation test. We keep your video on this computer.'],
  ['ja', 'en', 'こんにちは。これは字幕翻訳の動作確認です。'],
]) {
  const outputPath = path.join(temporary, `${sourceLanguage}-${targetLanguage}.json`);
  const requestPath = path.join(temporary, `${sourceLanguage}-${targetLanguage}-request.json`);
  await fs.writeFile(requestPath, JSON.stringify({ modelDirectory, sourceLanguage, targetLanguage, texts: [text], outputPath }));
  const execution = await runProcess({ executable: process.execPath, args: ['--max-old-space-size=512', worker, requestPath], cwd: temporary, captureStdout: true,
    limits: { totalTimeoutMs: 180000, maximumMemoryBytes: 3 * 1024 ** 3, resourceSampleIntervalMs: 100, tickIntervalMs: 100, maximumOutputBytes: 100000, maximumStandardErrorBytes: 100000 } });
  assert.equal(execution.exitCode, 0, execution.stderr);
  const translated = JSON.parse(await fs.readFile(outputPath, 'utf8'));
  assert.ok(translated[0]?.trim());
  if (targetLanguage === 'zh') assert.match(translated[0], /[\u3400-\u9fff]/);
  translations.push({ sourceLanguage, targetLanguage, source: text, translated, execution });
}
const hashFile = async file => { const hash = createHash('sha256'); for await (const bytes of createReadStream(file)) hash.update(bytes); return hash.digest('hex'); };
const input = resolve('--input');
const originalHash = await hashFile(input);
const tools = { ffmpeg: resolve('--ffmpeg'), ffprobe: resolve('--ffprobe'), whisper: resolve('--whisper'), node: process.execPath };
if (values.get('--fonts')) tools.fonts = resolve('--fonts');
const engine = createSubtitleEngine({ tools, modelDirectory });
const result = await engine.run({ id: `integration-${Date.now()}`, inputPath: input, outputDirectory: base, sourceLanguage: 'en', targetLanguage: 'zh', textMode: 'bilingual', outputMode: 'soft', style: { fontScale: 1.6, colorHex: 'FFE066', position: 'top' } });
assert.equal(await hashFile(input), originalHash);
const srtPath = result.files.find(name => name.endsWith('.srt'));
const videoPath = result.files.find(name => name.endsWith('.mkv'));
const srt = await fs.readFile(srtPath, 'utf8');
assert.match(srt, /[\u3400-\u9fff]/);
assert.match(srt, /local video translation test/i);
const probe = await runProcess({ executable: tools.ffprobe, args: ['-v', 'error', '-show_entries', 'stream=codec_type,codec_name,width,height:format=duration', '-of', 'json', videoPath], captureStdout: true, limits: { totalTimeoutMs: 30000, maximumMemoryBytes: 512 * 1024 ** 2 } });
assert.equal(probe.exitCode, 0);
const media = JSON.parse(probe.stdout);
assert.ok(media.streams.some(stream => stream.codec_type === 'subtitle' && stream.codec_name === 'subrip'));
const decode = await runProcess({ executable: tools.ffmpeg, args: ['-hide_banner', '-nostdin', '-v', 'error', '-i', videoPath, '-map', '0:v:0', '-map', '0:a:0?', '-f', 'null', '-'], captureStdout: true, limits: { totalTimeoutMs: 30000, maximumMemoryBytes: 768 * 1024 ** 2 } });
assert.equal(decode.exitCode, 0, decode.stderr);
const report = { passed: true, platform: process.platform, architecture: process.arch, translations, pipeline: result, srt, sourceUnchanged: true, sourceSha256: originalHash, media, decodeExitCode: decode.exitCode,
  limits: { translationBytes: 3 * 1024 ** 3, asrBytes: 2 * 1024 ** 3, ffmpegBytes: 768 * 1024 ** 2, stageMinutes: 30 },
  resourceScope: 'Fixed-text workers and translation pipeline use 100ms process-tree RSS samples. Samples can miss shorter spikes. The process-tree watchdog remained enabled; it is not a Windows kernel Job Object.',
  runtimeScope: process.platform === 'win32' ? 'Windows runtime execution.' : 'Actual host CPU runtime; this does not establish Windows execution or Windows h264_mf burned export.' };
await fs.writeFile(resolve('--report'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ passed: true, translations: translations.map(value => ({ from: value.sourceLanguage, to: value.targetLanguage, sampledPeakBytes: value.execution.peakMemoryBytes, milliseconds: value.execution.durationMs })), pipelineSampledPeakBytes: result.peakMemoryBytes, cueCount: result.cueCount, report: resolve('--report') }));
