// Protected ERP removal. Read identity data, never execute customer project code.
import { readFile, writeFile, realpath, lstat, open, unlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, dirname, basename, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile), sha = value => createHash('sha256').update(value).digest('hex');
const equalPath = (a,b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
async function docker(args) {
  const {stdout} = await exec('docker',args,{windowsHide:true,timeout:120000,maxBuffer:8*1024*1024});
  return stdout.trim();
}
async function safeAncestors(path) {
  for (let current=path;dirname(current)!==current;current=dirname(current)) {
    try { if ((await lstat(current)).isSymbolicLink()) throw Error('Linked ERP paths are not supported.'); }
    catch(error) { if (error.code!=='ENOENT') throw error; }
  }
}
function matchesProof(p,project) {
  return p?.protocol===1 && p.projectId===project.id && p.runtimeId===project.contractRuntimeId
    && p.packId===project.packId && p.packVersion===project.packVersion && p.targetPath===project.targetPath
    && p.resourcesRemoved===true && typeof p.canonicalRoot==='string' && equalPath(p.canonicalRoot,resolve(project.targetPath));
}
const imageId = value => /^sha256:[a-f0-9]{64}$/.test(value || '');
const words = value => value.split(/\s+/).filter(Boolean);
async function imageInventory(run) {
  const ids=[...new Set(words(await run(['image','ls','-a','-q','--no-trunc'])))];
  const images=[];
  for(let i=0;i<ids.length;i+=100)images.push(...JSON.parse(await run(['image','inspect',...ids.slice(i,i+100)])));
  return new Map(images.map(image=>[image.Id,image]));
}
function managedImage(image,project,engine) {
  if(engine!=='erpnext'||!imageId(image?.Id))return false;
  const labels=image.Config?.Labels||{},customer=labels['com.cogentspec.customer.project'];
  if(!/^[a-f0-9]{64}$/.test(labels['com.cogentspec.erpnext.source']||''))return false;
  // Foundation labels are inherited by customer images. Never mistake another
  // installation's customer build for the shared foundation.
  if(customer&&(customer!==project.id||labels['com.cogentspec.customer.runtime']!==project.contractRuntimeId))return false;
  return (image.RepoTags||[]).every(tag=>/^cogentspec\/erpnext:[a-f0-9]{64}$/.test(tag)||/^cogent-vrc-base:[a-f0-9]{64}$/.test(tag));
}
async function removalImages({run,project,engine,root,present,resources}) {
  if(engine!=='erpnext')return [];
  const inventory=await imageInventory(run),ids=new Set(resources.filter(r=>r.kind==='container').map(r=>r.data.Image).filter(imageId));
  const path=resolve(root,'.coge/erp-removal-images.json');
  if(present){
    for(const file of ['.coge/runtime/image.json','.coge/erp-removal-images.json']){
      const location=resolve(root,file);await safeAncestors(location);
      let data;try{data=JSON.parse(await readFile(location,'utf8'));}catch(error){if(error.code==='ENOENT')continue;throw error;}
      if(file.endsWith('/image.json')){
        if(!imageId(data.image))throw Error('The ERP image receipt is invalid.');ids.add(data.image);
      }else{
        if(data.projectId!==project.id||data.runtimeId!==project.contractRuntimeId||data.rootDigest!==sha(root)||!Array.isArray(data.ids)||data.ids.length>1000||data.ids.some(id=>!imageId(id)))throw Error('The ERP image cleanup identity changed.');
        for(const id of data.ids)ids.add(id);
      }
    }
  }
  // Includes inactive, superseded and untagged builds for every customisation
  // layer belonging to this installation, even when no container uses them.
  for(const image of inventory.values())if(image.Config?.Labels?.['com.cogentspec.customer.project']===project.id&&image.Config.Labels['com.cogentspec.customer.runtime']===project.contractRuntimeId)ids.add(image.Id);
  for(const id of ids){
    const image=inventory.get(id);if(!managedImage(image,project,engine))continue;
    const labels=image.Config.Labels;
    for(const base of [image.Parent,labels['com.cogentspec.erpnext.base'],labels['com.cogentspec.customer.base']])if(imageId(base)&&managedImage(inventory.get(base),project,engine))ids.add(base);
  }
  const selected=[...ids].filter(id=>managedImage(inventory.get(id),project,engine));
  if(present){
    // Record before removing containers: a disconnected retry must still know
    // which images belonged to the installation. Never execute project code.
    await writeFile(path,JSON.stringify({projectId:project.id,runtimeId:project.contractRuntimeId,rootDigest:sha(root),ids:selected}),{mode:0o600});
  }
  return selected.sort((a,b)=>(inventory.get(b).RootFS?.Layers?.length||0)-(inventory.get(a).RootFS?.Layers?.length||0));
}
async function removeImages(ids,run,project,engine) {
  const result={removed:0,retained:[]};
  for(const id of ids){
    // Re-read immediately before each removal. Keep images referenced by any
    // running OR stopped foreign container, or by another retained image.
    const inventory=await imageInventory(run),image=inventory.get(id);if(!image)continue;
    if(!managedImage(image,project,engine)){result.retained.push({id,reason:'identity_changed'});continue;}
    const containers=words(await run(['container','ls','-a','-q','--no-trunc']));
    let used=false;
    for(let i=0;i<containers.length;i+=100)if(JSON.parse(await run(['container','inspect',...containers.slice(i,i+100)])).some(c=>c.Image===id))used=true;
    const layers=image.RootFS?.Layers||[];
    const dependent=[...inventory.values()].some(other=>other.Id!==id&&(other.Parent===id
      ||[other.Config?.Labels?.['com.cogentspec.customer.base'],other.Config?.Labels?.['com.cogentspec.erpnext.base']].includes(id)
      ||layers.length>0&&(other.RootFS?.Layers?.length||0)>layers.length&&layers.every((layer,index)=>other.RootFS.Layers[index]===layer)));
    if(used||dependent){result.retained.push({id,reason:used?'container_reference':'dependent_image'});continue;}
    // Remove our aliases too; removing just one tag leaves the image behind.
    // No force and no implicit parent pruning, so Docker remains the final
    // guard against concurrent users and unrelated parent-image deletion.
    for(const ref of image.RepoTags?.length?image.RepoTags:[id]){
      if(ref!==id){const current=JSON.parse(await run(['image','inspect',ref]))[0];if(current.Id!==id)throw Error('An ERP image tag changed during removal.');}
      await run(['image','rm','--no-prune',ref]);
    }
    if((await imageInventory(run)).has(id))throw Error('An unused ERP image remains. Retry removal before deleting its folder.');
    result.removed++;
  }
  return result;
}
export async function removeErpResources(project, { run=docker, previousProof=null }={}) {
  const engine=project?.projectType==='erpnext_business_app'&&project?.packId==='coge.erpnext-business-app.foundation'?'erpnext':project?.projectType==='odoo_business_app'&&project?.packId==='coge.odoo-business-app.foundation'?'odoo':null;
  if (!engine
    || !/^[a-f0-9-]{36}$/i.test(project.id||'') || !/^[a-f0-9-]{36}$/i.test(project.contractRuntimeId||'')
    || !isAbsolute(project.targetPath||'') || !isAbsolute(project.workDirectory||'')
    || !/^[a-z0-9][a-z0-9-]*$/.test(project.projectSlug||'')) throw Error('Invalid approved ERP deletion identity.');
  const target=resolve(project.targetPath),parent=resolve(project.workDirectory);
  if (!equalPath(dirname(target),parent) || basename(target)!==project.projectSlug || dirname(parent)===parent) throw Error('ERP deletion must target its exact registered project folder.');
  await safeAncestors(target);
  let root, present=true;
  try { root=await realpath(target); if(!equalPath(root,target)) throw Error('The ERP folder identity changed.'); }
  catch(error) { if(error.code!=='ENOENT' || !matchesProof(previousProof,project)) throw error; present=false;root=previousProof.canonicalRoot; }
  if(present){
    const json=async p=>{const path=resolve(root,p);await safeAncestors(path);return JSON.parse(await readFile(path,'utf8'));};
    const identity=await json('.coge/knowledge-manifest.json'),plan=await json(`.coge/${engine}-project.json`),binding=await json('.coge/contract-binding.json');
    if(identity.project?.requestId!==project.id || identity.project?.type!==project.projectType
      || identity.binding?.packRef!==`${project.packId}@${project.packVersion}` || plan.projectId!==project.id
      || plan.runtimeId!==project.contractRuntimeId || binding.projectType!==project.projectType
      || binding.packId!==project.packId || binding.packVersion!==project.packVersion
      || binding.contractChecksum!==plan.contractChecksum) throw Error('The ERP folder does not match the approved deletion.');
  }
  let lock;
  const lockPath=resolve(root,'.coge/operation.lock');
  if(present){
    try { lock=await open(lockPath,'wx',0o600); }
    catch(error){
      if(error.code!=='EEXIST')throw error;
      const raw=await readFile(lockPath,'utf8'),prior=JSON.parse(raw);
      if(!Number.isInteger(prior.pid)||prior.pid<=0)throw Error('The ERP operation lock needs checking.');
      try { process.kill(prior.pid,0); throw Error('Another ERP operation is still active.'); }
      catch(problem){if(problem.code!=='ESRCH')throw problem;}
      if(await readFile(lockPath,'utf8')!==raw)throw Error('The ERP operation changed.');
      await unlink(lockPath);lock=await open(lockPath,'wx',0o600);
    }
    await lock.writeFile(JSON.stringify({pid:process.pid,operation:'remove_erp'}));
  }
  try {
    if(await run(['info','--format','{{.OSType}}'])!=='linux')throw Error('The ERP runtime is unavailable.');
    const key='coge-'+engine+'-'+sha(project.id).slice(0,20),rootDigest=sha(root),resources=[];
    for(const kind of ['container','volume','network']){
      const ids=(await run([kind,'ls',...(kind==='container'?['-a']:[]),'-q','--filter',`label=com.cogentspec.${engine}.project=`+project.id])).split(/\s+/).filter(Boolean);
      for(const id of ids){
        const data=JSON.parse(await run([kind,'inspect',id]))[0],labels=data.Labels||data.Config?.Labels||{};
        const name=String(data.Name||'').replace(/^\//,'');
        if(labels[`com.cogentspec.${engine}.project`]!==project.id || labels[`com.cogentspec.${engine}.root`]!==rootDigest
          || !(name===key||name.startsWith(key+'-'))) throw Error('A runtime resource has a different project identity. Nothing was removed.');
        resources.push({kind,id:kind==='volume'?name:data.Id,name,data});
      }
    }
    // Refuse shared volumes/networks before removing any resource.
    const all=(await run(['container','ls','-a','-q'])).split(/\s+/).filter(Boolean);
    const ours=new Set(resources.filter(r=>r.kind==='container').map(r=>r.id));
    for(let i=0;i<all.length;i+=100){
      for(const data of JSON.parse(await run(['container','inspect',...all.slice(i,i+100)]))){
        if(ours.has(data.Id))continue;
        if(resources.some(r=>r.kind==='volume'&&(data.Mounts||[]).some(m=>m.Name===r.name)
          ||r.kind==='network'&&Object.values(data.NetworkSettings?.Networks||{}).some(n=>n.NetworkID===r.id))) throw Error('An ERP resource is shared with another container. Nothing was removed.');
      }
    }
    const imageIds=await removalImages({run,project,engine,root,present,resources});
    const removed={containers:0,volumes:0,networks:0,images:0};
    for(const resource of resources){
      const current=JSON.parse(await run([resource.kind,'inspect',resource.id]))[0],labels=current.Labels||current.Config?.Labels||{};
      if(labels[`com.cogentspec.${engine}.project`]!==project.id||labels[`com.cogentspec.${engine}.root`]!==rootDigest
        ||resource.kind==='volume'&&current.CreatedAt!==resource.data.CreatedAt)throw Error('An ERP resource changed during removal.');
      await run([resource.kind,'rm',...(resource.kind==='container'?['-f']:[]),resource.id]);
      removed[resource.kind==='container'?'containers':resource.kind==='volume'?'volumes':'networks']++;
    }
    for(const kind of ['container','volume','network']) if(await run([kind,'ls',...(kind==='container'?['-a']:[]),'-q','--filter',`label=com.cogentspec.${engine}.project=`+project.id]))throw Error('Some ERP resources remain.');
    const images=await removeImages(imageIds,run,project,engine);removed.images=images.removed;
    return {protocol:1,projectId:project.id,runtimeId:project.contractRuntimeId,packId:project.packId,packVersion:project.packVersion,
      targetPath:project.targetPath,canonicalRoot:root,resourcesRemoved:true,removed,retainedImages:images.retained};
  } finally { if(lock){await lock.close();await unlink(lockPath);} }
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try { let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>16384)throw Error('Invalid deletion plan.');}
    const value=JSON.parse(input);console.log(JSON.stringify(await removeErpResources(value.project,{previousProof:value.previousProof}))); }
  catch { console.error('ERP removal could not be verified. Its folder and registration were kept for retry.');process.exitCode=1; }
}
