// Private Bridge worker. The plan comes only from the protected installation queue.
import { readFile, realpath, lstat, mkdir, open, rename, unlink, statfs, writeFile } from "node:fs/promises";
import {createReadStream} from 'node:fs';
import { resolve, isAbsolute } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import {assertCustomerRuntime,execute} from "./erp-customer-runtime.mjs";
import {createHash} from 'node:crypto';

// Delivery belongs to the Bridge. Published Foundation source stays immutable.
export async function prepareErpDistribution(root,descriptor,{run=(program,args,options)=>execute(program,args,options),fetcher=fetch,space=statfs,onProgress=async()=>{},idleMs=120000,maxDurationMs=5400000,attempts=3}={}){
  const distribution=await import(pathToFileURL(resolve(root,'scripts/distribution.mjs')).href);
  const lock=distribution.validateDistributionLock(descriptor),cache=resolve(root,'.coge/runtime/distribution');
  await mkdir(cache,{recursive:true});
  for(const part of ['.coge','.coge/runtime','.coge/runtime/distribution'])if((await lstat(resolve(root,part))).isSymbolicLink())throw Error('Linked ERP download directories are not supported.');
  const digest=b=>createHash('sha256').update(b).digest('hex');
  const inspect=async()=>{
    const rows=JSON.parse(await run('docker',['image','inspect',...Object.values(lock.tags)]));
    for(const [role,id]of Object.entries(lock.images)){
      const image=rows.find(row=>row.RepoTags?.includes(lock.tags[role]));
      if(!image||![id,lock.configImages[role]].includes(image.Id)||image.Os!=='linux'||image.Architecture!=='amd64'||role==='runtime'&&image.Config?.Labels?.['com.cogentspec.erpnext.source']!==lock.imageSourceDigest)throw Error('The approved ERP image identity is unavailable.');
    }
  };
  try{await inspect();await onProgress({phase:'preparing'});return;}catch{/* Fetch only the exact pinned release. */}
  const manifestResponse=await fetcher(distribution.distributionUrl(lock.manifestUrl,lock.version),{redirect:'error',headers:{'accept-encoding':'identity'},signal:AbortSignal.timeout(30000)});
  if(!manifestResponse.ok||manifestResponse.redirected||!manifestResponse.body)throw Error('The approved ERP manifest is unavailable.');
  const chunks=[];let length=0;
  for await(const chunk of manifestResponse.body){length+=chunk.length;if(length>65536)throw Error('The ERP manifest is too large.');chunks.push(chunk);}
  const manifestBytes=Buffer.concat(chunks);if(digest(manifestBytes)!==lock.manifestSha256)throw Error('The ERP manifest failed its integrity check.');
  const manifest=JSON.parse(manifestBytes);
  for(const key of ['protocol','engine','version','imageSourceDigest','imageRecipeDigest'])if(manifest[key]!==lock[key])throw Error('The ERP distribution identity changed.');
  for(const key of ['images','configImages','tags'])if(JSON.stringify(Object.entries(manifest[key]||{}).sort())!==JSON.stringify(Object.entries(lock[key]).sort()))throw Error('The ERP image identity changed.');
  const bundle=manifest.bundle;
  if(!/^[a-f0-9]{64}$/.test(bundle?.sha256)||!Number.isSafeInteger(bundle.bytes)||bundle.bytes<1||bundle.bytes>4*1024**3)throw Error('Invalid approved ERP download.');
  const url=distribution.distributionUrl(bundle.url,lock.version),partial=resolve(cache,bundle.sha256+'.partial'),archive=resolve(cache,bundle.sha256+'.tar.gz');
  const size=async path=>{try{const info=await lstat(path);if(!info.isFile()||info.isSymbolicLink()||info.nlink!==1)throw Error('Linked ERP archives are not supported.');return info.size;}catch(error){if(error.code==='ENOENT')return 0;throw error;}};
  const verify=async path=>{const hash=createHash('sha256');for await(const chunk of createReadStream(path))hash.update(chunk);return hash.digest('hex')===bundle.sha256;};
  let archiveReady=await size(archive)===bundle.bytes&&await verify(archive);
  if(!archiveReady){
    if(await size(archive))await unlink(archive);
    if(await size(partial)>bundle.bytes)await unlink(partial);
    const available=await space(cache);
    if(Number(available.bavail)*Number(available.bsize)<bundle.bytes-await size(partial)+256*1024**2)throw Error('Free enough disk space for the remaining ERP download plus 256 MiB.');
    const deadline=Date.now()+maxDurationMs;
    for(let attempt=0;attempt<attempts;attempt++){
      let received=await size(partial),handle,reader,timer,overall;
      if(received===bundle.bytes){
        await onProgress({phase:'verifying',receivedBytes:received,totalBytes:bundle.bytes});
        if(!await verify(partial)){await unlink(partial);throw Error('The ERP download failed its integrity check. Retry to download a fresh verified copy.');}
        await rename(partial,archive);archiveReady=true;break;
      }
      const controller=new AbortController(),arm=()=>{clearTimeout(timer);timer=setTimeout(()=>controller.abort(),idleMs);};
      try{
        if(Date.now()>=deadline)throw Error('Download time limit reached.');
        overall=setTimeout(()=>controller.abort(),Math.max(1,deadline-Date.now()));arm();
        await onProgress({phase:received?'resuming':'downloading',receivedBytes:received,totalBytes:bundle.bytes});
        const headers={'accept-encoding':'identity',...(received?{Range:`bytes=${received}-`}:{})};
        const response=await fetcher(url,{redirect:'error',headers,signal:controller.signal});arm();
        if(!response.ok||response.redirected||!response.body)throw Error('The approved ERP download is unavailable.');
        if(response.status===206){
          const range=/^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range')||'');
          if(!range||Number(range[1])!==received||Number(range[2])!==bundle.bytes-1||Number(range[3])!==bundle.bytes)throw Error('The ERP resume response changed.');
        }else if(response.status===200){received=0;}else throw Error('Unexpected ERP download response.');
        const declared=response.headers.get('content-length');if(declared!==null&&Number(declared)!==bundle.bytes-received)throw Error('The ERP download size changed.');
        // Range-ignoring servers safely restart from zero rather than append.
        handle=await open(partial,received?'r+':'w',0o600);reader=response.body.getReader();
        while(true){
          const {done,value}=await reader.read();if(done)break;arm();
          if(received+value.length>bundle.bytes)throw Error('The ERP download exceeded its approved size.');
          let written=0;while(written<value.length){const result=await handle.write(value,written,value.length-written,received+written);if(!result.bytesWritten)throw Error('The ERP download could not be written.');written+=result.bytesWritten;}
          received+=value.length;
          await onProgress({phase:'downloading',receivedBytes:received,totalBytes:bundle.bytes});
        }
        await handle.sync();await handle.close();handle=null;
        if(received!==bundle.bytes)throw Error('The ERP download was interrupted.');
      }catch(error){
        if(handle){await handle.close();handle=null;}
        if(attempt+1>=attempts||Date.now()>=deadline)throw Error('The ERP download was interrupted. Downloaded bytes have been kept; Retry installation will resume.');
        await onProgress({phase:'retrying',receivedBytes:await size(partial),totalBytes:bundle.bytes});
      }finally{
        clearTimeout(timer);clearTimeout(overall);controller.abort();
        if(reader)await reader.cancel().catch(()=>{});if(handle)await handle.close();
      }
    }
    // A completed final attempt still needs digest verification and promotion.
    if(!archiveReady&&await size(partial)===bundle.bytes){
      await onProgress({phase:'verifying',receivedBytes:bundle.bytes,totalBytes:bundle.bytes});
      if(!await verify(partial)){await unlink(partial);throw Error('The ERP download failed its integrity check. Retry to download a fresh verified copy.');}
      await rename(partial,archive);archiveReady=true;
    }
    if(!archiveReady)throw Error('The ERP download is incomplete. Downloaded bytes have been kept.');
  }
  await onProgress({phase:'loading',receivedBytes:bundle.bytes,totalBytes:bundle.bytes});
  await run('docker',['image','load','--input',archive],{timeout:600000});await inspect();
  // Keep the verified archive through setup, so a Docker/setup failure can retry.
  await onProgress({phase:'preparing'});
  return {archive,sha256:bundle.sha256,bytes:bundle.bytes};
}

export async function stopErpInstallation(project,{run=args=>execute('docker',args)}={}){
  const engine=project?.projectType==='erpnext_business_app'?'erpnext':project?.projectType==='odoo_business_app'?'odoo':null;
  if(!engine||project.packId!==`coge.${engine}-business-app.foundation`||!/^[a-f0-9-]{36}$/.test(project.id||'')||!isAbsolute(project.targetPath||''))throw Error('Invalid installation stop identity.');
  const ids=(await run(['container','ls','-a','-q','--no-trunc','--filter',`label=com.cogentspec.${engine}.project=`+project.id])).split(/\s+/).filter(Boolean);
  const stopped=()=>({stopped:true,projectId:project.id,runtimeId:project.contractRuntimeId,targetPath:project.targetPath,containersStopped:ids.length,dataKept:true});
  let root,identity,plan;
  try{
    root=await realpath(project.targetPath);if(root.toLowerCase()!==resolve(project.targetPath).toLowerCase())throw Error('Linked ERP folders are not supported.');
    for(const path of ['.coge','.coge/knowledge-manifest.json',`.coge/${engine}-project.json`])if((await lstat(resolve(root,path))).isSymbolicLink())throw Error('Linked installation metadata is not supported.');
    identity=JSON.parse(await readFile(resolve(root,'.coge/knowledge-manifest.json')));plan=JSON.parse(await readFile(resolve(root,`.coge/${engine}-project.json`)));
  }catch(error){
    if(error.code!=='ENOENT'||ids.length)throw error;
    try{await lstat(resolve(project.targetPath,'.coge/runtime/listener.json'));throw Error('An incomplete installation still has a listener.');}catch(listenerError){if(listenerError.code!=='ENOENT')throw listenerError;}
    return stopped();
  }
  if(identity.project?.requestId!==project.id||identity.binding?.packRef!==`${project.packId}@${project.packVersion}`||plan.projectId!==project.id||plan.runtimeId!==project.contractRuntimeId)throw Error('The stopped installation identity changed.');
  const sha=s=>createHash('sha256').update(s).digest('hex'),key=`coge-${engine}-`+sha(project.id).slice(0,20),rootDigest=sha(root);
  const verify=c=>{const labels=c.Config?.Labels||{},name=String(c.Name||'').replace(/^\//,'');if(labels[`com.cogentspec.${engine}.project`]!==project.id||labels[`com.cogentspec.${engine}.root`]!==rootDigest||!(name===key||name.startsWith(key+'-')))throw Error('An installation container belongs to another folder.');};
  if(ids.length){
    for(const container of JSON.parse(await run(['container','inspect',...ids])))verify(container);
    await run(['container','stop','--time','15',...ids]);
    for(const container of JSON.parse(await run(['container','inspect',...ids]))){verify(container);if(container.State?.Running)throw Error('An installation container is still running.');}
  }
  let listener;try{listener=JSON.parse(await readFile(resolve(root,'.coge/runtime/listener.json')));}catch(error){if(error.code!=='ENOENT')throw error;}
  if(listener){
    if(listener.projectId!==project.id||!Number.isInteger(listener.pid)||listener.pid<=0||listener.pid===process.pid)throw Error('The installation listener cannot be safely stopped.');
    const runtimeFile=resolve(root,`scripts/${engine}-runtime.mjs`);
    if(process.platform==='win32'){
      const script=`$ErrorActionPreference='Stop';$v=[Console]::In.ReadToEnd()|ConvertFrom-Json;$p=Get-CimInstance Win32_Process -Filter ("ProcessId="+[int]$v.pid);if($p){if($p.Name -notmatch '^node(?:\\.exe)?$' -or $p.CommandLine -notmatch ('(?:^|["\\s])'+[Regex]::Escape([string]$v.runtimeFile)+'(?=["\\s]|$)')){throw 'Listener identity changed'};Stop-Process -Id $p.ProcessId -Force}`;
      await execute('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{input:JSON.stringify({pid:listener.pid,runtimeFile})});
    }else{
      let command;try{command=(await readFile(`/proc/${listener.pid}/cmdline`,'utf8')).split('\0');}catch(error){if(error.code!=='ENOENT')throw error;}
      if(command){if(!command.includes(runtimeFile))throw Error('Listener identity changed');try{process.kill(listener.pid);}catch(error){if(error.code!=='ESRCH')throw error;}}
    }
  }
  return stopped();
}

export async function installErpProject(project, inspectOnly = false) {
  const engine = project?.projectType === "erpnext_business_app" && project?.packId === "coge.erpnext-business-app.foundation" ? "erpnext"
    : project?.projectType === "odoo_business_app" && project?.packId === "coge.odoo-business-app.foundation" ? "odoo" : null;
  if (!project || !engine
    || !isAbsolute(project.targetPath) || !/^[a-f0-9-]{36}$/.test(project.id)) throw Error("Invalid ERP installation identity.");
  const runtimeFile = `scripts/${engine}-runtime.mjs`, planFile = `.coge/${engine}-project.json`;
  const root = await realpath(project.targetPath);
  if (root.toLowerCase() !== resolve(project.targetPath).toLowerCase()) throw Error("Linked ERP folders are not supported.");
  const json = async path => JSON.parse(await readFile(resolve(root, path), "utf8"));
  const identity = await json(".coge/knowledge-manifest.json"), plan = await json(planFile);
  if (identity.project?.requestId !== project.id || identity.project?.type !== project.projectType
    || identity.binding?.packRef !== `${project.packId}@${project.packVersion}`
    || plan.projectId !== project.id || plan.runtimeId !== project.contractRuntimeId) throw Error("The ERP project identity changed.");
  for (const path of ["scripts", runtimeFile, ".coge", planFile]) {
    if ((await lstat(resolve(root, path))).isSymbolicLink()) throw Error("Linked ERP files are not supported.");
  }
  const runtime = await import(pathToFileURL(resolve(root, runtimeFile)).href);
  const validated = await runtime.validatePlan();
  const customer = engine === "erpnext" ? await assertCustomerRuntime(project) : null;
  if (!inspectOnly) { try { return await installErpProject(project, true); } catch { /* A stopped, identity-checked project may be restarted below. */ } }
  if (inspectOnly) {
    const inspection = await runtime.inspect(), listener = await json(".coge/runtime/listener.json");
    if (!inspection.ready || listener.projectId !== project.id || listener.sourceDigest !== validated.sourceDigest || !Number.isInteger(listener.pid)) throw Error("The ERP connection needs refreshing.");
    process.kill(listener.pid, 0);
    const health = await fetch(new URL("/__cogentspec/health", listener.url), { signal: AbortSignal.timeout(3000) }).then(r => r.json());
    if (health.projectId !== project.id || !health.ready || health.sourceDigest !== validated.sourceDigest) throw Error("The ERP listener is not verified.");
    return { engine, projectId: project.id, targetPath: project.targetPath, runtimeId: project.contractRuntimeId,
      foundationVersion: project.packVersion, modules: inspection.modules, ready: true,
      sourceDigest: validated.sourceDigest, customerRelease: customer ? {id:customer.releaseId,imageId:customer.imageId} : null, localUrl: listener.url, processId: listener.pid };
  }
  let delivery;
  let lastProgress=0,currentProgress;
  const progressPath=resolve(root,'.coge/runtime/installation-progress.json');
  const progress=async value=>{
    currentProgress=value;
    if(value.phase==='downloading'&&Date.now()-lastProgress<1000)return;
    lastProgress=Date.now();await mkdir(resolve(root,'.coge/runtime'),{recursive:true});
    const target=progressPath+'.'+process.pid+'.tmp';
    await writeFile(target,JSON.stringify({...value,projectId:project.id,updatedAt:new Date().toISOString()}),{mode:0o600});await rename(target,progressPath);
  };
  if (!customer) {
    await progress({phase:'checking'});
    if(validated.distribution){
      try{delivery=await prepareErpDistribution(root,validated.distribution,{onProgress:progress});}
      catch(error){if(['downloading','resuming','retrying'].includes(currentProgress?.phase))await progress({...currentProgress,phase:'paused'});throw error;}
    }
    await progress({phase:'preparing'});await runtime.build();await runtime.prepare();
  }
  await progress({phase:'starting'});
  // Keep the native application running independently of this bounded installer.
  const child = spawn(process.execPath, [resolve(root, runtimeFile), "start"], {
    cwd: root, windowsHide: true, detached: true, stdio: ["ignore", "pipe", "ignore"],
  });
  const running = await new Promise((done, fail) => {
    let output = "", finished = false;
    const timer = setTimeout(() => { if (!finished) { child.kill(); fail(Error("The ERP did not start in time.")); } }, 120_000);
    child.once("error", () => { clearTimeout(timer); fail(Error("The ERP could not start.")); });
    child.once("exit", () => { if (!finished) { clearTimeout(timer); fail(Error("The ERP stopped before verification.")); } });
    child.stdout.on("data", chunk => {
      output += chunk.toString(); if (output.length > 16384) output = output.slice(-16384);
      for (const line of output.split(/\r?\n/)) {
        try {
          const value = JSON.parse(line);
          if (value.status === "running" && value.projectId === project.id && value.localUrl) {
            finished = true; clearTimeout(timer); child.stdout.destroy(); child.unref(); done(value); return;
          }
        } catch { /* Ignore non-result output; never forward raw process output. */ }
      }
    });
  });
  const inspected = await runtime.inspect();
  if (!inspected.ready || inspected.projectId !== project.id) throw Error("The selected ERP apps were not verified.");
  const listener = await json(".coge/runtime/listener.json");
  if (listener.url !== running.localUrl || listener.projectId !== project.id || !Number.isInteger(listener.pid)) throw Error("The ERP listener ownership could not be verified.");
  process.kill(listener.pid, 0);
  if(delivery?.archive){try{await unlink(delivery.archive);}catch{/* A retained verified archive is safe to reuse. */}}
  return { engine, projectId: project.id, targetPath: project.targetPath, runtimeId: project.contractRuntimeId,
    foundationVersion: project.packVersion, modules: inspected.modules, ready: true,
    sourceDigest: validated.sourceDigest, customerRelease: customer ? {id:customer.releaseId,imageId:customer.imageId} : null, localUrl: running.localUrl, processId: listener.pid };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    let input = ""; for await (const chunk of process.stdin) { input += chunk; if (input.length > 8192) throw Error("Invalid plan."); }
    console.log(JSON.stringify(process.argv.includes('--stop')?await stopErpInstallation(JSON.parse(input)):await installErpProject(JSON.parse(input), process.argv.includes("--inspect"))));
  } catch { console.error("The ERP installation could not be verified. Existing project data was kept."); process.exitCode = 1; }
}
