export const LANGUAGES = Object.freeze([
  ['zh', '中文'], ['en', '英语'], ['ja', '日语'], ['ko', '韩语'], ['fr', '法语'],
  ['de', '德语'], ['es', '西班牙语'], ['pt', '葡萄牙语'], ['it', '意大利语'],
  ['ru', '俄语'], ['ar', '阿拉伯语'], ['hi', '印地语'], ['th', '泰语'],
  ['vi', '越南语'], ['id', '印度尼西亚语'], ['tr', '土耳其语'], ['uk', '乌克兰语'], ['nl', '荷兰语'],
].map(([code, name]) => Object.freeze({ code, name })));

export const DEFAULT_STYLE = Object.freeze({ fontScale: 1, colorHex: 'FFFFFF', position: 'bottom' });

export function validateStyle(value = DEFAULT_STYLE) {
  if (!value || typeof value !== 'object') throw new Error('字幕样式格式不正确。');
  const { fontScale = 1, colorHex = 'FFFFFF', position = 'bottom' } = value;
  if (!Number.isFinite(fontScale) || fontScale < 0.6 || fontScale > 2) throw new Error('字幕字号应为 60%–200%。');
  if (typeof colorHex !== 'string' || !/^[0-9a-f]{6}$/i.test(colorHex)) throw new Error('字幕颜色格式不正确。');
  if (!['top', 'center', 'bottom'].includes(position)) throw new Error('请选择字幕位置。');
  return { fontScale, colorHex: colorHex.toUpperCase(), position };
}

export function validateCues(cues, duration = 7200) {
  if (!Array.isArray(cues) || cues.length === 0 || cues.length > 20000) throw new Error('没有识别到可用语音，或字幕数量超出限制。');
  let previous = -1;
  let totalCharacters = 0;
  return cues.map(cue => {
    const { start, end } = cue;
    const text = typeof cue.text === 'string' ? cue.text.replace(/\u0000/g, '').trim() : '';
    totalCharacters += text.length;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || start >= duration || end <= start || start < previous || end > duration + 1 || !text || text.length > 4000 || totalCharacters > 1000000) {
      throw new Error('识别结果的时间或文本格式不正确。');
    }
    previous = start;
    return { start, end: Math.min(end, duration), text, ...(typeof cue.translation === 'string' ? { translation: cue.translation.trim() } : {}) };
  });
}

const srtSeconds = text => {
  const match = /^(\d{1,3}):(\d{2}):(\d{2})[,.](\d{3})$/.exec(text);
  if (!match || +match[2] > 59 || +match[3] > 59) return NaN;
  return +match[1] * 3600 + +match[2] * 60 + +match[3] + +match[4] / 1000;
};

export function parseSrt(value, offset = 0) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 10000000) throw new Error('字幕文件过大。');
  const result = [];
  for (const block of value.replace(/^\uFEFF/, '').replace(/\r/g, '').trim().split(/\n\s*\n/)) {
    const lines = block.split('\n');
    if (/^\d+$/.test(lines[0]?.trim())) lines.shift();
    const match = /^(\S+)\s+-->\s+(\S+)/.exec(lines.shift() ?? '');
    if (!match) continue;
    const start = srtSeconds(match[1]);
    const end = srtSeconds(match[2]);
    const text = lines.join('\n').trim();
    if (Number.isFinite(start) && Number.isFinite(end) && end > start && text) result.push({ start: start + offset, end: end + offset, text });
  }
  return result;
}

function timestamp(seconds, ass = false) {
  const units = Math.round(seconds * (ass ? 100 : 1000));
  const fraction = units % (ass ? 100 : 1000);
  const whole = Math.floor(units / (ass ? 100 : 1000));
  return `${ass ? Math.floor(whole / 3600) : String(Math.floor(whole / 3600)).padStart(2, '0')}:${String(Math.floor(whole / 60) % 60).padStart(2, '0')}:${String(whole % 60).padStart(2, '0')}${ass ? '.' : ','}${String(fraction).padStart(ass ? 2 : 3, '0')}`;
}

function cueText(cue, bilingual) {
  const translated = cue.translation?.trim() || cue.text;
  return bilingual && cue.translation && cue.translation !== cue.text ? `${translated}\n${cue.text}` : translated;
}

export function toSrt(cues, bilingual = false) {
  return cues.map((cue, index) => `${index + 1}\n${timestamp(cue.start)} --> ${timestamp(cue.end)}\n${cueText(cue, bilingual).replace(/<[^>]*>/g, '')}\n`).join('\n');
}

export function toAss(cues, { width, height, style: rawStyle, bilingual = false }) {
  const style = validateStyle(rawStyle);
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 2 || height < 2 || width > 1920 || height > 1920) throw new Error('字幕画面尺寸不正确。');
  const fontSize = Math.round(height * 0.045 * style.fontScale * 10) / 10;
  const color = `&H00${style.colorHex.slice(4, 6)}${style.colorHex.slice(2, 4)}${style.colorHex.slice(0, 2)}`;
  const alignment = { bottom: 2, center: 5, top: 8 }[style.position];
  // ASS BorderStyle 1 draws only an outline. Fully transparent BackColour and Shadow 0 keep the video visible behind text.
  const header = `[Script Info]\nScriptType: v4.00+\nPlayResX: ${width}\nPlayResY: ${height}\nWrapStyle: 0\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Noto Sans CJK SC,${fontSize},${color},${color},&H00000000,&HFF000000,0,0,0,0,100,100,0,0,1,${Math.max(1, fontSize * 0.035).toFixed(1)},0,${alignment},${Math.round(width * 0.05)},${Math.round(width * 0.05)},${Math.round(height * 0.045)},1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n`;
  const escape = value => value.replace(/\\/g, '＼').replace(/{/g, '｛').replace(/}/g, '｝').replace(/\r?\n/g, '\\N');
  return header + cues.map(cue => `Dialogue: 0,${timestamp(cue.start, true)},${timestamp(cue.end, true)},Default,,0,0,0,,${escape(cueText(cue, bilingual))}`).join('\n') + '\n';
}
