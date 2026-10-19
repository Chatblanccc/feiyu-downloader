'use strict';
const test = require('node:test'); const assert = require('node:assert/strict');
const fs = require('node:fs/promises'); const path = require('node:path'); const os = require('node:os');
const { recoverSubtitleTask, style, message, FeatherController } = require('../src/controller.cjs');
const { pathToFileURL } = require('node:url');
async function fixture(t) {
 const root = await fs.mkdtemp(path.join(os.tmpdir(),'feiyu-controller-')); t.after(()=>fs.rm(root,{recursive:true,force:true}));
 const dir=path.join(root,'completed'); await fs.mkdir(dir); const file=path.join(dir,'字幕.srt'); await fs.writeFile(file,'subtitle');
 const request={id:'fixed-id',inputPath:path.join(root,'source.mp4'),sourceLanguage:'en',targetLanguage:'zh',textMode:'bilingual',style:style(),outputDirectory:root,outputMode:'srt',bilingual:true};
 const receipt={schemaVersion:1,id:'fixed-id',request,files:[{name:'字幕.srt',size:8}],cueCount:1,duration:3};
 await fs.writeFile(path.join(dir,'completion.json'),JSON.stringify(receipt));return {root,dir,file,receipt,task:{id:'fixed-id',engineRequest:request,expectedDirectory:dir}};
}
test('committed receipt recovers completed export without saved result',async t=>{const f=await fixture(t);assert.equal((await recoverSubtitleTask(f.task)).files[0],f.file);});
test('uncommitted missing receipt remains incomplete',async t=>{const f=await fixture(t);await fs.unlink(path.join(f.dir,'completion.json'));assert.equal(await recoverSubtitleTask(f.task),null);});
test('style or source identity mismatch cannot recover',async t=>{const f=await fixture(t);f.task.engineRequest.style={...style(),colorHex:'FF0000'};assert.equal(await recoverSubtitleTask(f.task),null);});
test('changed output size cannot recover',async t=>{const f=await fixture(t);await fs.appendFile(f.file,'extra');assert.equal(await recoverSubtitleTask(f.task),null);});
test('receipt output path traversal rejected',async t=>{const f=await fixture(t);f.receipt.files[0].name='../字幕.srt';await fs.writeFile(path.join(f.dir,'completion.json'),JSON.stringify(f.receipt));assert.equal(await recoverSubtitleTask(f.task),null);});
test('symlink output rejected',async t=>{const f=await fixture(t);const outside=path.join(f.root,'outside.srt');await fs.rename(f.file,outside);await fs.symlink(outside,f.file);assert.equal(await recoverSubtitleTask(f.task),null);});
test('style validation strict and friendly warning preserved',()=>{assert.throws(()=>style({fontScale:Infinity,colorHex:'FFFFFF',position:'bottom'}));assert.throws(()=>style({...style(),colorHex:'bad'}));assert.equal(message('resource warning'),'resource warning');});
test('controller restart preserves settings and interrupts unfinished job without retry',async t=>{
 const f=await fixture(t);const data=path.join(f.root,'data');await fs.mkdir(data);const models={modelsStatus:async()=>({ready:false,languages:[]}),languages:[]};
 let c=new FeatherController({dataDirectory:data,downloadDirectory:f.root,tools:{},engine:models});await c.init();await c.saveSettings({style:{fontScale:1.6,colorHex:'FFE066',position:'top'},browser:'none'});await c.close();
 await fs.writeFile(path.join(data,'subtitle-history.json'),JSON.stringify([{id:'incomplete',status:'running',request:{input:f.file}}]));
 c=new FeatherController({dataDirectory:data,downloadDirectory:f.root,tools:{},engine:models});await c.init();assert.equal(c.snapshot().settings.style.fontScale,1.6);assert.equal(c.snapshot().subtitles[0].status,'interrupted');assert.equal(c.activeSubtitle,null);await c.close();
});
