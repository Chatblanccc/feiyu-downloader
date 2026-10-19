'use strict';
const { DownloadError } = require('./core/protocol');

function douyinVideoID(value) {
  try {
    const url = new URL(value), query = url.searchParams.get('modal_id');
    return url.pathname.match(/\/video\/(\d+)(?:\/|$)/)?.[1] || (/^\d+$/.test(query || '') ? query : null);
  } catch { return null; }
}
function supportsDouyinURL(value) {
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password &&
      /(^|\.)(douyin\.com|iesdouyin\.com)$/.test(url.hostname) && url.hostname !== 'live.douyin.com' &&
      (url.hostname === 'v.douyin.com' || !!douyinVideoID(url.href));
  } catch { return false; }
}

// This fixed reader runs in the website, without Node access. It reads only the
// current video's player data; recommendations and account state are excluded.
function readDouyinPage() {
  const id = location.pathname.match(/^\/video\/(\d+)/)?.[1] || new URL(location.href).searchParams.get('modal_id');
  if (!id || !/(^|\.)douyin\.com$/.test(location.hostname)) return null;
  const seen = new Set(); let nodes = 0, found;
  function walk(value, depth) {
    if (found || !value || typeof value !== 'object' || seen.has(value) || depth > 5 || ++nodes > 15000) return;
    seen.add(value);
    if (String(value.awemeId) === id && value.video?.playAddr) { found = value; return; }
    if (Array.isArray(value)) { for (const item of value.slice(0, 12)) walk(item, depth + 1); return; }
    if (Object.getPrototypeOf(value) !== Object.prototype) return;
    for (const key of Object.keys(value).slice(0, 70)) if (key !== 'children') walk(value[key], depth + 1);
  }
  for (const video of document.querySelectorAll('video')) {
    for (let element = video, level = 0; element && level < 15 && !found; element = element.parentElement, level++) {
      const key = Object.keys(element).find(name => name.startsWith('__reactFiber'));
      for (let fiber = key && element[key], n = 0; fiber && n < 35 && !found; fiber = fiber.return, n++) {
        try { walk(fiber.memoizedProps, 0); } catch {}
      }
    }
  }
  if (!found || found.status?.isDelete || found.status?.isProhibited) return null;
  const video = found.video;
  const addresses = value => (Array.isArray(value) ? value : []).slice(0, 4).map(item => ({ src: String(item?.src || '').slice(0, 8192) }));
  return JSON.stringify({ id, title: String(found.desc || found.itemTitle || document.title).slice(0, 4096), video: {
    width: video.width, height: video.height, duration: video.duration, playAddr: addresses(video.playAddr),
    bitRateList: (video.bitRateList || []).slice(0, 64).filter(rate => rate.format === 'mp4').map(rate => ({
      width: rate.width, height: rate.height, fps: rate.fps, bitRate: rate.bitRate, dataSize: rate.dataSize,
      isH265: rate.isH265, playAddr: addresses(rate.playAddr)
    }))
  } });
}

function douyinInfo(text, userAgent) {
  let data; try { data = JSON.parse(text); } catch { throw new DownloadError('invalidMetadata'); }
  if (!data || !/^\d+$/.test(data.id) || typeof data.title !== 'string' || !data.title.trim() || !data.video) throw new DownloadError('invalidMetadata');
  const positive = number => typeof number === 'number' && Number.isFinite(number) && number > 0 ? number : undefined;
  function address(list) {
    for (const item of Array.isArray(list) ? list : []) {
      try {
        const url = new URL(item.src);
        if (['https:', 'http:'].includes(url.protocol) && !url.username && !url.password && /(^|\.)(douyinvod\.com|douyin\.com|bytecdn\.cn)$/.test(url.hostname)) return url.href;
      } catch {}
    }
  }
  const formats = (Array.isArray(data.video.bitRateList) ? data.video.bitRateList : []).slice(0, 64).map((rate, index) => ({
    format_id: 'web-' + index, url: address(rate.playAddr), ext: 'mp4',
    width: positive(rate.width), height: positive(rate.height), fps: positive(rate.fps),
    tbr: positive(rate.bitRate) / 1000 || undefined, filesize: positive(rate.dataSize),
    vcodec: rate.isH265 ? 'hevc' : 'h264', acodec: 'aac'
  })).filter(format => format.url);
  if (!formats.length) {
    const url = address(data.video.playAddr);
    if (url) formats.push({ format_id: 'web-default', url, ext: 'mp4', width: positive(data.video.width), height: positive(data.video.height), vcodec: 'unknown', acodec: 'aac' });
  }
  if (!formats.length) throw new DownloadError('invalidMetadata');
  return { id: data.id, title: data.title.slice(0, 4096), duration: positive(data.video.duration) / 1000 || undefined,
    webpage_url: 'https://www.douyin.com/video/' + data.id, extractor_key: 'DouyinWeb', extractor: 'douyin:web',
    http_headers: { Referer: 'https://www.douyin.com/', 'User-Agent': userAgent }, formats };
}
module.exports = { readDouyinPage, douyinInfo, supportsDouyinURL, douyinVideoID };
