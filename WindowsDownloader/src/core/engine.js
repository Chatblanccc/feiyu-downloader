'use strict';
const fs=require('node:fs/promises');
const path=require('node:path');
const {runProcess}=require('./process');
const {PROGRESS_PREFIX,FINAL_PREFIX,QUALITY_FORMATS,DownloadError,parseShareLinks,quality,prepareAuthentication,decodeMetadata,parseProgress,readableFailure}=require('./protocol');

class DownloadEngine {
  constructor({tools,runner=runProcess,limits={},environment={},onResourceWarning}={}) {
    this.tools=tools||{};this.runner=runner;this.limits=limits;this.environment=environment;this.onResourceWarning=onResourceWarning;
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
  async preview(shareText,{authentication={type:'none'},signal}={}) {
    const url=parseShareLinks(shareText)[0];if(!url)throw new DownloadError('noURL');
    if(signal?.aborted)throw new DownloadError('cancelled');
    await this.validateTools();
    const auth=await prepareAuthentication(authentication);
    try{
      const result=await this.runner(this.command([...this.commonArguments(),...auth.args,'--dump-single-json','--skip-download','--',url],signal,{captureStdout:true,limits:{totalTimeoutMs:90000,maximumOutputBytes:16*1024*1024,maximumLineBytes:16*1024*1024,...this.limits.metadata}}));
      if(result.exitCode!==0)throw new DownloadError('processFailed',readableFailure(result.stderr));
      return decodeMetadata(result.stdout,url);
    }finally{await auth.cleanup();}
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
    const auth=await prepareAuthentication(authentication);let finalPath=null,lastEmission=0;
    try{
      const args=[...this.commonArguments(),...auth.args,'--no-simulate','--quiet','--newline','--progress','--progress-delta','0.5','--progress-template','download:'+PROGRESS_PREFIX+'{"status":%(progress.status|null)j,"downloaded_bytes":%(progress.downloaded_bytes|null)j,"total_bytes":%(progress.total_bytes|null)j,"total_bytes_estimate":%(progress.total_bytes_estimate|null)j,"speed":%(progress.speed|null)j,"eta":%(progress.eta|null)j,"item":%(info.format_id|null)j}','--progress-template','postprocess:'+PROGRESS_PREFIX+'{"status":%(progress.status|null)j,"postprocessor":%(progress.postprocessor|null)j}','--print','after_move:'+FINAL_PREFIX+'%(filepath)j','--no-overwrites','--continue','--windows-filenames','--paths',destination,'--output',q==='audio'?'%(title).180B [%(id)s] · 音频.%(ext)s':'%(title).180B [%(id)s].%(ext)s','--format',QUALITY_FORMATS[q]];
      if(q==='audio')args.push('--extract-audio','--audio-format','m4a','--audio-quality','0');
      else args.push('--merge-output-format','mp4','--format-sort','vcodec:h264,lang,quality,res,fps,hdr:12,acodec:aac');
      args.push('--',metadata.sourceURL);
      const result=await this.runner(this.command(args,signal,{captureStdout:false,progressTracking:true,limits:{...this.limits.download},onLine:(line,channel)=>{
        if(channel==='stdout'&&line.startsWith(FINAL_PREFIX)){
          try{const value=JSON.parse(line.slice(FINAL_PREFIX.length));if(typeof value==='string'&&path.isAbsolute(value)&&!value.includes('\0'))finalPath=path.resolve(value);}catch{}
        }
        const p=parseProgress(line), now=Date.now();
        if(p&&(now-lastEmission>=200||p.status==='finished')){lastEmission=now;onProgress(p);}
      }}));
      if(result.exitCode!==0)throw new DownloadError('processFailed',readableFailure(result.stderr));
      // Exit success and an existing, verified after_move file form the commit boundary.
      // Late cancellation cannot discard a file already delivered by the helper.
      const file=await validateFinalFile(finalPath,destination);
      return {...file,peakMemoryBytes:result.peakMemoryBytes||0,durationMs:result.durationMs||0};
    }finally{await auth.cleanup();}
  }
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
