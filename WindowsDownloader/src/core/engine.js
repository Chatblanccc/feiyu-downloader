'use strict';
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const {runProcess}=require('./process');
const {supportsDouyinURL}=require('../douyin.cjs');
const {PROGRESS_PREFIX,FINAL_PREFIX,QUALITY_FORMATS,DownloadError,parseShareLinks,quality,prepareAuthentication,decodeMetadata,parseProgress,readableFailure,isBrowserCookieFailure}=require('./protocol');

class DownloadEngine {
  constructor({tools,runner=runProcess,limits={},environment={},onResourceWarning,sessionAuthentication,sessionMetadata,anonymousMetadata,platform=process.platform}={}) {
    this.tools=tools||{};this.runner=runner;this.limits=limits;this.environment=environment;this.onResourceWarning=onResourceWarning;this.sessionAuthentication=sessionAuthentication;this.sessionMetadata=sessionMetadata;this.anonymousMetadata=anonymousMetadata;this.platform=platform;
  }
  async validateTools(){
    for(const name of ['ytDlp','ffmpeg',...(this.tools.deno?['deno']:[])]){
      const filename=this.tools[name];
      try{if(typeof filename!=='string'||!path.isAbsolute(filename)||!(await fs.stat(filename)).isFile())throw new Error('missing');await fs.access(filename,process.platform==='win32'?0:1);}catch{throw new DownloadError('missingTool');}
    }
  }
  commonArguments(){
    const args=['--ignore-config','--no-plugin-dirs','--no-cache-dir','--no-playlist','--playlist-items','1','--socket-timeout','30','--retries','3','--fragment-retries','3','--encoding','utf-8','--ffmpeg-location',path.dirname(this.tools.ffmpeg),'--no-js-runtimes'];
    if(this.tools.deno)args.push('--js-runtimes',`deno:${this.tools.deno}`);
    return args;
  }
  command(args,signal,extra={}){
    const directories=[path.dirname(this.tools.ffmpeg),...(this.tools.deno?[path.dirname(this.tools.deno)]:[])];
    return {executable:this.tools.ytDlp,args,env:{...this.environment,PATH:[...directories,this.environment.PATH||process.env.PATH||''].join(path.delimiter),PYTHONUNBUFFERED:'1',NO_COLOR:'1'},signal,onResourceWarning:this.onResourceWarning,...extra};
  }
  async authenticated(sourceURL,authentication,signal,operation){
    const auth=await prepareAuthentication(authentication,{sourceURL,sessionAuthentication:this.sessionAuthentication});
    let result;
    try{result=await operation(auth.args);}finally{await auth.cleanup();}
    let anonymousFallback=false;
    if(this.platform==='win32'&&authentication.type==='browser'&&result.exitCode!==0&&isBrowserCookieFailure(result.stderr)){
      if(signal?.aborted)throw new DownloadError('cancelled');
      this.onResourceWarning?.('Windows 无法读取所选浏览器的登录状态，正在尝试直接解析公开链接。需要登录的视频可改用「应用内网站会话」。');
      // Cookie loading failed before extraction. Retry once without reading any other credentials.
      const anonymous=await prepareAuthentication({type:'none'});
      try{result=await operation(anonymous.args);}finally{await anonymous.cleanup();}
      anonymousFallback=true;
    }
    if(result.exitCode!==0){
      const error=new DownloadError('processFailed',readableFailure(result.stderr));
      error.anonymousAttempted=authentication.type==='none'||anonymousFallback;
      throw error;
    }
    return {result,anonymousFallback};
  }
  async preview(shareText,{authentication={type:'none'},signal}={}) {
    const url=parseShareLinks(shareText)[0];if(!url)throw new DownloadError('noURL');
    if(signal?.aborted)throw new DownloadError('cancelled');
    await this.validateTools();
    if(authentication.type==='session'&&this.sessionMetadata){
      const info=await this.sessionMetadata(url,{signal});
      if(info)return {...decodeMetadata(JSON.stringify(info),url),downloadInfo:info};
    }
    try{
      const {result,anonymousFallback}=await this.authenticated(url,authentication,signal,args=>this.runner(this.command([...this.commonArguments(),...args,'--dump-single-json','--skip-download','--',url],signal,{captureStdout:true,limits:{totalTimeoutMs:90000,maximumOutputBytes:16*1024*1024,maximumLineBytes:16*1024*1024,...this.limits.metadata}})));
      return {...decodeMetadata(result.stdout,url),...(anonymousFallback?{anonymousFallback:true}:{})};
    }catch(error){
      if(signal?.aborted)throw new DownloadError('cancelled');
      // Like the Mac public-page resolver: no existing login state is involved.
      if(this.platform!=='win32'||error.code!=='processFailed'||!error.anonymousAttempted||!this.anonymousMetadata||!supportsDouyinURL(url))throw error;
      const info=await this.anonymousMetadata(url,{signal});
      if(signal?.aborted)throw new DownloadError('cancelled');
      if(!info)throw error;
      return {...decodeMetadata(JSON.stringify(info),url),downloadInfo:info,anonymousFallback:true};
    }
  }
  async download(metadata,{quality:requestedQuality='best',directory,authentication={type:'none'},signal,onProgress=()=>{}}={}) {
    const q=quality(requestedQuality);
    if(!metadata||typeof metadata.title!=='string'||!parseShareLinks(metadata.sourceURL).length)throw new DownloadError('invalidMetadata');
    if(metadata.isLive)throw new DownloadError('liveVideo');
    if(signal?.aborted)throw new DownloadError('cancelled');
    await this.validateTools();
    let destination;
    try{
      if(typeof directory!=='string'||!path.isAbsolute(directory)||directory.includes('\0'))throw new Error('invalid');
      await fs.mkdir(directory,{recursive:true});destination=await fs.realpath(directory);await fs.access(destination,2);
    }catch{throw new DownloadError('invalidDirectory');}
    if(metadata.anonymousFallback&&authentication.type==='browser')authentication={type:'none'};
    let finalPath=null,lastEmission=0;
    const input=await prepareDownloadInput(metadata);
    try{
    const {result}=await this.authenticated(metadata.sourceURL,authentication,signal,async authArgs=>{
      const args=[...this.commonArguments(),...authArgs,'--no-simulate','--quiet','--newline','--progress','--progress-delta','0.5','--progress-template','download:'+PROGRESS_PREFIX+'{"status":%(progress.status|null)j,"downloaded_bytes":%(progress.downloaded_bytes|null)j,"total_bytes":%(progress.total_bytes|null)j,"total_bytes_estimate":%(progress.total_bytes_estimate|null)j,"speed":%(progress.speed|null)j,"eta":%(progress.eta|null)j,"item":%(info.format_id|null)j}','--progress-template','postprocess:'+PROGRESS_PREFIX+'{"status":%(progress.status|null)j,"postprocessor":%(progress.postprocessor|null)j}','--print','after_move:'+FINAL_PREFIX+'%(filepath)j','--no-overwrites','--continue','--windows-filenames','--paths',destination,'--output',q==='audio'?'%(title).180B [%(id)s] · 音频.%(ext)s':'%(title).180B [%(id)s].%(ext)s','--format',QUALITY_FORMATS[q]];
      if(q==='audio')args.push('--extract-audio','--audio-format','m4a','--audio-quality','0');
      else args.push('--merge-output-format','mp4','--format-sort','vcodec:h264,lang,quality,res,fps,hdr:12,acodec:aac');
      args.push(...input.args);
      const result=await this.runner(this.command(args,signal,{captureStdout:false,progressTracking:true,limits:{...this.limits.download},onLine:(line,channel)=>{
        if(channel==='stdout'&&line.startsWith(FINAL_PREFIX)){
          try{const value=JSON.parse(line.slice(FINAL_PREFIX.length));if(typeof value==='string'&&path.isAbsolute(value)&&!value.includes('\0'))finalPath=path.resolve(value);}catch{}
        }
        const p=parseProgress(line), now=Date.now();
        if(p&&(now-lastEmission>=200||p.status==='finished')){lastEmission=now;onProgress(p);}
      }}));
      return result;
    });
    // Exit success and an existing, verified after_move file form the commit boundary.
    // Late cancellation cannot discard a file already delivered by the helper.
    const file=await validateFinalFile(finalPath,destination);
    return {...file,peakMemoryBytes:result.peakMemoryBytes||0,durationMs:result.durationMs||0};
    }finally{await input.cleanup();}
  }
}
async function prepareDownloadInput(metadata){
  if(!metadata.downloadInfo)return {args:['--',metadata.sourceURL],cleanup:async()=>{}};
  if(String(metadata.downloadInfo.id)!==metadata.id)throw new DownloadError('invalidMetadata');
  const content=JSON.stringify(metadata.downloadInfo);
  if(Buffer.byteLength(content)>16*1024*1024)throw new DownloadError('invalidMetadata');
  const directory=await fs.mkdtemp(path.join(os.tmpdir(),'FeiyuVideoInfo-')),filename=path.join(directory,'video.json');
  try{await fs.writeFile(filename,content,{mode:0o600});}catch(error){await fs.rm(directory,{recursive:true,force:true});throw error;}
  return {args:['--load-info-json',filename],cleanup:()=>fs.rm(directory,{recursive:true,force:true})};
}
async function validateFinalFile(filename,directory,expectedSize){
  try{
    if(typeof filename!=='string'||!path.isAbsolute(filename))throw new Error('invalid');
    const realDirectory=await fs.realpath(directory), realFile=await fs.realpath(filename);
    const relative=path.relative(realDirectory,realFile);
    if(!relative||relative==='..'||relative.startsWith(`..${path.sep}`)||path.isAbsolute(relative))throw new Error('outside');
    const stat=await fs.stat(realFile);
    if(!stat.isFile()||stat.size<=0||(expectedSize!==undefined&&stat.size!==expectedSize))throw new Error('invalid');
    return {filePath:realFile,fileSize:stat.size};
  }catch{throw new DownloadError('missingFinalFile');}
}
module.exports={DownloadEngine,validateFinalFile};
