#!/usr/bin/env node
'use strict';
// npm installs host optional binaries. Cross-packaging must explicitly add the target
// prebuild without removing the host prebuild used for local acceptance testing.
const fs=require('node:fs/promises');
const path=require('node:path');
const crypto=require('node:crypto');
const {Readable}=require('node:stream');
const {pipeline}=require('node:stream/promises');
const {createWriteStream}=require('node:fs');
const PROJECT=path.resolve(__dirname,'..');
const PIN=Object.freeze({name:'@img/sharp-win32-x64',version:'0.35.5',url:'https://registry.npmjs.org/@img/sharp-win32-x64/-/sharp-win32-x64-0.35.5.tgz',integrity:'sha512-x76eH0vEiHlcMQu8Y8IenntaACtddpT6W0wmXtWrnKcnKI7ME5DdgqhAD6SEWOEl1v2zDvkZDhFA9KnURwpfqg=='});
const MAX_ARCHIVE=32*1024*1024,MAX_UNPACKED=64*1024*1024;
const hash=(data,algorithm='sha256')=>crypto.createHash(algorithm).update(data).digest('hex');
function verified(data){return 'sha512-'+crypto.createHash('sha512').update(data).digest('base64')===PIN.integrity;}
async function readJSON(file){return JSON.parse(await fs.readFile(file,'utf8'));}
async function filesIn(directory){const output=[];for(const item of await fs.readdir(directory,{withFileTypes:true})){const name=path.join(directory,item.name);if(item.isDirectory())output.push(...await filesIn(name));else if(item.isFile())output.push(name);else throw new Error('Unexpected link in native package');}return output.sort();}
function peInfo(data){
  if(data.length<128||data.toString('ascii',0,2)!=='MZ')throw new Error('Native file has no DOS header');
  const pe=data.readUInt32LE(0x3c);if(pe+24>data.length||data.toString('ascii',pe,pe+4)!=='PE\0\0')throw new Error('Native file has no PE header');
  const machine=data.readUInt16LE(pe+4),sections=data.readUInt16LE(pe+6),sizeOptional=data.readUInt16LE(pe+20),optional=pe+24;
  if(optional+sizeOptional>data.length||sections>96)throw new Error('Invalid PE sections');
  const magic=data.readUInt16LE(optional),directories=optional+(magic===0x20b?112:magic===0x10b?96:0);if(directories===optional)throw new Error('Invalid PE optional header');
  const ranges=[];for(let n=0;n<sections;n++){const offset=optional+sizeOptional+n*40;if(offset+40>data.length)throw new Error('Truncated PE section');ranges.push({rva:data.readUInt32LE(offset+12),span:Math.max(data.readUInt32LE(offset+8),data.readUInt32LE(offset+16)),offset:data.readUInt32LE(offset+20)});}
  const offsetOf=rva=>{if(!rva)return null;for(const r of ranges)if(rva>=r.rva&&rva<r.rva+r.span){const out=r.offset+rva-r.rva;if(out>=data.length)throw new Error('RVA outside PE file');return out;}throw new Error('Unmapped PE RVA');};
  const cstring=rva=>{const offset=offsetOf(rva);if(offset===null)return '';const end=data.indexOf(0,offset);if(end<offset||end-offset>512)throw new Error('Invalid import name');return data.toString('ascii',offset,end);};
  const imports=[],delayedImports=[];
  if(directories+16<=optional+sizeOptional){const start=offsetOf(data.readUInt32LE(directories+8));if(start!==null)for(let n=0;n<4096;n++){const offset=start+n*20;if(offset+20>data.length)throw new Error('Truncated imports');const name=data.readUInt32LE(offset+12);if(!name)break;imports.push(cstring(name));}}
  if(directories+14*8<=optional+sizeOptional){const start=offsetOf(data.readUInt32LE(directories+13*8));if(start!==null)for(let n=0;n<4096;n++){const offset=start+n*32;if(offset+32>data.length)throw new Error('Truncated delayed imports');const attributes=data.readUInt32LE(offset),name=data.readUInt32LE(offset+4);if(!name)break;if(!(attributes&1))throw new Error('Unsupported VA-based delayed imports');delayedImports.push(cstring(name));}}
  return {machine:`0x${machine.toString(16)}`,architecture:machine===0x8664?'x64':machine===0x14c?'x86':machine===0xaa64?'arm64':'unknown',imports:[...new Set(imports)].sort(),delayedImports:[...new Set(delayedImports)].sort()};
}
async function fetchArchive(filename){
  let data;try{const stat=await fs.stat(filename);if(stat.isFile()&&stat.size<=MAX_ARCHIVE){data=await fs.readFile(filename);if(verified(data))return data;}}catch{}
  const response=await fetch(PIN.url,{redirect:'error',signal:AbortSignal.timeout(120000)});
  if(!response.ok)throw new Error(`Official npm archive returned ${response.status}`);
  const announced=Number(response.headers.get('content-length'));if(announced>MAX_ARCHIVE)throw new Error('Native archive too large');
  let size=0;const temporary=filename+'.'+crypto.randomUUID()+'.part';
  try{
    await pipeline(Readable.from((async function*(){for await(const chunk of response.body){size+=chunk.length;if(size>MAX_ARCHIVE)throw new Error('Native archive exceeded limit');yield chunk;}})()),createWriteStream(temporary,{mode:0o600,flags:'wx'}));
    data=await fs.readFile(temporary);if(!verified(data))throw new Error('Native archive SHA512 integrity mismatch');await fs.rename(temporary,filename);return data;
  }catch(error){await fs.rm(temporary,{force:true});throw error;}
}
async function fetchWindowsNodeDeps({project=PROJECT}={}){
  const sharp=await readJSON(path.join(project,'node_modules/sharp/package.json'));
  if(sharp.version!==PIN.version||sharp.optionalDependencies?.[PIN.name]!==PIN.version)throw new Error(`Expected sharp ${PIN.version} with its matching fixed Windows optional dependency; run npm ci first.`);
  const tar=require(require.resolve('tar',{paths:[project]}));
  const cache=path.join(project,'vendor/win-node-deps');await fs.mkdir(cache,{recursive:true});
  const archive=path.join(cache,`sharp-win32-x64-${PIN.version}.tgz`),data=await fetchArchive(archive);
  let unpacked=0,count=0;
  await tar.t({file:archive,strict:true,onReadEntry:entry=>{
    if(++count>64||!entry.path.startsWith('package/')||entry.path.includes('\0')||entry.path.split('/').includes('..')||/^[A-Za-z]:/.test(entry.path)||!['File','Directory'].includes(entry.type))throw new Error('Unsafe npm native package member');
    unpacked+=entry.size;if(unpacked>MAX_UNPACKED)throw new Error('Unpacked native package exceeded limit');
  }});
  const parent=path.join(project,'node_modules/@img');await fs.mkdir(parent,{recursive:true});
  const stage=await fs.mkdtemp(path.join(parent,'.sharp-win32-x64-'));const target=path.join(parent,'sharp-win32-x64');
  try{
    await tar.x({file:archive,cwd:stage,strip:1,strict:true,preservePaths:false});
    const metadata=await readJSON(path.join(stage,'package.json'));
    if(metadata.name!==PIN.name||metadata.version!==PIN.version||!metadata.os?.includes('win32')||!metadata.cpu?.includes('x64'))throw new Error('Wrong target native package identity');
    if(Object.keys(metadata.dependencies||{}).length||Object.keys(metadata.optionalDependencies||{}).length)throw new Error('Pinned native package unexpectedly acquired dependencies; review and pin closure.');
    const files=[];for(const filename of await filesIn(stage)){const bytes=await fs.readFile(filename);const relative=path.relative(stage,filename);const item={path:relative.split(path.sep).join('/'),bytes:bytes.length,sha256:hash(bytes)};if(/\.(?:node|dll)$/i.test(relative)){item.pe=peInfo(bytes);if(item.pe.architecture!=='x64')throw new Error('Wrong PE architecture in Windows x64 native package');}files.push(item);}
    const expected=`lib/sharp-win32-x64-${PIN.version}.node`;if(!files.some(f=>f.path===expected))throw new Error('Windows Sharp entry missing');
    // Replace only this target optional package, retaining every Mac/Linux test prebuild.
    const backup=`${target}.previous-${crypto.randomUUID()}`;let previous=false;
    try{await fs.rename(target,backup);previous=true;}catch(error){if(error.code!=='ENOENT')throw error;}
    try{await fs.rename(stage,target);}catch(error){if(previous)await fs.rename(backup,target);throw error;}
    if(previous)await fs.rm(backup,{recursive:true,force:true});
    const manifest={platform:'win32-x64',package:PIN.name,version:PIN.version,source:{url:PIN.url,integrity:PIN.integrity,archiveSHA256:hash(data),archiveBytes:data.length},entry:expected,exports:metadata.exports,dependencies:metadata.dependencies||{},optionalDependencies:metadata.optionalDependencies||{},files,scope:'Static dependency identity, published SHA512 archive integrity and PE architecture/import inspection. This does not execute native Windows code.'};
    await fs.writeFile(path.join(cache,'native-deps-manifest.json'),JSON.stringify(manifest,null,2)+'\n');return manifest;
  }finally{await fs.rm(stage,{recursive:true,force:true});}
}
if(require.main===module)fetchWindowsNodeDeps().then(manifest=>process.stdout.write(`Verified ${manifest.package}@${manifest.version} for ${manifest.platform}; ${manifest.files.length} files.\n`)).catch(error=>{process.stderr.write(error.message+'\n');process.exitCode=1;});
module.exports={fetchWindowsNodeDeps,peInfo,PIN};
