// Private Bridge worker. The plan comes only from the protected installation queue.
import { readFile, realpath, lstat } from "node:fs/promises";
import { resolve, isAbsolute } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import {assertCustomerRuntime,execute} from "./erp-customer-runtime.mjs";
import {createHash} from 'node:crypto';

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
  if (!customer) { await runtime.build(); await runtime.prepare(); }
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
