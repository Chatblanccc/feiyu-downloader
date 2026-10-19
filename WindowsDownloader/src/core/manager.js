'use strict';
const {EventEmitter}=require('node:events');
const fs=require('node:fs/promises');
const path=require('node:path');
const crypto=require('node:crypto');
const {DownloadEngine,validateFinalFile}=require('./engine');
const {DownloadError,publicError,parseShareLinks,quality,authentication}=require('./protocol');
const ACTIVE=new Set(['resolving','downloading','processing']);
const TERMINAL=new Set(['completed','failed','cancelled','interrupted']);
const ALL_STATUSES=new Set(['queued',...ACTIVE,...TERMINAL]);
const clone=value=>JSON.parse(JSON.stringify(value));

async function atomicJSON(filename,value){
  await fs.mkdir(path.dirname(filename),{recursive:true,mode:0o700});
  const temporary=`${filename}.${crypto.randomUUID()}.tmp`;
  let handle;
  try{handle=await fs.open(temporary,'wx',0o600);await handle.writeFile(JSON.stringify(value,null,2));await handle.sync();await handle.close();handle=null;await fs.rename(temporary,filename);}
  catch(error){await handle?.close().catch(()=>{});await fs.rm(temporary,{force:true}).catch(()=>{});throw error;}
}
async function readJSON(filename,maximum=32*1024*1024){const stat=await fs.stat(filename);if(!stat.isFile()||stat.size>maximum)throw new Error('invalid record');return JSON.parse(await fs.readFile(filename,'utf8'));}
function cleanMetadata(metadata){
  if(!metadata)return null;
  const {id,title,sourceURL,webpageURL,duration,extractor,availableHeights,isLive}=metadata;
  // Do not persist signed CDN streams, thumbnail query strings or extractor diagnostics.
  return {id,title,sourceURL,webpageURL,duration,extractor,availableHeights,isLive};
}

class DownloadManager extends EventEmitter {
  constructor({tools,dataDirectory,downloadDirectory,concurrency=1,runner,engine,limits,environment,sessionAuthentication,sessionMetadata,anonymousMetadata}={}){
    super();
    if(typeof dataDirectory!=='string'||!path.isAbsolute(dataDirectory)||typeof downloadDirectory!=='string'||!path.isAbsolute(downloadDirectory))throw new DownloadError('invalidDirectory');
    this.dataDirectory=path.resolve(dataDirectory);this.historyFile=path.join(this.dataDirectory,'download-history.json');this.receiptDirectory=path.join(this.dataDirectory,'download-receipts');
    this.options={downloadDirectory:path.resolve(downloadDirectory),quality:'best',authentication:{type:'none'},concurrency:Math.min(2,Math.max(1,Math.trunc(concurrency)||1))};
    this.tasks=[];this.active=new Map();this.ready=false;this.closing=false;this.pendingWrite=Promise.resolve();this.previewController=null;this.previewPromise=null;this.pumpScheduled=false;this.changeTimer=null;
    this.engine=engine||new DownloadEngine({tools,runner,limits,environment,sessionAuthentication,sessionMetadata,anonymousMetadata,onResourceWarning:message=>this.emit('warning',message)});
  }
  async init(){
    if(this.ready)return this;
    await fs.mkdir(this.dataDirectory,{recursive:true,mode:0o700});await fs.mkdir(this.receiptDirectory,{recursive:true,mode:0o700});
    let record;
    try{record=await readJSON(this.historyFile);}catch(error){if(error.code!=='ENOENT')throw new DownloadError('persistenceFailed','任务记录无法读取。原文件已保留，请检查应用数据目录后重试。');}
    if(record){
      if(record.version!==1||!Array.isArray(record.tasks)||record.tasks.length>5000)throw new DownloadError('persistenceFailed');
      if(record.options){try{this.options=this._options({...this.options,...record.options});}catch{}}
      for(const item of record.tasks){
        if(!item||typeof item.id!=='string'||!/^[a-zA-Z0-9-]{1,80}$/.test(item.id)||!ALL_STATUSES.has(item.status)||typeof item.sourceURL!=='string'||!parseShareLinks(item.sourceURL).length||typeof item.directory!=='string'||!path.isAbsolute(item.directory))throw new DownloadError('persistenceFailed');
        quality(item.quality);authentication(item.authentication);
        const task={...item,progress:null,metadata:cleanMetadata(item.metadata)};
        const receipt=await this._recoverReceipt(task);
        if(receipt){task.status='completed';task.error=null;task.filePath=receipt.filePath;task.fileSize=receipt.fileSize;task.completedAt=receipt.completedAt;}
        else if(task.status==='queued'||ACTIVE.has(task.status)){task.status='interrupted';task.error=publicError(new DownloadError('interrupted'));task.updatedAt=new Date().toISOString();}
        else if(task.status==='completed'){
          try{await validateFinalFile(task.filePath,task.directory,task.fileSize);}catch{task.status='failed';task.error=publicError(new DownloadError('missingFinalFile'));task.updatedAt=new Date().toISOString();}
        }
        this.tasks.push(task);
      }
    }
    this.ready=true;await this._persist();this._emit();return this;
  }
  _options(value){
    if(typeof value.downloadDirectory!=='string'||!path.isAbsolute(value.downloadDirectory)||value.downloadDirectory.includes('\0'))throw new DownloadError('invalidDirectory');
    return {downloadDirectory:path.resolve(value.downloadDirectory),quality:quality(value.quality),authentication:authentication(value.authentication),concurrency:Math.min(2,Math.max(1,Math.trunc(Number(value.concurrency))||1))};
  }
  snapshot(){return clone({tasks:this.tasks,options:this.options,activeCount:this.active.size+(this.previewController?1:0),previewing:!!this.previewController});}
  async setOptions(value){this._assertReady();this.options=this._options({...this.options,...value});await this._persist();this._emit();this._schedulePump();return this.snapshot();}
  _assertReady(){if(!this.ready||this.closing)throw new DownloadError('cancelled');}
  async preview(shareText,{authentication:auth=this.options.authentication,signal}={}){
    this._assertReady();
    if(this.active.size>=2)throw new DownloadError('busy','已有两个任务正在处理，请稍后再解析链接。');
    this.previewController?.abort();
    const previous=this.previewPromise;
    const controller=new AbortController();this.previewController=controller;
    const abort=()=>controller.abort();signal?.addEventListener('abort',abort,{once:true});if(signal?.aborted)controller.abort();this._emit();
    const operation=(async()=>{
      await previous?.catch(()=>{});
      if(controller.signal.aborted||this.closing)throw new DownloadError('cancelled');
      return this.engine.preview(shareText,{authentication:authentication(auth),signal:controller.signal});
    })();
    this.previewPromise=operation;
    try{return await operation;}
    finally{signal?.removeEventListener('abort',abort);if(this.previewController===controller){this.previewController=null;this.previewPromise=null;this._emit();this._schedulePump();}}
  }

  async add(shareText,value={}){
    this._assertReady();if(this.tasks.length>=5000)throw new DownloadError('historyFull','任务记录已达上限，请先移除不需要的历史记录。');
    const sourceURL=parseShareLinks(shareText)[0];if(!sourceURL)throw new DownloadError('noURL');
    const directory=value.directory||this.options.downloadDirectory;
    if(typeof directory!=='string'||!path.isAbsolute(directory)||directory.includes('\0'))throw new DownloadError('invalidDirectory');
    const now=new Date().toISOString();
    const task={id:crypto.randomUUID(),sourceURL,title:'等待解析视频',metadata:null,quality:quality(value.quality||this.options.quality),directory:path.resolve(directory),authentication:authentication(value.authentication||this.options.authentication),status:'queued',progress:null,error:null,createdAt:now,updatedAt:now,filePath:null,fileSize:null};
    this.tasks.unshift(task);
    try{await this._persist();}catch(error){this.tasks=this.tasks.filter(t=>t!==task);throw error;}
    this._emit();this._schedulePump();return task.id;
  }
  async retry(id,value={}){
    this._assertReady();const task=this._task(id);if(!TERMINAL.has(task.status))throw new DownloadError('busy','该任务仍在处理中。');
    if(task.status==='completed')throw new DownloadError('alreadyCompleted','视频已经下载完成，可在保存目录中打开。');
    const auth=authentication(value.authentication||this.options.authentication),q=quality(value.quality||task.quality),directory=value.directory||task.directory;
    if(!path.isAbsolute(directory))throw new DownloadError('invalidDirectory');
    Object.assign(task,{authentication:auth,quality:q,directory:path.resolve(directory),status:'queued',progress:null,error:null,updatedAt:new Date().toISOString(),filePath:null,fileSize:null});
    await this._persist();this._emit();this._schedulePump();return id;
  }
  async cancel(id){
    this._assertReady();const task=this._task(id);
    if(task.status==='queued'){task.status='cancelled';task.error=publicError(new DownloadError('cancelled'));task.updatedAt=new Date().toISOString();await this._persist();this._emit();}
    else if(ACTIVE.has(task.status))this.active.get(id)?.controller.abort();
    return this.snapshot();
  }
  async remove(id){
    this._assertReady();const task=this._task(id);if(!TERMINAL.has(task.status))throw new DownloadError('busy','请先取消任务，再移除这条记录。');
    const previous=this.tasks;this.tasks=this.tasks.filter(t=>t.id!==id);
    try{await this._persist();}catch(error){this.tasks=previous;throw error;}
    // Deleting a record never deletes the user's video or partially downloaded media.
    await fs.rm(this._receiptFile(id),{force:true}).catch(()=>{});this._emit();return this.snapshot();
  }
  _task(id){const task=this.tasks.find(t=>t.id===id);if(!task)throw new DownloadError('notFound','没有找到这条任务记录。');return task;}
  _receiptFile(id){return path.join(this.receiptDirectory,`${id}.json`);}
  async _recoverReceipt(task){
    try{const r=await readJSON(this._receiptFile(task.id),8192);if(r.version!==1||r.taskId!==task.id||r.sourceURL!==task.sourceURL||r.quality!==task.quality||!Number.isSafeInteger(r.fileSize)||typeof r.completedAt!=='string')return null;await validateFinalFile(r.filePath,task.directory,r.fileSize);return r;}catch{return null;}
  }
  _persist(){
    const value=clone({version:1,options:this.options,tasks:this.tasks.map(t=>({...t,metadata:cleanMetadata(t.metadata),progress:null}))});
    const next=this.pendingWrite.catch(()=>{}).then(()=>atomicJSON(this.historyFile,value)).catch(()=>{throw new DownloadError('persistenceFailed');});this.pendingWrite=next;return next;
  }
  _emit(throttled=false){
    if(throttled){if(!this.changeTimer)this.changeTimer=setTimeout(()=>{this.changeTimer=null;this.emit('change',this.snapshot());},200);return;}
    if(this.changeTimer){clearTimeout(this.changeTimer);this.changeTimer=null;}this.emit('change',this.snapshot());
  }
  _schedulePump(){if(this.pumpScheduled||this.closing)return;this.pumpScheduled=true;queueMicrotask(()=>{this.pumpScheduled=false;this._pump();});}
  _pump(){
    if(this.closing||!this.ready)return;
    while(this.active.size<this.options.concurrency&&this.active.size+(this.previewController?1:0)<2){
      const task=[...this.tasks].reverse().find(t=>t.status==='queued');if(!task)break;
      const controller=new AbortController();const slot={controller,promise:null};this.active.set(task.id,slot);
      task.status='resolving';task.updatedAt=new Date().toISOString();this._emit();
      slot.promise=this._run(task,controller).finally(()=>{this.active.delete(task.id);this._emit();this._schedulePump();});
    }
  }
  async _run(task,controller){
    try{
      await this._persist();
      const metadata=await this.engine.preview(task.sourceURL,{authentication:task.authentication,signal:controller.signal});
      if(controller.signal.aborted)throw new DownloadError('cancelled');
      task.metadata=cleanMetadata(metadata);task.title=metadata.title;task.status='downloading';task.updatedAt=new Date().toISOString();await this._persist();this._emit();
      if(controller.signal.aborted)throw new DownloadError('cancelled');
      const result=await this.engine.download(metadata,{quality:task.quality,directory:task.directory,authentication:task.authentication,signal:controller.signal,onProgress:p=>{
        if(!ACTIVE.has(task.status))return;
        task.progress=p;if(p.postprocessor||p.status==='finished')task.status='processing';else if(p.downloadedBytes!==null)task.status='downloading';task.updatedAt=new Date().toISOString();this._emit(true);
      }});
      const completedAt=new Date().toISOString();
      // Commit receipt first. Restart can recover completion if history save or UI delivery is interrupted.
      await atomicJSON(this._receiptFile(task.id),{version:1,taskId:task.id,sourceURL:task.sourceURL,quality:task.quality,...result,completedAt});
      Object.assign(task,{status:'completed',error:null,progress:{fraction:1,status:'finished'},filePath:result.filePath,fileSize:result.fileSize,completedAt,updatedAt:completedAt});
      await this._persist();
    }catch(error){
      const receipt=await this._recoverReceipt(task);
      if(receipt){Object.assign(task,{status:'completed',error:null,filePath:receipt.filePath,fileSize:receipt.fileSize,completedAt:receipt.completedAt,progress:{fraction:1,status:'finished'}});}
      else{task.status=error?.code==='cancelled'?'cancelled':'failed';task.error=publicError(error);task.progress=null;}
      task.updatedAt=new Date().toISOString();await this._persist().catch(()=>this.emit('warning','任务记录未能写入磁盘，已停止本次任务。请检查磁盘空间。'));
    }
  }
  async close(){
    if(this.closing)return;
    this.closing=true;this.previewController?.abort();
    for(const {controller}of this.active.values())controller.abort();
    await Promise.allSettled([...this.active.values()].map(s=>s.promise).concat(this.previewPromise?[this.previewPromise]:[]));
    if(this.changeTimer){clearTimeout(this.changeTimer);this.changeTimer=null;}
    // Queued tasks remain interrupted on the next start; they are never resumed automatically.
    await this.pendingWrite.catch(()=>{});
  }
}
module.exports={DownloadManager,atomicJSON,readJSON,ACTIVE,TERMINAL};
