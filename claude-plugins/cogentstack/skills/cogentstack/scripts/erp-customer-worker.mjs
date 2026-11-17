import {readFile,lstat} from 'node:fs/promises';
import {resolve,basename} from 'node:path';
import {createHash} from 'node:crypto';
import {prepareLayerEnvironment,cancelPreparedLayerEnvironment,initializeCustomerLayer,buildCustomerRelease,verifyCustomerRelease,deployCustomerRelease,rollbackCustomerRelease} from './erp-customer-runtime.mjs';
let raw='';for await(const chunk of process.stdin){raw+=chunk;if(raw.length>8192)throw Error('Invalid computer authorisation.');}
let credential=JSON.parse(raw);raw='';
const api=async body=>{const response=await fetch('https://cogentspec.com/api/plugin/erp-customer-releases',{method:'POST',redirect:'error',headers:{authorization:'Bearer '+credential.token,'content-type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(30000)});if(!response.ok)throw Error('Customer release authorisation is unavailable.');return response.json();};
async function localLease(){
 const root=resolve(process.env.LOCALAPPDATA||'', 'CogentSpec/bridge-manager/v1'),current=JSON.parse(await readFile(resolve(root,'current.json'),'utf8'));
 if(!/^[a-f0-9]{24}$/.test(current.version)||basename(import.meta.dirname)!==current.version)throw Error('The customer build helper package changed.');
 try{await lstat(resolve(root,'paused'));throw Error('The computer helper is paused.');}catch(error){if(error.code!=='ENOENT')throw error;}
 for(const name of ['erp-customer-worker.mjs','erp-customer-runtime.mjs'])if(createHash('sha256').update(await readFile(resolve(import.meta.dirname,name))).digest('hex')!==current.hashes[name])throw Error('The customer build helper package changed.');
}
let job,timer,failed=false,cancellation,heartbeat;
const cancelRequested=()=>{if(!cancellation.signal.aborted)cancellation.abort(Object.assign(Error('Layer setup was cancelled.'),{code:'layer_setup_cancelled'}));};
async function finishCancellation(error){
 const proof=error?.cancellationProof??await cancelPreparedLayerEnvironment(job.project,job.work,{operationId:job.id});
 await api({action:'cancelled',id:job.id,claim:job.claim,proof});console.log(JSON.stringify({status:'layer_setup_cancelled',id:job.id}));
}
try{
 await localLease();job=(await api({action:'claim',protocol:6})).job;
 if(job){
  cancellation=new AbortController();
  heartbeat=async phase=>{await localLease();if(failed)throw Error('The customer release lease was lost.');const result=await api({action:'heartbeat',id:job.id,claim:job.claim,...(phase?{phase}:{})});if(job.kind==='environment'&&result.cancelRequested)cancelRequested();};
  const checkCancelled=async()=>{await heartbeat();cancellation.signal.throwIfAborted();};
  timer=setInterval(()=>heartbeat().catch(()=>{failed=true;}),job.kind==='environment'?5000:30000);
  let proof;
  if(job.kind==='environment')proof=await prepareLayerEnvironment(job.project,job.work,{id:job.id,onProgress:heartbeat,signal:cancellation.signal,checkCancelled});
  else if(job.kind==='initialize')proof=await initializeCustomerLayer(job.project,job.work);
  else if(job.kind==='build'||job.kind==='refresh'&&job.state==='building'){
   await buildCustomerRelease(job.project,job.work,{id:job.id,version:job.version,revision:job.revision,workRevision:job.work_revision});await heartbeat();
   proof=await verifyCustomerRelease(job.project,job.work,job.id);
  }else if(job.kind==='deploy'||job.kind==='refresh'&&job.state==='deploying')proof=await deployCustomerRelease(job.project,job.work,job,heartbeat);
  else if(job.kind==='rollback')proof=await rollbackCustomerRelease(job.project,job.work,job,heartbeat);
  else throw Error('Unsupported customer release work.');
  await heartbeat();cancellation.signal.throwIfAborted();
  const result=await api({action:'complete',id:job.id,claim:job.claim,proof});if(job.kind==='environment'&&result.cancelRequested){cancelRequested();throw cancellation.signal.reason;}
  console.log(JSON.stringify({status:'customer_release_reported',id:job.id}));
 }
}catch(error){
 let cancelled=false;
 try{
  if(job?.kind==='environment'&&(error.code==='layer_setup_cancelled'||cancellation?.signal.aborted)){await finishCancellation(error);cancelled=true;}
  else if(job){const result=await api({action:'fail',id:job.id,claim:job.claim,failureCode:error.code==='rollback_data_changed'?'rollback_data_changed':job.kind==='environment'&&error.layerPreparationRetryable===true?'layer_setup_retryable':null});if(job.kind==='environment'&&result.cancelRequested){await finishCancellation();cancelled=true;}}
 }catch{if(job?.kind==='environment')await api({action:'fail',id:job.id,claim:job.claim,failureCode:'layer_cancel_unverified'}).catch(()=>{});}
 if(!cancelled){console.error('Customer release work did not complete. Inspect its private local operation journal.');process.exitCode=1;}
}finally{clearInterval(timer);credential=null;}
