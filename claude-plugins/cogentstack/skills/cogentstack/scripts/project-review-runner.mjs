import {mkdtemp,mkdir,writeFile,readFile,rm,lstat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {collectProjectPreview} from './project-preview-build.mjs';
import {fingerprintProjectSource} from './project-source-fingerprint.mjs';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const relativePath=url=>{const u=new URL(url);return u.pathname+u.search+u.hash;};
const safePath=value=>typeof value==='string'&&value.startsWith('/')&&!value.startsWith('//')&&!/[\\%\0]/.test(value)&&!value.split('/').some(part=>part==='.'||part==='..');
// Navigation must be exercised from its real entry point. Directly loading the
// destination does not establish that the link works. Only the isolated build
// is opened; no customer browser, cookies or records are reused.
async function auditNavigation(browser,origin,viewport,storageState,entries,signal){
 const navigation=[];let complete=entries.length<=40;
 for(const entry of entries.slice(0,40)){
  signal?.throwIfAborted();const context=await browser.newContext({viewport,storageState,serviceWorkers:'block',acceptDownloads:false}),page=await context.newPage();page.setDefaultTimeout(6000);
  let errors=0,blocked=0,result='passed',arrivedPath;
  context.on('page',p=>p.on('pageerror',()=>errors++));
  page.on('pageerror',()=>errors++);
  await context.route('**/*',route=>{if(new URL(route.request().url()).origin!==origin){blocked++;void route.abort();}else void route.continue();});
  try{
   const response=await page.goto(origin+entry.fromPath,{waitUntil:'networkidle'});if(!response||response.status()>=400)throw Error();
   const beforeText=await page.locator('body').innerText();
   const link=page.locator('a').nth(entry.index),href=await link.getAttribute('href');
   if(href!==entry.href||!await link.isVisible())throw Error();
   const popup=page.waitForEvent('popup',{timeout:1000}).catch(()=>null);
   await link.click();const destination=await popup||page;
   await destination.waitForURL(url=>url.origin===origin&&relativePath(url.href)===entry.targetPath,{timeout:6000});
   await destination.waitForLoadState('networkidle');arrivedPath=relativePath(destination.url());
   const content=await destination.locator('body').innerText();if(!content.trim()||errors)throw Error();
   if(blocked||content===beforeText)result='blocked'; // URL changes alone do not establish that the destination rendered.
  }catch{result='failed';}
  navigation.push({label:entry.label,fromPath:entry.fromPath,targetPath:entry.targetPath,...(arrivedPath?{arrivedPath}:{}),result,uncaughtErrorCount:Math.min(errors,1000)});
  await context.close();
 }
 return {navigation,complete};
}
const cleanupReviewRoot=async root=>{if(!root.startsWith(path.join(tmpdir(),'coge-polish-run-')))throw Error('Invalid test cleanup path.');await rm(root,{recursive:true,force:true,maxRetries:10,retryDelay:150});};
const stopProcess=async child=>{
 if(!child||child.exitCode!==null||child.signalCode!==null)return;
 if(child.connected){child.send({action:'stop'});await new Promise(done=>{const timer=setTimeout(done,3000);child.once('exit',()=>{clearTimeout(timer);done();});});if(child.exitCode!==null||child.signalCode!==null)return;}
 if(process.platform==='win32'){const killer=spawn('taskkill.exe',['/PID',String(child.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});await new Promise((done,reject)=>{killer.once('exit',done);killer.once('error',reject);});}
 else{try{process.kill(-child.pid,'SIGTERM');}catch{child.kill('SIGTERM');}}
 await new Promise(done=>{if(child.exitCode!==null||child.signalCode!==null)return done();const timer=setTimeout(done,5000);child.once('exit',()=>{clearTimeout(timer);done();});});
 if(child.exitCode===null&&child.signalCode===null){if(process.platform!=='win32')try{process.kill(-child.pid,'SIGKILL');}catch{child.kill('SIGKILL');}throw Error('The isolated test process did not stop.');}
};
export async function runProjectReview(input,{signal,executablePath}={}){
 if(!/^[a-f0-9-]{36}$/.test(input.id)||!path.isAbsolute(input.targetPath||'')||!path.isAbsolute(input.runtimeRoot||''))throw Error('identity_mismatch');
 signal?.throwIfAborted();
 const projectRoot=path.resolve(input.targetPath),manifest=JSON.parse(await readFile(path.join(projectRoot,'.coge','knowledge-manifest.json'),'utf8'));
 if(manifest.project?.requestId!==input.projectId)throw Error('identity_mismatch');
 const binding=JSON.parse(await readFile(path.join(projectRoot,'.coge','contract-binding.json'),'utf8'));
 for(const key of ['contractChecksum','taskBlueprintChecksum','packId','packVersion'])if(typeof input[key]!=='string'||binding[key]!==input[key])throw Error('identity_mismatch');
 const before=await fingerprintProjectSource(projectRoot),packed=await collectProjectPreview({targetPath:projectRoot,projectId:input.projectId,runtimeId:input.runtimeId});
 const require=createRequire(path.join(input.runtimeRoot,'package.json'));let chromium;try{const installed=await import(pathToFileURL(require.resolve('playwright')).href);chromium=installed.chromium??installed.default?.chromium;if(!chromium)throw Error();}catch{throw Error('browser_setup_required');}
 const root=await mkdtemp(path.join(tmpdir(),'coge-polish-run-'));let host,browser,origin;const observations=[],artifacts=[],remembered=new Map();
 const abort=()=>{void browser?.close().catch(()=>{});void stopProcess(host).catch(()=>{});};signal?.addEventListener('abort',abort,{once:true});
 try{
  for(const file of packed.files){const target=path.resolve(root,'bundle',file.path);if(!target.startsWith(path.join(root,'bundle')+path.sep))throw Error('unsafe_build');await mkdir(path.dirname(target),{recursive:true});await writeFile(target,Buffer.from(file.content,'base64'));}
  const environment={PATH:process.env.PATH||process.env.Path||'',SystemRoot:process.env.SystemRoot||'',TEMP:root,TMP:root,HOME:root,USERPROFILE:root,NODE_ENV:'test',NO_PROXY:'*'};
  host=spawn(process.execPath,[fileURLToPath(new URL('project-review-host.mjs',import.meta.url))],{cwd:root,windowsHide:true,detached:process.platform!=='win32',env:environment,stdio:['pipe','pipe','pipe','ipc']});
  host.stderr.on('data',()=>{});host.stdin.end(JSON.stringify({root,kind:packed.kind,runtimeRoot:input.runtimeRoot}));
  origin=await new Promise((resolve,reject)=>{let stdout='';const timer=setTimeout(()=>reject(Error('test_instance_unavailable')),30000);host.once('exit',()=>{clearTimeout(timer);reject(Error('test_instance_unavailable'));});host.stdout.on('data',chunk=>{stdout+=chunk;if(stdout.length>4096){clearTimeout(timer);reject(Error('test_instance_unavailable'));return;}if(stdout.includes('\n'))try{const ready=JSON.parse(stdout.trim());if(!ready.ready||!/^http:\/\/127\.0\.0\.1:\d+$/.test(ready.origin))throw Error();clearTimeout(timer);resolve(ready.origin);}catch{clearTimeout(timer);reject(Error('test_instance_unavailable'));}});});
  signal?.throwIfAborted();try{browser=await chromium.launch({headless:true,...(executablePath?{executablePath}:process.platform==='win32'?{channel:'chrome'}:{})});}catch{try{browser=await chromium.launch({headless:true});}catch{throw Error('browser_setup_required');}}
  for(const [index,journey]of input.plan.journeys.entries()){
   signal?.throwIfAborted();const zoom=journey.viewport==='zoom',viewport=journey.viewport==='narrow'?{width:390,height:844}:zoom?{width:640,height:450}:{width:1280,height:900};
   const context=await browser.newContext({viewport,serviceWorkers:'block',acceptDownloads:false}),page=await context.newPage();page.setDefaultTimeout(6000);
   let blocked=0,errors=0,stepsCompleted=0,outcomeChecks=0,result='passed',message='The requested journey completed. Visual inspection of the screenshot is still required.';const controls=[],interactions=[],entries=new Map(),unmetBefore=new Set();let navigation=[],navigationComplete=false;
   page.on('pageerror',()=>errors++);
   await context.route('**/*',route=>{let url;try{url=new URL(route.request().url());}catch{void route.abort();return;}if(url.origin!==origin){blocked++;void route.abort();}else void route.continue();});
   context.on('page',popup=>{if(popup!==page)void popup.close();});
   const target=value=>page.getByRole(value.role,{name:value.name,exact:true});
   const assertions=['expect_text','expect_path','expect_visible','expect_changed','expect_restored'];
   const condition=async step=>{
    if(step.action==='expect_text')return await page.getByText(step.text,{exact:true}).isVisible()===(step.visible!==false);
    if(step.action==='expect_path')return relativePath(page.url())===step.path;
    if(step.action==='expect_visible')return await target(step.target).isVisible()===(step.visible!==false);
    const value=await target(step.target).textContent(),old=remembered.get(journey.id+':'+step.key);
    return old!==undefined&&(step.action==='expect_changed'?value!==old:value===old);
   };
   const collectLinks=async()=>{
    const fromPath=relativePath(page.url());
    const links=await page.locator('a').evaluateAll(elements=>elements.map((a,index)=>{
     const copy=a.cloneNode(true);copy.querySelectorAll('[aria-hidden="true"]').forEach(e=>e.remove());
     const labelled=a.getAttribute('aria-labelledby')?.split(/\s+/).map(id=>document.getElementById(id)?.textContent||'').join(' ');
     return {index,href:a.getAttribute('href'),download:a.hasAttribute('download'),label:(a.getAttribute('aria-label')||labelled||copy.textContent||a.querySelector('img')?.alt||'').replace(/\s+/g,' ').trim(),visible:Boolean(a.getClientRects().length)};
    }));
    for(const link of links){
     if(!link.visible||link.download||!link.href||link.href.startsWith('#'))continue;
     let url;try{url=new URL(link.href,page.url());}catch{continue;}
     if(url.origin!==origin||url.pathname===new URL(page.url()).pathname&&url.search===new URL(page.url()).search||!safePath(relativePath(url.href)))continue;
     entries.set(fromPath+':'+link.index,{...link,label:link.label.slice(0,120)||'Unnamed navigation link',fromPath,targetPath:relativePath(url.href)});
    }
   };
   try{
    if(!safePath(journey.path))throw Error('invalid_test_path');
    const response=await page.goto(origin+journey.path,{waitUntil:'domcontentloaded'});if(!response||response.status()>=400)throw Error('test_page_unavailable');
    await page.waitForLoadState('networkidle');await collectLinks();
    for(const [stepIndex,step]of journey.steps.entries()){signal?.throwIfAborted();
     if(['click','fill','check','select','press'].includes(step.action))interactions.push({stepIndex,action:step.action,...(step.target?{target:step.target}:{}),verified:false});
     if(['click','press'].includes(step.action)){const outcome=journey.steps.slice(stepIndex+1).find(s=>assertions.includes(s.action));if(outcome&&await condition(outcome)===false)unmetBefore.add(stepIndex);}
     if(step.action==='click')await target(step.target).click();
     else if(step.action==='fill'){await target(step.target).fill(step.value);if(await target(step.target).inputValue()!==step.value)throw Error();interactions.at(-1).verified=true;}
     else if(step.action==='check'){await target(step.target).setChecked(step.checked);if(await target(step.target).isChecked()!==step.checked)throw Error();interactions.at(-1).verified=true;}
     else if(step.action==='select'){await target(step.target).selectOption(step.value);if(await target(step.target).inputValue()!==step.value)throw Error();interactions.at(-1).verified=true;}
     else if(step.action==='press'){if(!['Tab','Shift+Tab','Enter','Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(step.key))throw Error();const active=await page.evaluateHandle(()=>document.activeElement);await page.keyboard.press(step.key);if(['Tab','Shift+Tab'].includes(step.key)&&await active.evaluate(e=>e!==document.activeElement))interactions.at(-1).verified=true;await active.dispose();}
     else if(step.action==='expect_text'){const node=page.getByText(step.text,{exact:true});if(step.visible!==false)await node.waitFor({state:'visible'});else await node.waitFor({state:'hidden'});}
     else if(step.action==='expect_path')await page.waitForURL(url=>url.origin===origin&&relativePath(url.href)===step.path);
     else if(step.action==='expect_visible')await target(step.target).waitFor({state:step.visible===false?'hidden':'visible'});
     else if(step.action==='remember_text')remembered.set(journey.id+':'+step.key,await target(step.target).textContent());
     else if(['expect_changed','expect_restored'].includes(step.action)){const old=remembered.get(journey.id+':'+step.key);if(old===undefined)throw Error();const deadline=Date.now()+6000;let matched=false;while(Date.now()<deadline){signal?.throwIfAborted();const value=await target(step.target).textContent();if(step.action==='expect_changed'?value!==old:value===old){matched=true;break;}await new Promise(done=>setTimeout(done,100));}if(!matched)throw Error('control_did_not_change');}
     else throw Error('unsupported_test_step');
     if(assertions.includes(step.action)){outcomeChecks++;const pending=interactions.findLast(i=>!i.verified);if(pending&&unmetBefore.has(pending.stepIndex)){pending.verified=true;pending.outcomeStep=stepIndex;}}
     stepsCompleted++;await collectLinks();
    }
    for(const control of journey.controls){const node=target(control.target);for(const state of ['normal','hover','keyboard_focus']){
      signal?.throwIfAborted();if(state==='normal')await page.mouse.move(0,0);if(state==='hover')await node.hover();if(state==='keyboard_focus')await node.focus();
      const sample=await node.evaluate(element=>{const style=getComputedStyle(element);let background='',known=true;for(let parent=element;parent;parent=parent.parentElement){const s=getComputedStyle(parent);if(s.backgroundImage!=='none'||Number(s.opacity)!==1||s.filter!=='none'||s.mixBlendMode!=='normal')known=false;if(!background&&!['rgba(0, 0, 0, 0)','transparent'].includes(s.backgroundColor))background=s.backgroundColor;}return{foreground:style.color,background:background||'rgb(255, 255, 255)',contrastKnown:known&&/^rgb\(/.test(style.color)&&(!background||/^rgb\(/.test(background))};});controls.push({id:control.id,state,visible:await node.isVisible(),...sample});
    }}
    const audited=await auditNavigation(browser,origin,viewport,await context.storageState(),[...entries.values()],signal);navigation=audited.navigation;navigationComplete=audited.complete;
    if(errors||navigation.some(n=>n.result==='failed')){result='failed';message='An application error or broken page-navigation link was detected. The journey cannot pass.';}
    else if(interactions.some(i=>!i.verified)){result='blocked';message='An action has no recorded outcome check. Add an assertion that verifies what the control actually did.';}
    else if(blocked||!navigationComplete||navigation.some(n=>n.result==='blocked')){result='blocked';message='Some navigation or external resources could not be checked. Their behaviour has not been verified.';}
    if(zoom&&result==='passed'){result='blocked';message='This capture checks reflow at an equivalent narrow layout. Native 200% browser zoom still needs a controlled check.';}
   }catch(error){signal?.throwIfAborted();result=error.message==='test_page_unavailable'?'blocked':'failed';message='The declared journey did not finish. Inspect the screenshot and the last completed step; no application correction is confirmed.';}
   const id='capture-'+index;let png=await page.screenshot({type:'png',scale:'css'}).catch(()=>null),captureCoverage='viewport',artifact='not-captured';
   if(png?.length>512000){try{const sharp=(await import(pathToFileURL(require.resolve('sharp')).href)).default;png=await sharp(png).png({compressionLevel:9}).toBuffer();}catch{/* Preserve the original capture if optional lossless compression is unavailable. */}}
   if(png?.length>512000){captureCoverage='top_region';png=await page.screenshot({type:'png',scale:'css',clip:{x:0,y:0,width:viewport.width,height:Math.min(240,viewport.height)}}).catch(()=>null);message+=' The bounded screenshot shows only the top region; it does not establish full-page visual coverage.';}
   if(png&&png.length<=512000){artifact='.coge-review-evidence/'+input.id+'/'+id+'.png';artifacts.push({id,path:artifact,sha256:sha(png),png:png.toString('base64')});}else{if(result==='passed')result='blocked';message+=' A bounded review screenshot could not be captured.';}
   observations.push({journey:journey.id,mode:journey.viewport,path:journey.path,result,message,artifact,captureCoverage,stepsCompleted,uncaughtErrorCount:Math.min(errors,1000),outcomeChecks,navigationComplete,navigation,interactions,zoomMethod:zoom?'layout_equivalent':'not_tested',controls});await context.close();
  }
  signal?.throwIfAborted();const after=await fingerprintProjectSource(projectRoot);if(before.sourceDigest!==after.sourceDigest)throw Error('source_changed');
  const evidenceRoot=path.join(projectRoot,'.coge-review-evidence');try{if((await lstat(evidenceRoot)).isSymbolicLink())throw Error('unsafe_evidence_path');}catch(error){if(error.code!=='ENOENT')throw error;}
  const output=path.join(evidenceRoot,input.id);await mkdir(output,{recursive:true});for(const artifact of artifacts)await writeFile(path.join(output,artifact.id+'.png'),Buffer.from(artifact.png,'base64'));
  return {protocol:1,checksVersion:2,target:'local_build',sourceProtocol:before.protocol,sourceDigest:before.sourceDigest,buildDigest:packed.buildDigest,isolatedData:true,headless:true,result:observations.some(o=>o.result==='failed')?'failed':observations.some(o=>o.result==='blocked')?'blocked':'passed',observations,artifacts};
 }finally{signal?.removeEventListener('abort',abort);await browser?.close();await stopProcess(host);await cleanupReviewRoot(root);}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 let raw='';for await(const chunk of process.stdin){raw+=chunk;if(raw.length>200000)throw Error('Review plan too large.');}
 try{const input=JSON.parse(raw),controller=new AbortController();const timer=setTimeout(()=>controller.abort(),8*60*1000);const stop=()=>controller.abort();process.on('SIGTERM',stop);const check=setInterval(()=>{if(input.cancelFile)void lstat(input.cancelFile).then(stop).catch(()=>{});},500);try{const result=await runProjectReview(input,{signal:controller.signal});process.stdout.write(JSON.stringify({result}));}finally{clearTimeout(timer);clearInterval(check);process.removeListener('SIGTERM',stop);}}
 catch(error){process.stdout.write(JSON.stringify({failure:['browser_setup_required','identity_mismatch','build_missing','source_changed'].includes(error.message)?error.message:'background_checks_failed'}));process.exitCode=1;}
}
