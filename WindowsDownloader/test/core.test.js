'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const {once}=require('node:events');
const {DownloadManager,DownloadEngine,DownloadError,runProcess,parseShareLinks,readableFailure,PROGRESS_PREFIX,FINAL_PREFIX,validateFinalFile,atomicJSON}=require('../src/core');
async function temporary(t){const root=await fs.mkdtemp(path.join(os.tmpdir(),'FeatherCoreTest-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));return root;}
const quietSample=async()=>{const {sampleProcesses}=require('../src/core');return sampleProcesses();};
const shortLimits={totalTimeoutMs:1500,preparationTimeoutMs:150,inactivityTimeoutMs:150,processingTimeoutMs:150,resourceSampleIntervalMs:1000,tickIntervalMs:20,killGraceMs:50,exitGraceMs:70};
const nodeRun=(source,options={})=>runProcess({executable:process.execPath,args:['-e',source],resourceSample:quietSample,limits:shortLimits,...options});
async function waitUntil(predicate,milliseconds=4000){const start=Date.now();while(!predicate()){if(Date.now()-start>milliseconds)throw new Error('condition timed out');await new Promise(r=>setTimeout(r,10));}}

test('share text preserves signed queries, trims wrappers, rejects URL credentials',()=>{
  assert.deepEqual(parseShareLinks('复制 https://v.douyin.com/hello/?a=1&token=A%2FB 。 (https://x.com/u/status/123/video/1?s=46). https://user:pass@example.com/x'),['https://v.douyin.com/hello/?a=1&token=A%2FB','https://x.com/u/status/123/video/1?s=46']);
  assert.deepEqual(parseShareLinks('https://a.example/x_(y) https://a.example/x_(y)'),['https://a.example/x_(y)']);
});
test('error classification follows actual error and does not mislabel X visibility as deletion',()=>{
  assert.match(readableFailure('WARNING: cookies unavailable\nERROR: network connection failed'),/网络/);
  assert.match(readableFailure('ERROR: [twitter] Video #1 is unavailable'),/登录或内容可见性/);
  assert.match(readableFailure('ERROR: video has been deleted'),/删除/);
  assert.doesNotMatch(readableFailure('ERROR: https://example.com/?token=deleted&login=secret unavailable'),/secret|token|删除/);
});
test('process normal exit returns bounded output and never invokes a shell',async()=>{
  const result=await nodeRun('process.stdout.write("hello");process.stderr.write("warning");');
  assert.equal(result.exitCode,0);assert.equal(result.stdout,'hello');assert.equal(result.stderr,'warning');
});
test('process cancellation releases a running child',async()=>{
  const controller=new AbortController();const operation=nodeRun('setInterval(()=>{},1000)',{signal:controller.signal});setTimeout(()=>controller.abort(),70);
  await assert.rejects(operation,{code:'cancelled'});
});
test('repeated byte counts are not actual progress and stop on inactivity',async()=>{
  const line=JSON.stringify(PROGRESS_PREFIX+JSON.stringify({status:'downloading',downloaded_bytes:10,total_bytes:100,item:'video'})+'\n');
  const start=Date.now();await assert.rejects(nodeRun(`setInterval(()=>process.stdout.write(${line}),20)`,{captureStdout:false,progressTracking:true}),{code:'stalled'});assert.ok(Date.now()-start<1500);
});
test('repeated finished messages do not reset postprocessing timeout',async()=>{
  const line=JSON.stringify(PROGRESS_PREFIX+JSON.stringify({status:'finished',downloaded_bytes:100,total_bytes:100,item:'video'})+'\n');
  await assert.rejects(nodeRun(`setInterval(()=>process.stdout.write(${line}),20)`,{captureStdout:false,progressTracking:true}),{code:'stalled'});
});
test('metadata stdout and individual line flooding stop before unbounded accumulation',async()=>{
  await assert.rejects(nodeRun('process.stdout.write("x".repeat(50000));setInterval(()=>{},1000)',{limits:{...shortLimits,maximumOutputBytes:20000}}),{code:'outputTooLarge'});
  await assert.rejects(nodeRun('process.stdout.write("x".repeat(50000));setInterval(()=>{},1000)',{captureStdout:false,onLine:()=>{},limits:{...shortLimits,maximumLineBytes:10000}}),{code:'outputTooLarge'});
});
test('own tree memory excess stops helper',async()=>{
  await assert.rejects(nodeRun('setInterval(()=>{},1000)',{resourceSample:async()=>[{pid:1,ppid:0,rss:0,identity:'other'},{pid:process.pid,ppid:1,rss:0,identity:'parent'}],limits:{...shortLimits,totalTimeoutMs:100,resourceSampleIntervalMs:1000}}),{code:'timedOut'});
  // Inject a deterministic owned sample based on the actual spawned child ID.
  let childPID;const {spawn}=require('node:child_process');
  await assert.rejects(nodeRun('setInterval(()=>{},1000)',{spawn:(...args)=>{const child=spawn(...args);childPID=child.pid;return child;},resourceSample:async()=>[{pid:childPID,ppid:process.pid,rss:4096,identity:'owned'}],limits:{...shortLimits,maximumMemoryBytes:1024}}),{code:'memoryLimitExceeded'});
});
test('successful final file outside destination, symlink escapes and empty files are rejected',async t=>{
  const root=await temporary(t),dir=path.join(root,'videos');await fs.mkdir(dir);const outside=path.join(root,'outside.mp4');await fs.writeFile(outside,'video');await fs.writeFile(path.join(dir,'empty.mp4'),'');
  await assert.rejects(validateFinalFile(outside,dir),{code:'missingFinalFile'});await assert.rejects(validateFinalFile(path.join(dir,'empty.mp4'),dir),{code:'missingFinalFile'});
  if(process.platform!=='win32'){await fs.symlink(outside,path.join(dir,'escape.mp4'));await assert.rejects(validateFinalFile(path.join(dir,'escape.mp4'),dir),{code:'missingFinalFile'});}
});
test('engine requires successful exit plus verified final path; anonymous arguments disable cookie reads',async t=>{
  const root=await temporary(t),file=path.join(root,'result.mp4');await fs.writeFile(file,'video');const calls=[];
  const runner=async options=>{calls.push(options);if(options.args.includes('--dump-single-json'))return{exitCode:0,stdout:JSON.stringify({id:'x',title:'Example',formats:[]}),stderr:''};options.onLine(FINAL_PREFIX+JSON.stringify(file),'stdout');return{exitCode:0,stderr:''};};
  const engine=new DownloadEngine({tools:{ytDlp:process.execPath,ffmpeg:process.execPath},runner});const metadata=await engine.preview('https://example.com/video');const result=await engine.download(metadata,{directory:root});assert.equal(result.fileSize,5);
  assert.ok(calls.every(c=>c.args.includes('--no-cookies')&&c.args.includes('--no-cookies-from-browser')));
  assert.ok(calls.every(c=>!c.args.includes('--cookies-from-browser')));
  assert.equal(calls[1].captureStdout,false);
  const failing=new DownloadEngine({tools:{ytDlp:process.execPath,ffmpeg:process.execPath},runner:async options=>{options.onLine(FINAL_PREFIX+JSON.stringify(file),'stdout');return{exitCode:1,stderr:'ERROR: download failed'};}});
  await assert.rejects(failing.download(metadata,{directory:root}),{code:'processFailed'});
});
test('file cookies are copied privately, not modified or kept after invocation',async t=>{
  const root=await temporary(t),cookies=path.join(root,'cookies.txt');const content='# Netscape HTTP Cookie File\nexample.com\tFALSE\t/\tFALSE\t0\tname\tsecret\n';await fs.writeFile(cookies,content);let copied;
  const engine=new DownloadEngine({tools:{ytDlp:process.execPath,ffmpeg:process.execPath},runner:async options=>{copied=options.args[options.args.indexOf('--cookies')+1];assert.notEqual(copied,cookies);assert.equal(await fs.readFile(copied,'utf8'),content);await fs.appendFile(copied,'changed');return{exitCode:1,stderr:'ERROR: failed'};}});
  await assert.rejects(engine.preview('https://example.com/video',{authentication:{type:'file',path:cookies}}));assert.equal(await fs.readFile(cookies,'utf8'),content);await assert.rejects(fs.access(copied));
});
function fakeEngine(directory,{hang=false,lateCancel=false}={}){
  return {preview:async(sourceURL,{signal})=>{if(signal.aborted)throw new DownloadError('cancelled');return {id:'example',title:'A video',sourceURL,availableHeights:[1080],isLive:false};},download:async(metadata,{signal,onProgress})=>{
    onProgress({fraction:0.5,downloadedBytes:5,totalBytes:10,status:'downloading'});
    if(signal.aborted)throw new DownloadError('cancelled');
    if(hang)return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new DownloadError('cancelled')),{once:true}));
    await fs.mkdir(directory,{recursive:true});const filePath=path.join(directory,'example.mp4');await fs.writeFile(filePath,'video-data');if(lateCancel)await new Promise(r=>setTimeout(r,30));return{filePath,fileSize:10};
  }};
}
test('manager completion persists receipt before restart and history-only removal keeps media',async t=>{
  const root=await temporary(t),directory=path.join(root,'videos'),dataDirectory=path.join(root,'data');const manager=new DownloadManager({downloadDirectory:directory,dataDirectory,engine:fakeEngine(directory)});await manager.init();const id=await manager.add('https://example.com/video');await waitUntil(()=>manager.snapshot().tasks[0].status==='completed');await manager.close();
  const restored=new DownloadManager({downloadDirectory:directory,dataDirectory,engine:fakeEngine(directory)});await restored.init();assert.equal(restored.snapshot().tasks[0].status,'completed');await restored.remove(id);assert.equal(await fs.readFile(path.join(directory,'example.mp4'),'utf8'),'video-data');await restored.close();
});
test('receipt recovers a helper-finished task if app stopped before completion history save',async t=>{
  const root=await temporary(t),directory=path.join(root,'videos'),dataDirectory=path.join(root,'data');await fs.mkdir(directory);const filePath=path.join(directory,'result.mp4');await fs.writeFile(filePath,'video');
  const task={id:'test-task',sourceURL:'https://example.com/video',quality:'best',directory,authentication:{type:'none'},status:'downloading',title:'Example',createdAt:new Date().toISOString(),updatedAt:new Date().toISOString()};
  await atomicJSON(path.join(dataDirectory,'download-history.json'),{version:1,tasks:[task]});await atomicJSON(path.join(dataDirectory,'download-receipts','test-task.json'),{version:1,taskId:task.id,sourceURL:task.sourceURL,quality:'best',filePath,fileSize:5,completedAt:new Date().toISOString()});
  const manager=new DownloadManager({downloadDirectory:directory,dataDirectory,engine:fakeEngine(directory)});await manager.init();assert.equal(manager.snapshot().tasks[0].status,'completed');await manager.close();
});
test('restart interrupts queued and downloading tasks without issuing requests',async t=>{
  const root=await temporary(t),dataDirectory=path.join(root,'data'),directory=path.join(root,'videos');let requests=0;
  await atomicJSON(path.join(dataDirectory,'download-history.json'),{version:1,tasks:['queued','downloading'].map((status,i)=>({id:`task-${i}`,sourceURL:'https://example.com/video',quality:'best',directory,authentication:{type:'none'},status,title:'Example'}))});
  const manager=new DownloadManager({downloadDirectory:directory,dataDirectory,engine:{preview:async()=>{requests++;}}});await manager.init();await new Promise(r=>setTimeout(r,60));assert.equal(requests,0);assert.deepEqual(manager.snapshot().tasks.map(t=>t.status),['interrupted','interrupted']);await manager.close();
});
test('cancel active download settles and leaves no active slots',async t=>{
  const root=await temporary(t),directory=path.join(root,'videos');const manager=new DownloadManager({downloadDirectory:directory,dataDirectory:path.join(root,'data'),engine:fakeEngine(directory,{hang:true})});await manager.init();const id=await manager.add('https://example.com/video');await waitUntil(()=>manager.snapshot().tasks[0].status==='downloading');await manager.cancel(id);await waitUntil(()=>manager.snapshot().tasks[0].status==='cancelled'&&manager.snapshot().activeCount===0);await manager.close();
});
test('late cancellation after delivered file does not erase completed task',async t=>{
  const root=await temporary(t),directory=path.join(root,'videos');const manager=new DownloadManager({downloadDirectory:directory,dataDirectory:path.join(root,'data'),engine:fakeEngine(directory,{lateCancel:true})});await manager.init();const id=await manager.add('https://example.com/video');await waitUntil(()=>manager.snapshot().tasks[0].status==='downloading');await manager.cancel(id);await waitUntil(()=>manager.snapshot().tasks[0].status==='completed');await manager.close();
});
test('preview replacement cancels and waits for prior cleanup before starting another process',async t=>{
  const root=await temporary(t);let active=0,peak=0;
  const engine={preview:async(text,{signal})=>{active++;peak=Math.max(peak,active);return new Promise((resolve,reject)=>{signal.addEventListener('abort',()=>setTimeout(()=>{active--;reject(new DownloadError('cancelled'));},30),{once:true});});}};
  const manager=new DownloadManager({downloadDirectory:root,dataDirectory:path.join(root,'data'),engine});await manager.init();const first=manager.preview('https://example.com/a').catch(e=>e);await waitUntil(()=>active===1);const second=manager.preview('https://example.com/b').catch(e=>e);await first;await waitUntil(()=>active===1);await manager.close();await second;assert.equal(peak,1);assert.equal(active,0);
});

test('repeated resource monitor failures stop task instead of running unguarded',async()=>{
  let warnings=0;await assert.rejects(nodeRun('setInterval(()=>{},1000)',{resourceSample:async()=>{throw new Error('monitor blocked');},onResourceWarning:()=>warnings++,limits:{...shortLimits,resourceSampleIntervalMs:20}}),{code:'resourceMonitoringUnavailable'});assert.equal(warnings,1);
});
test('post-root-exit inherited output pipes cannot hold task open indefinitely',async()=>{
  const source='require("node:child_process").spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{stdio:["ignore",process.stdout,process.stderr]});process.exit(0);';
  const start=Date.now();await assert.rejects(nodeRun(source),{code:'helperDidNotExit'});assert.ok(Date.now()-start<1000);
});
test('manager never exceeds two queued downloads and cancellation frees a slot',async t=>{
  const root=await temporary(t);let active=0,peak=0;
  const engine={preview:async sourceURL=>({id:'x',title:'Example',sourceURL}),download:async(metadata,{signal})=>{active++;peak=Math.max(peak,active);if(signal.aborted){active--;throw new DownloadError('cancelled');}return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>{active--;reject(new DownloadError('cancelled'));},{once:true}));}};
  const manager=new DownloadManager({downloadDirectory:root,dataDirectory:path.join(root,'data'),engine,concurrency:99});await manager.init();const ids=await Promise.all(['a','b','c'].map(s=>manager.add(`https://example.com/${s}`)));await waitUntil(()=>active===2);assert.equal(peak,2);await manager.cancel(ids[0]);await waitUntil(()=>active===2&&manager.snapshot().tasks.find(t=>t.id===ids[0]).status==='cancelled');await manager.close();assert.equal(peak,2);assert.equal(active,0);
});
test('an inventory that omits the running owned child is treated as monitoring failure',async()=>{
  await assert.rejects(nodeRun('setInterval(()=>{},1000)',{resourceSample:async()=>[],limits:{...shortLimits,resourceSampleIntervalMs:20}}),{code:'resourceMonitoringUnavailable'});
});
