'use strict';

const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

const PROGRESS_PREFIX = '__FEATHER_PROGRESS__';
const FINAL_PREFIX = '__FEATHER_FINAL__';
const QUALITY_FORMATS = Object.freeze({best:'bv*+ba/b',p1080:'bv*[height<=1080]+ba/b[height<=1080]',p720:'bv*[height<=720]+ba/b[height<=720]',audio:'ba/b'});
const MESSAGES = Object.freeze({
  noURL:'请粘贴视频链接，或包含链接的分享文案。',
  invalidMetadata:'没有获得有效的视频信息。请确认这是单个视频链接，或选择登录状态后重试。',
  liveVideo:'这个链接是正在直播的内容。当前版本只下载已发布的视频。',
  invalidDirectory:'保存目录不可写，请重新选择目录。',
  invalidAuthentication:'登录状态设置无效，请重新选择浏览器或 Cookie 文件。',
  invalidCookieFile:'所选 Cookie 文件无法读取。请选择 Netscape 格式的文本文件。',
  missingSiteSession:'请先点击「打开视频网站」，在应用内打开并确认视频可以播放，再返回重试。',
  anonymousExtractionUnavailable:'暂时未能读取这个公开视频。请稍后重试；如果网站要求登录或验证，再主动选择「应用内网站会话」。',
  missingTool:'应用内的下载组件缺失或无法运行，请重新安装应用。',
  timedOut:'操作等待过久，已停止。请检查网络后重试。',
  stalled:'下载长时间没有实际进展，已自动停止并释放资源。请检查网络后手动重试。',
  memoryLimitExceeded:'下载组件占用内存过多，已自动停止并释放资源。可以换一个视频或较低画质后重试。',
  outputTooLarge:'平台返回的数据过大，已停止本次操作。',
  helperDidNotExit:'下载组件未正常退出，已停止相关任务并释放资源。请手动重试。',
  missingFinalFile:'下载组件没有返回可验证的完成文件，请重试。',
  cancelled:'已取消。',
  interrupted:'上次运行未正常结束，任务已停止。请手动重试。',
  persistenceFailed:'任务记录无法保存，请检查应用数据目录的权限和磁盘空间。',
  launchFailed:'下载组件未能启动，请重新安装应用或检查安全软件的拦截记录。',
  generic:'这次解析或下载没有成功。可以重试，或使用另一个视频链接。'
});
class DownloadError extends Error {
  constructor(code, message) { super(message || MESSAGES[code] || MESSAGES.generic); this.name='DownloadError'; this.code=code; }
}
function readableFailure(detail) {
  const lines = String(detail || '').split(/[\r\n]+/);
  const final = [...lines].reverse().find(line => /ERROR:/i.test(line)) || lines.slice(-4).join(' ');
  const text = final.replace(/https?:\/\/[^\s]+/gi, '').toLowerCase();
  const any = (...phrases) => phrases.some(s => text.includes(s));
  if (any('unsupported url','no suitable extractor')) return '暂时无法解析这个平台或链接，请换用视频详情页链接。';
  if (any('requested format is not available')) return '视频没有所选清晰度，请选择最佳画质后重试。';
  if (text.includes('[twitter]') && (any('no video could be found in this tweet') || /video #\d+ is unavailable/.test(text))) return '未获取到这条 X 帖子的媒体信息，可能受登录或内容可见性限制。请在「登录状态」中选择已登录且有权访问的浏览器后重试。';
  if (any('not available in your country','not made available in your country','not available in your region','not available from your location','blocked in your country','geo-restricted','geoblocked')) return '平台明确限制了当前地区的访问，暂时无法下载这个视频。';
  if (any('private video','video is private','tweet is private','protected tweet','protected account','only available to subscribers','members-only','only available for registered users')) return '平台明确限制了这个内容的访问权限。请使用本身有权查看它的账号登录状态后重试。';
  if (any('video has been deleted','video has been removed','tweet has been deleted','tweet was deleted','deleted by the uploader','removed by the uploader','this content was removed')) return '平台提示这个内容已被删除或移除，无法继续下载。';
  if (isBrowserCookieFailure(detail)) return 'Windows 无法读取所选浏览器的登录状态。请选择「应用内网站会话」并打开视频网站，或使用自行导出的 Cookie 文件。';
  if (any('permission denied','no space left','read-only')) return '文件无法写入，请检查保存目录权限和磁盘剩余空间。';
  if (any('fresh cookies')) return '网站需要有效会话。请选择「应用内网站会话」，点击「打开视频网站」并确认视频可以播放，再返回重试；也可使用新导出的 Cookie 文件。';
  if (any('cookies','sign in','login','log in','not authorized','unauthorized','authentication required','age-restricted','confirm your age')) return '平台需要有效登录状态或内容访问资格。请选择已登录且有权访问的浏览器，或选择 Cookie 文件后重试。';
  if (any('429','too many requests')) return '平台暂时限制了请求频率，请稍后手动重试。';
  if (any('403','captcha','verify','blocked')) return '平台拒绝了这次请求，可能需要登录、验证或稍后重试。';
  if (any('timed out','connection','network','name or service','could not resolve','unable to resolve','failed to resolve','nodename nor servname')) return '网络连接未成功，请检查网络或代理设置后重试。';
  if (any('unavailable','not available','no video formats found')) return '平台当前没有返回可下载的视频。请先在浏览器确认内容可播放，并检查是否需要登录或具备访问权限。';
  return MESSAGES.generic;
}
function isBrowserCookieFailure(detail) {
  const errors=String(detail||'').split(/[\r\n]+/).filter(line=>/ERROR:/i.test(line)).join(' ').replace(/https?:\/\/\S+/gi,'');
  return /could not (?:copy|find).*cookie.*database|failed to decrypt|\bdpapi\b|app-bound|failed to load cookies from browser/i.test(errors);
}
function publicError(error) {
  return {code: error instanceof DownloadError ? error.code : 'generic', message: error instanceof DownloadError ? error.message : MESSAGES.generic};
}
function parseShareLinks(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text)>65536) throw new DownloadError('noURL');
  const matches = text.match(/https?:\/\/[^\s<>"“”‘’「」『』【】《》。，、！？；：]+/gi) || [];
  const seen = new Set();
  for (let value of matches) {
    value = value.replace(/[。，、！？；：….,!;:']+$/u,'');
    for (;;) {
      const close=value.at(-1), open={')':'(',']':'[','}':'{','）':'（'}[close];
      if (!open || value.split(close).length<=value.split(open).length) break;
      value=value.slice(0,-1);
    }
    try { const u=new URL(value); if (['http:','https:'].includes(u.protocol)&&u.hostname&&!u.username&&!u.password) seen.add(u.href); } catch {}
  }
  return [...seen];
}
function quality(value='best') { if (!Object.hasOwn(QUALITY_FORMATS,value)) throw new DownloadError('invalidMetadata'); return value; }
function authentication(value={type:'none'}) {
  if (!value || typeof value !== 'object') throw new DownloadError('invalidAuthentication');
  if (value.type==='none') return {type:'none'};
  if (value.type==='session') return {type:'session'};
  if (value.type==='browser' && ['chrome','edge','firefox','brave','opera','vivaldi'].includes(value.browser)) return {type:'browser',browser:value.browser};
  if (value.type==='file' && typeof value.path==='string' && path.isAbsolute(value.path) && !value.path.includes('\0')) return {type:'file',path:path.resolve(value.path)};
  throw new DownloadError('invalidAuthentication');
}
async function prepareAuthentication(value,{sourceURL,sessionAuthentication}={}) {
  const auth=authentication(value);
  if (auth.type==='session') {
    if(typeof sessionAuthentication!=='function')throw new DownloadError('missingSiteSession');
    return sessionAuthentication(sourceURL);
  }
  if (auth.type==='none') return {args:['--no-cookies','--no-cookies-from-browser'],cleanup:async()=>{}};
  if (auth.type==='browser') return {args:['--no-cookies','--cookies-from-browser',auth.browser],cleanup:async()=>{}};
  let temp;
  try {
    const stat=await fs.stat(auth.path);
    if (!stat.isFile()||stat.size>16*1024*1024) throw new Error('invalid');
    const data=await fs.readFile(auth.path);
    if (!/Netscape HTTP Cookie File|HTTP Cookie File/.test(data.subarray(0,1024).toString('utf8'))) throw new Error('invalid');
    temp=await fs.mkdtemp(path.join(os.tmpdir(),'FeatherCookies-'));
    await fs.chmod(temp,0o700);
    const copied=path.join(temp,'cookies.txt');
    await fs.writeFile(copied,data,{mode:0o600});
    return {args:['--no-cookies-from-browser','--cookies',copied],cleanup:()=>fs.rm(temp,{recursive:true,force:true})};
  } catch {
    if(temp) await fs.rm(temp,{recursive:true,force:true}).catch(()=>{});
    throw new DownloadError('invalidCookieFile');
  }
}
function safeHTTP(value) { try { const u=new URL(value); return ['http:','https:'].includes(u.protocol)&&!u.username&&!u.password ? u.href : null; } catch { return null; } }
function decodeMetadata(text, sourceURL) {
  let raw; try { raw=JSON.parse(text); } catch { throw new DownloadError('invalidMetadata'); }
  if (!raw||Array.isArray(raw)||raw.entries||!['string','number'].includes(typeof raw.id)||typeof raw.title!=='string'||!raw.title.trim()) throw new DownloadError('invalidMetadata');
  if (raw.is_live||raw.live_status==='is_live') throw new DownloadError('liveVideo');
  const formats=(Array.isArray(raw.formats)?raw.formats:[]).slice(0,4096).filter(f=>f&&typeof f.format_id==='string').map(f=>({id:f.format_id.slice(0,256),height:finite(f.height),width:finite(f.width),extension:typeof f.ext==='string'?f.ext.slice(0,16):null,hasVideo:f.vcodec!=='none'&&!!f.vcodec,hasAudio:f.acodec!=='none'&&!!f.acodec}));
  return {id:String(raw.id).slice(0,512),sourceURL,title:raw.title.slice(0,4096),webpageURL:safeHTTP(raw.webpage_url),thumbnailURL:safeHTTP(raw.thumbnail),duration:finite(raw.duration),extractor:typeof(raw.extractor_key||raw.extractor)==='string'?(raw.extractor_key||raw.extractor).slice(0,128):null,availableHeights:[...new Set(formats.map(f=>f.height).filter(n=>n>0))].sort((a,b)=>b-a),formats,isLive:false};
}
function finite(value) { return typeof value==='number'&&Number.isFinite(value)&&value>=0?value:null; }
function parseProgress(line) {
  if (!line.startsWith(PROGRESS_PREFIX)||Buffer.byteLength(line)>16384) return null;
  let raw; try {raw=JSON.parse(line.slice(PROGRESS_PREFIX.length));} catch{return null;}
  if(!raw||typeof raw!=='object'||Array.isArray(raw))return null;
  const allowed=['status','downloaded_bytes','total_bytes','total_bytes_estimate','speed','eta','item','postprocessor'];
  if(Object.keys(raw).some(k=>!allowed.includes(k)))return null;
  const downloadedBytes=finite(raw.downloaded_bytes), totalBytes=finite(raw.total_bytes) || finite(raw.total_bytes_estimate);
  return {fraction:downloadedBytes!==null&&totalBytes>0?Math.max(0,Math.min(1,downloadedBytes/totalBytes)):null,downloadedBytes,totalBytes,speedBytesPerSecond:finite(raw.speed),etaSeconds:finite(raw.eta),status:typeof raw.status==='string'?raw.status.slice(0,64):'processing',item:typeof raw.item==='string'?raw.item.slice(0,256):'',postprocessor:typeof raw.postprocessor==='string'?raw.postprocessor.slice(0,256):''};
}
module.exports={PROGRESS_PREFIX,FINAL_PREFIX,QUALITY_FORMATS,MESSAGES,DownloadError,publicError,readableFailure,isBrowserCookieFailure,parseShareLinks,quality,authentication,prepareAuthentication,decodeMetadata,parseProgress};
