import {mkdir,lstat,readFile,open,rename,unlink} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {homedir} from 'node:os';
import {createHash,randomInt} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';

// Never allocate the legacy 3000-3099 origins. Keep every reservation, including
// deleted installations, because browser storage outlives the ERP directory.
export const erpAddressRange={first:10000,last:59999};
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
export const erpAddressStore=()=>resolve(process.env.LOCALAPPDATA||resolve(homedir(),'.local/share'),'CogentSpec','erp-installation-addresses.json');
function identity(project){
 if(!uuid(project.id)||!uuid(project.contractRuntimeId)||typeof project.targetPath!=='string')throw Error('Invalid ERP address identity.');
 const root=resolve(project.targetPath);return {projectId:project.id,runtimeId:project.contractRuntimeId,rootDigest:createHash('sha256').update(process.platform==='win32'?root.toLowerCase():root).digest('hex')};
}
async function regular(path){try{if(!(await lstat(path)).isFile())throw Error('The ERP address record is not a regular file.');return true;}catch(error){if(error.code==='ENOENT')return false;throw error;}}
async function read(store){
 if(!await regular(store)){
  if(await regular(store+'.established'))throw Error('The saved ERP addresses are missing. Restore the address record before reconnecting; old addresses must not be reused.');
  return {protocol:1,assignments:[]};
 }
 let data;try{data=JSON.parse(await readFile(store,'utf8'));}catch{throw Error('The saved ERP addresses need repair; no replacement address was assigned.');}
 if(data.protocol!==1||!Array.isArray(data.assignments)||data.assignments.length>50000)throw Error('Invalid ERP address record.');
 const projects=new Set(),ports=new Set();
 for(const row of data.assignments){
  if(!uuid(row.projectId)||!uuid(row.runtimeId)||! /^[a-f0-9]{64}$/.test(row.rootDigest)||!Number.isInteger(row.port)||row.port<erpAddressRange.first||row.port>erpAddressRange.last||projects.has(row.projectId)||ports.has(row.port))throw Error('Conflicting ERP address reservations; no address was reused.');
  projects.add(row.projectId);ports.add(row.port);
 }
 return data;
}
function match(project,data){const wanted=identity(project),row=data.assignments.find(row=>row.projectId===wanted.projectId);
 if(row&&(row.runtimeId!==wanted.runtimeId||row.rootDigest!==wanted.rootDigest))throw Error('This ERP address belongs to a different runtime or installation folder.');
 return row?{...row,url:`http://127.0.0.1:${row.port}/`}:null;
}
export async function readErpAddress(project,{store=erpAddressStore()}={}){return match(project,await read(store));}
async function write(store,data){
 const temporary=store+'.'+process.pid+'.'+randomInt(1e9)+'.tmp';
 const file=await open(temporary,'wx',0o600);
 try{await file.writeFile(JSON.stringify(data,null,2)+'\n');await file.sync();}finally{await file.close();}
 try{await rename(temporary,store);}catch(error){await unlink(temporary).catch(()=>{});throw error;}
}
async function bind(server,port){await new Promise((done,fail)=>{const error=value=>{server.removeListener('listening',ready);fail(value);};const ready=()=>{server.removeListener('error',error);done();};server.once('error',error);server.once('listening',ready);server.listen(port,'127.0.0.1');});}
export async function bindErpAddress(project,server,{store=erpAddressStore(),choose=()=>randomInt(erpAddressRange.first,erpAddressRange.last+1)}={}){
 await mkdir(dirname(store),{recursive:true});if((await lstat(dirname(store))).isSymbolicLink())throw Error('Linked ERP address storage is not supported.');
 let lock;for(let attempt=0;!lock;attempt++){try{lock=await open(store+'.lock','wx',0o600);}catch(error){if(error.code!=='EEXIST'||attempt>=100)throw Error('ERP address allocation is busy. Retry without changing the saved address.');await delay(50);}}
 try{
  const data=await read(store),existing=match(project,data);
  if(existing){try{await bind(server,existing.port);}catch{throw Error('This installation’s saved ERP address is occupied. Close its conflicting listener and reconnect; the address has been preserved.');}return existing;}
  const used=new Set(data.assignments.map(row=>row.port)),start=choose();
  if(!Number.isInteger(start)||start<erpAddressRange.first||start>erpAddressRange.last)throw Error('Invalid ERP address allocation.');
  for(let offset=0;offset<=erpAddressRange.last-erpAddressRange.first;offset++){
   const port=erpAddressRange.first+(start-erpAddressRange.first+offset)%(erpAddressRange.last-erpAddressRange.first+1);if(used.has(port))continue;
   try{await bind(server,port);}catch(error){if(['EADDRINUSE','EACCES','EPERM'].includes(error.code))continue;throw error;}
   const row={...identity(project),port,assignedAt:new Date().toISOString()};data.assignments.push(row);
   try{await write(store,data);const marker=await open(store+'.established','a',0o600);await marker.close();}catch(error){server.close();throw error;}
   return {...row,url:`http://127.0.0.1:${port}/`};
  }
  throw Error('No unused ERP address is available. Existing and deleted installation addresses have been preserved.');
 }finally{await lock.close();await unlink(store+'.lock');}
}
