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
   let blocked=0,stepsCompleted=0,result='passed',message='The requested journey completed. Visual inspection of the screenshot is still required.';const controls=[];
   await context.route('**/*',route=>{let url;try{url=new URL(route.request().url());}catch{void route.abort();return;}if(url.origin!==origin){blocked++;void route.abort();}else void route.continue();});
   context.on('page',popup=>{if(popup!==page)void popup.close();});
   const target=value=>page.getByRole(value.role,{name:value.name,exact:true});
   try{
    if(typeof journey.path!=='string'||!journey.path.startsWith('/')||journey.path.startsWith('//')||/[\\%\0]/.test(journey.path)||journey.path.split('/').some(part=>part==='.'||part==='..'))throw Error('invalid_test_path');
    const response=await page.goto(origin+journey.path,{waitUntil:'domcontentloaded'});if(!response||response.status()>=400)throw Error('test_page_unavailable');
    for(const step of journey.steps){signal?.throwIfAborted();
     if(step.action==='click')await target(step.target).click();
     else if(step.action==='fill')await target(step.target).fill(step.value);
     else if(step.action==='check')await target(step.target).setChecked(step.checked);
     else if(step.action==='select')await target(step.target).selectOption(step.value);
     else if(step.action==='press'){if(!['Tab','Shift+Tab','Enter','Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(step.key))throw Error();await page.keyboard.press(step.key);}
     else if(step.action==='expect_text'){const node=page.getByText(step.text,{exact:true});if(step.visible!==false)await node.waitFor({state:'visible'});else await node.waitFor({state:'hidden'});}
     else if(step.action==='remember_text')remembered.set(journey.id+':'+step.key,await target(step.target).textContent());
     else if(['expect_changed','expect_restored'].includes(step.action)){const old=remembered.get(journey.id+':'+step.key);if(old===undefined)throw Error();const deadline=Date.now()+6000;let matched=false;while(Date.now()<deadline){signal?.throwIfAborted();const value=await target(step.target).textContent();if(step.action==='expect_changed'?value!==old:value===old){matched=true;break;}await new Promise(done=>setTimeout(done,100));}if(!matched)throw Error('control_did_not_change');}
     else throw Error('unsupported_test_step');stepsCompleted++;
    }
    for(const control of journey.controls){const node=target(control.target);for(const state of ['normal','hover','keyboard_focus']){
      signal?.throwIfAborted();if(state==='normal')await page.mouse.move(0,0);if(state==='hover')await node.hover();if(state==='keyboard_focus')await node.focus();
      const sample=await node.evaluate(element=>{const style=getComputedStyle(element);let background='',known=true;for(let parent=element;parent;parent=parent.parentElement){const s=getComputedStyle(parent);if(s.backgroundImage!=='none'||Number(s.opacity)!==1||s.filter!=='none'||s.mixBlendMode!=='normal')known=false;if(!background&&!['rgba(0, 0, 0, 0)','transparent'].includes(s.backgroundColor))background=s.backgroundColor;}return{foreground:style.color,background:background||'rgb(255, 255, 255)',contrastKnown:known&&/^rgb\(/.test(style.color)&&(!background||/^rgb\(/.test(background))};});controls.push({id:control.id,state,visible:await node.isVisible(),...sample});
    }}
    if(blocked){result='blocked';message='External resources were blocked in the isolated test. Their behaviour has not been verified.';}
    if(zoom){result='blocked';message='This capture checks reflow at an equivalent narrow layout. Native 200% browser zoom still needs a controlled check.';}
   }catch(error){signal?.throwIfAborted();result=error.message==='test_page_unavailable'?'blocked':'failed';message='The declared journey did not finish. Inspect the screenshot and the last completed step; no application correction is confirmed.';}
   const id='capture-'+index,png=await page.screenshot({type:'png',scale:'css'}).catch(()=>null);let artifact='not-captured';
   if(png&&png.length<=512000){artifact='.coge-review-evidence/'+input.id+'/'+id+'.png';artifacts.push({id,path:artifact,sha256:sha(png),png:png.toString('base64')});}else{result='blocked';message='A bounded review screenshot could not be captured.';}
   observations.push({journey:journey.id,mode:journey.viewport,result,message,artifact,stepsCompleted,zoomMethod:zoom?'layout_equivalent':'not_tested',controls});await context.close();
  }
  signal?.throwIfAborted();const after=await fingerprintProjectSource(projectRoot);if(before.sourceDigest!==after.sourceDigest)throw Error('source_changed');
  const evidenceRoot=path.join(projectRoot,'.coge-review-evidence');try{if((await lstat(evidenceRoot)).isSymbolicLink())throw Error('unsafe_evidence_path');}catch(error){if(error.code!=='ENOENT')throw error;}
  const output=path.join(evidenceRoot,input.id);await mkdir(output,{recursive:true});for(const artifact of artifacts)await writeFile(path.join(output,artifact.id+'.png'),Buffer.from(artifact.png,'base64'));
  return {protocol:1,sourceProtocol:before.protocol,sourceDigest:before.sourceDigest,buildDigest:packed.buildDigest,isolatedData:true,headless:true,result:observations.some(o=>o.result==='failed')?'failed':observations.some(o=>o.result==='blocked')?'blocked':'passed',observations,artifacts};
 }finally{signal?.removeEventListener('abort',abort);await browser?.close();await stopProcess(host);await cleanupReviewRoot(root);}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 let raw='';for await(const chunk of process.stdin){raw+=chunk;if(raw.length>200000)throw Error('Review plan too large.');}
 try{const input=JSON.parse(raw),controller=new AbortController();const timer=setTimeout(()=>controller.abort(),8*60*1000);const stop=()=>controller.abort();process.on('SIGTERM',stop);const check=setInterval(()=>{if(input.cancelFile)void lstat(input.cancelFile).then(stop).catch(()=>{});},500);try{const result=await runProjectReview(input,{signal:controller.signal});process.stdout.write(JSON.stringify({result}));}finally{clearTimeout(timer);clearInterval(check);process.removeListener('SIGTERM',stop);}}
 catch(error){process.stdout.write(JSON.stringify({failure:['browser_setup_required','identity_mismatch','build_missing','source_changed'].includes(error.message)?error.message:'background_checks_failed'}));process.exitCode=1;}
}
