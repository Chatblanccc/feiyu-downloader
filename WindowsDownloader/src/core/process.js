'use strict';

const {spawn,execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {StringDecoder} = require('node:string_decoder');
const {DownloadError,parseProgress} = require('./protocol');
const execFileAsync=promisify(execFile);

const DEFAULT_LIMITS=Object.freeze({totalTimeoutMs:90*60*1000,preparationTimeoutMs:90000,inactivityTimeoutMs:60000,processingTimeoutMs:600000,maximumMemoryBytes:768*1024*1024,maximumOutputBytes:8*1024*1024,maximumStandardErrorBytes:512*1024,maximumLineBytes:16384,resourceSampleIntervalMs:2500,exitGraceMs:1500,killGraceMs:1200,tickIntervalMs:250});
const positive=(v,f)=>Number.isFinite(v)&&v>0?v:f;

// Numeric PIDs and this fixed script are the only PowerShell inputs. No user data is evaluated.
async function sampleProcesses(platform=process.platform) {
  if(platform==='win32') {
    const command='$ErrorActionPreference="Stop"; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -gt 0 -and $null -ne $_.CreationDate } | ForEach-Object { "{0}|{1}|{2}|{3}" -f $_.ProcessId,$_.ParentProcessId,$_.WorkingSetSize,$_.CreationDate.ToUniversalTime().Ticks }';
    const {stdout}=await execFileAsync('powershell.exe',['-NoLogo','-NoProfile','-NonInteractive','-Command',command],{windowsHide:true,timeout:4000,maxBuffer:2*1024*1024,encoding:'utf8'});
    return stdout.split(/[\r\n]+/).map(line=>{const [pid,ppid,rss,identity]=line.trim().split('|');return {pid:Number(pid),ppid:Number(ppid),rss:Number(rss),identity};}).filter(p=>p.pid>0&&Number.isFinite(p.rss)&&p.identity);
  }
  const {stdout}=await execFileAsync('/bin/ps',['-axo','pid=,ppid=,rss=,lstart='],{timeout:2000,maxBuffer:2*1024*1024,encoding:'utf8'});
  return stdout.split('\n').map(line=>{const m=line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);return m?{pid:+m[1],ppid:+m[2],rss:+m[3]*1024,identity:m[4]}:null;}).filter(Boolean);
}
function descendants(records,pid) {
  const selected=new Set([pid]);
  let grew=true; while(grew){grew=false;for(const rec of records)if(selected.has(rec.ppid)&&!selected.has(rec.pid)){selected.add(rec.pid);grew=true;}}
  return records.filter(p=>selected.has(p.pid));
}
async function taskkill(pid,force=true) {
  if(!Number.isInteger(pid)||pid<=1)return;
  try{await execFileAsync('taskkill.exe',['/PID',String(pid),'/T',...(force?['/F']:[])],{windowsHide:true,timeout:2000,maxBuffer:65536,encoding:'utf8'});}catch{}
}

/** Runs an owned child using argv, never a shell.
 * Options: executable, args, cwd, env (merged), signal, captureStdout (default true),
 * onLine(line,channel), limits, progressTracking (download-only), resourceSample?
 * Result: {exitCode,signal,stdout,stderr,peakMemoryBytes,durationMs} (strings, bounded).
 * Rejects DownloadError; never returns raw stderr in an error message.
 * Windows taskkill and polling bound normal failures; this is not a kernel Job Object.
 */
async function runProcess(options) {
  const {executable,args=[],signal}=options;
  if(typeof executable!=='string'||!executable||executable.includes('\0')||!Array.isArray(args)||args.some(a=>typeof a!=='string'||a.includes('\0')))throw new DownloadError('launchFailed');
  if(signal?.aborted)throw new DownloadError('cancelled');
  const limits={...DEFAULT_LIMITS,...options.limits};
  for(const key of Object.keys(DEFAULT_LIMITS))limits[key]=positive(limits[key],DEFAULT_LIMITS[key]);
  const capture=options.captureStdout!==false, platform=options.platform||process.platform;
  const sampler=options.resourceSample||(()=>sampleProcesses(platform));
  const spawnFunction=options.spawn||spawn;
  const started=Date.now();
  return new Promise((resolve,reject)=>{
    let child,failure,settled=false,rootExited=false,exitAt=0,exitCode=null,exitSignal=null,cleanupAt=0,killSent=false,sampling=false,lastSampleAt=0,peakMemoryBytes=0,samplingFailures=0,resourceWarningSent=false;
    let phase='preparing',phaseStarted=started,lastByteProgress=started;
    const bytesByItem=new Map(), finishedItems=new Set(), postprocessors=new Set(),known=new Map();
    const streams={stdout:{chunks:[],bytes:0,parts:[],lineBytes:0,decoder:new StringDecoder('utf8')},stderr:{chunks:[],bytes:0,parts:[],lineBytes:0,decoder:new StringDecoder('utf8')}};
    const progressTracking=options.progressTracking===true;
    let timer;
    const stop=(error)=>{if(!failure)failure=error; if(!cleanupAt){cleanupAt=Date.now();void terminate(false);}};
    const terminate=async(force)=>{
      if(!child?.pid)return;
      if(platform==='win32') {
        // Keep the leader alive until taskkill has been dispatched where possible.
        if(!rootExited)await taskkill(child.pid,true);
        // After parent exit, only signal a sampled child if its creation identity still matches.
        if(rootExited&&known.size){try{const records=await sampler();for(const p of records)if(p.pid!==child.pid&&known.get(p.pid)===p.identity)await taskkill(p.pid,true);}catch{}}
      } else {
        try{process.kill(-child.pid,force?'SIGKILL':'SIGTERM');}catch{}
      }
    };
    const finish=()=>{
      if(settled)return;settled=true;clearInterval(timer);signal?.removeEventListener('abort',abort);
      for(const stream of [child?.stdout,child?.stderr]) {stream?.removeAllListeners('data');stream?.destroy();}
      child?.removeListener('error',onError);child?.removeListener('close',onClose);child?.removeListener('exit',onExit);
      const result={exitCode:exitCode??-1,signal:exitSignal,stdout:capture?Buffer.concat(streams.stdout.chunks).toString('utf8'):'',stderr:Buffer.concat(streams.stderr.chunks).toString('utf8'),peakMemoryBytes,durationMs:Date.now()-started};
      // Release chunk arrays before handing the final result to the caller.
      for(const state of Object.values(streams)){state.chunks=[];state.parts=[];}
      if(failure)reject(failure);else resolve(result);
    };
    const abort=()=>stop(new DownloadError('cancelled'));
    const line=(text,channel)=>{
      if(progressTracking){
        const p=parseProgress(text);
        if(p){
          const now=Date.now();
          if(p.postprocessor){
            if(phase!=='processing'){phase='processing';phaseStarted=now;}
            if(!postprocessors.has(p.postprocessor)){postprocessors.add(p.postprocessor);phaseStarted=now;}
          }else if(p.downloadedBytes!==null){
            const previous=bytesByItem.get(p.item);
            const changed=previous===undefined||p.downloadedBytes>previous;
            if(changed){
              bytesByItem.set(p.item,Math.max(previous||0,p.downloadedBytes));
              if(phase!=='downloading'){phase='downloading';phaseStarted=now;}
              lastByteProgress=now;
            }
            if(p.status==='finished'&&!finishedItems.has(p.item)){
              finishedItems.add(p.item);phase='processing';phaseStarted=now;
            }
          }
        }
      }
      try{options.onLine?.(text,channel);}catch{stop(new DownloadError('invalidMetadata'));}
    };
    const consume=(chunk,channel)=>{
      if(settled||failure)return;
      const state=streams[channel];const buffer=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);
      state.bytes+=buffer.length;
      const max=channel==='stdout'?limits.maximumOutputBytes:limits.maximumStandardErrorBytes;
      if(state.bytes>max){stop(new DownloadError('outputTooLarge'));return;}
      if(channel==='stderr'||capture)state.chunks.push(buffer);
      if(!options.onLine&&!progressTracking)return;
      // Split UTF-8 only after a whole line; memory is bounded independently from capture.
      let cursor=0;
      for(let n=0;n<buffer.length;n++)if(buffer[n]===10||buffer[n]===13){
        const part=buffer.subarray(cursor,n);state.lineBytes+=part.length;
        if(state.lineBytes>limits.maximumLineBytes){stop(new DownloadError('outputTooLarge'));return;}
        state.parts.push(part);
        if(state.lineBytes)line(Buffer.concat(state.parts,state.lineBytes).toString('utf8'),channel);
        state.parts=[];state.lineBytes=0;cursor=n+1;
      }
      if(cursor<buffer.length){state.parts.push(buffer.subarray(cursor));state.lineBytes+=buffer.length-cursor;if(state.lineBytes>limits.maximumLineBytes)stop(new DownloadError('outputTooLarge'));}
    };
    const flush=()=>{for(const [channel,state]of Object.entries(streams))if(state.lineBytes&&!failure){line(Buffer.concat(state.parts,state.lineBytes).toString('utf8'),channel);state.parts=[];state.lineBytes=0;}};
    const onError=()=>{stop(new DownloadError('launchFailed')); if(!child?.pid)finish();};
    const onExit=(code,sig)=>{rootExited=true;exitAt=Date.now();exitCode=code;exitSignal=sig;};
    const onClose=(code,sig)=>{if(!rootExited)onExit(code,sig);flush();finish();};
    try {
      child=spawnFunction(executable,args,{cwd:options.cwd,env:{...process.env,...options.env},windowsHide:true,shell:false,detached:platform!=='win32',stdio:['ignore','pipe','pipe']});
      child.stdout?.on('data',c=>consume(c,'stdout'));child.stderr?.on('data',c=>consume(c,'stderr'));
      child.once('error',onError);child.once('exit',onExit);child.once('close',onClose);
    }catch{reject(new DownloadError('launchFailed'));return;}
    signal?.addEventListener('abort',abort,{once:true});
    if(signal?.aborted)abort();
    const tick=()=>{
      if(settled)return;const now=Date.now();
      if(!failure){
        if(now-started>limits.totalTimeoutMs)stop(new DownloadError('timedOut'));
        else if(rootExited&&now-exitAt>limits.exitGraceMs)stop(new DownloadError('helperDidNotExit'));
        else if(progressTracking&&phase==='preparing'&&now-phaseStarted>limits.preparationTimeoutMs)stop(new DownloadError('stalled'));
        else if(progressTracking&&phase==='downloading'&&now-lastByteProgress>limits.inactivityTimeoutMs)stop(new DownloadError('stalled'));
        else if(progressTracking&&phase==='processing'&&now-phaseStarted>limits.processingTimeoutMs)stop(new DownloadError('stalled'));
      }
      if(cleanupAt&&now-cleanupAt>limits.killGraceMs){if(!killSent){killSent=true;void terminate(true);} if(now-cleanupAt>limits.killGraceMs+500)finish();}
      if(!sampling&&!rootExited&&!failure&&now-lastSampleAt>=limits.resourceSampleIntervalMs){
        sampling=true;lastSampleAt=now;
        Promise.resolve().then(sampler).then(records=>{
          if(settled)return;
          const owned=descendants(records,child.pid);
          if(!rootExited&&!owned.some(p=>p.pid===child.pid))throw new Error('Owned process was absent from resource inventory');
          samplingFailures=0;let memory=0;
          for(const p of owned){known.set(p.pid,p.identity);memory+=p.rss;}
          peakMemoryBytes=Math.max(peakMemoryBytes,memory);
          if(memory>limits.maximumMemoryBytes)stop(new DownloadError('memoryLimitExceeded'));
        }).catch(()=>{
          if(settled)return;
          samplingFailures++;
          if(!resourceWarningSent){resourceWarningSent=true;try{options.onResourceWarning?.('正在重新检查下载组件的资源监测。');}catch{}}
          // Do not run an hours-long task without its resource guard if monitoring is blocked.
          if(samplingFailures>=3)stop(new DownloadError('resourceMonitoringUnavailable','无法监测下载组件的资源占用，已停止任务。请检查系统是否阻止了资源监测后再试。'));
        }).finally(()=>{sampling=false;});
      }
    };
    timer=setInterval(tick,limits.tickIntervalMs);tick();
  });
}
module.exports={runProcess,DEFAULT_LIMITS,sampleProcesses,descendants};
