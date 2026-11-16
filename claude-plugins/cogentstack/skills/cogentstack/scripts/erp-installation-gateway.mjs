import {createServer,request as httpRequest} from 'node:http';
import {connect} from 'node:net';
import {readFile,mkdir,writeFile,open,unlink,lstat,realpath,rename} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash,randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {execute} from './erp-customer-runtime.mjs';
import {bindErpAddress,readErpAddress} from './erp-installation-address.mjs';

export async function erpGatewaySourceDigest(){const hash=createHash('sha256');for(const name of ['erp-installation-address.mjs','erp-installation-gateway.mjs'])hash.update(name+'\0').update((await readFile(new URL(name,import.meta.url),'utf8')).replaceAll('\r\n','\n'));return hash.digest('hex');}

// The public address belongs to the installation, not the foundation image or
// Docker's temporary frontend socket. Reuse the pinned native session/owner
// adapters; never modify application source or copy another site's settings.
export function createErpAddressGateway({plan,inspect,connection,owner,session,gatewaySourceDigest}){
 const allowed=req=>['127.0.0.1','::ffff:127.0.0.1'].includes(req.socket.remoteAddress)&&req.headers.host===`127.0.0.1:${req.socket.localPort}`;
 const server=createServer(async(req,res)=>{
  if(!allowed(req)||!req.url.startsWith('/')||req.url.startsWith('//')){res.writeHead(403);res.end('Open the saved ERP installation address.');return;}
  try{
   if(req.url==='/__cogentspec/health'){
    const proof=await inspect();if(proof.projectId!==plan.projectId||proof.runtimeId!==plan.runtimeId||proof.sourceDigest!==plan.sourceDigest||proof.planDigest!==plan.planDigest)throw Error('ERP runtime identity changed.');res.writeHead(200,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify({...proof,addressProtocol:1,gatewaySourceDigest}));return;
   }
   if(req.url==='/__cogentspec/session.js'){res.writeHead(200,{'content-type':'application/javascript; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(session.browserCookieScript(plan.key));return;}
   if(await owner(req,res))return;
   if(req.method==='GET'&&req.url==='/'){res.writeHead(303,{location:'/desk/home','cache-control':'no-store'});res.end();return;}
   const port=await connection();
   const proxy=httpRequest({hostname:'127.0.0.1',port,path:req.url,method:req.method,
    headers:{...req.headers,cookie:session.requestCookie(plan.key,req.headers.cookie),'accept-encoding':'identity',connection:'close'},timeout:610000},reply=>{
    const cookies=session.responseCookies(plan.key,reply.headers['set-cookie']);if(cookies)reply.headers['set-cookie']=cookies;
    if((reply.headers['content-type']||'').includes('text/html')){
     let size=0;const chunks=[];
     reply.on('data',chunk=>{size+=chunk.length;if(size>8*1024*1024){reply.destroy();if(!res.headersSent)res.writeHead(502);res.end('ERP page exceeds its display limit.');}else chunks.push(chunk);});
     reply.on('end',()=>{if(res.writableEnded)return;if(reply.headers['content-encoding']&&reply.headers['content-encoding']!=='identity'){res.writeHead(502);res.end('ERP page encoding could not be verified.');return;}
      const body=Buffer.concat(chunks).toString('utf8').replace(/<head(?:\s[^>]*)?>/i,head=>head+'<script src="/__cogentspec/session.js"></script>');delete reply.headers['content-length'];delete reply.headers.etag;res.writeHead(reply.statusCode||502,reply.headers);res.end(body);});
     reply.on('error',()=>{if(!res.writableEnded){if(!res.headersSent)res.writeHead(502);res.end('ERP page could not be loaded.');}});return;
    }
    res.writeHead(reply.statusCode||502,reply.headers);reply.pipe(res);
   });
   proxy.on('timeout',()=>proxy.destroy());proxy.on('error',()=>{if(!res.headersSent)res.writeHead(503);res.end('ERP is unavailable. Reconnect this installation.');});req.pipe(proxy);
  }catch{if(!res.headersSent)res.writeHead(503,{'cache-control':'no-store'});res.end('ERP is unavailable. Reconnect this installation.');}
 });
 server.requestTimeout=610000;
 server.on('upgrade',async(req,socket,head)=>{
  if(!allowed(req)){socket.destroy();return;}
  try{const port=await connection();const target=connect(port,'127.0.0.1',()=>{
   target.write(`${req.method} ${req.url} HTTP/1.1\r\n`+Object.entries({...req.headers,cookie:session.requestCookie(plan.key,req.headers.cookie)}).map(([key,value])=>`${key}: ${value}`).join('\r\n')+'\r\n\r\n');if(head.length)target.write(head);socket.pipe(target).pipe(socket);
  });target.on('error',()=>socket.destroy());socket.on('error',()=>target.destroy());}catch{socket.destroy();}
 });
 return server;
}

export async function verifiedErpNativeConnection(project,plan){
 const rows=JSON.parse(await execute('docker',['inspect',plan.key+'-frontend-1'])),row=rows[0],labels=row?.Config?.Labels||{},ports=row?.NetworkSettings?.Ports?.['8080/tcp'];
 if(rows.length!==1||labels['com.cogentspec.erpnext.project']!==project.id||labels['com.cogentspec.erpnext.root']!==plan.rootDigest||labels['com.cogentspec.erpnext.source']!==plan.imageSourceDigest||!Array.isArray(ports)||ports.length!==1||ports[0].HostIp!=='127.0.0.1'||!/^\d+$/.test(ports[0].HostPort))throw Error('The ERP frontend ownership or private socket changed.');
 return Number(ports[0].HostPort);
}
async function stopPrevious(project,listener){
 if(!listener||listener.pid===process.pid)return;
 if(listener.projectId!==project.id||!Number.isInteger(listener.pid)||listener.pid<=0)throw Error('The previous ERP listener identity changed.');
 const runtimeFile=resolve(project.targetPath,'scripts/erpnext-runtime.mjs');
 if(process.platform==='win32'){
  const script="$ErrorActionPreference='Stop';$x=[Console]::In.ReadToEnd()|ConvertFrom-Json;$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$x.pid);if($p){if($p.Name -notmatch '^node(?:\\.exe)?$' -or $p.CommandLine -notmatch ('(?:^|[\"\\s])'+[Regex]::Escape([string]$x.runtimeFile)+'(?=[\"\\s]|$)')){throw 'ERP listener ownership changed'};Stop-Process -Id $x.pid -ErrorAction Stop}";
  await execute('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{input:JSON.stringify({pid:listener.pid,runtimeFile}),timeout:15000});
 }else{
  let command;try{command=(await readFile(`/proc/${listener.pid}/cmdline`,'utf8')).split('\0');}catch(error){if(error.code!=='ENOENT')throw error;}
  if(command){if(!command.includes(runtimeFile))throw Error('ERP listener ownership changed.');try{process.kill(listener.pid);}catch(error){if(error.code!=='ESRCH')throw error;}}
 }
}
export async function startErpInstallationGateway(project){
 const root=await realpath(project.targetPath);if(root.toLowerCase()!==resolve(project.targetPath).toLowerCase())throw Error('Linked installation folders are not supported.');
 for(const name of ['scripts','.coge','scripts/erpnext-runtime.mjs','scripts/first-owner.mjs','scripts/owner-session.mjs','scripts/erpnext-session.mjs'])if((await lstat(resolve(root,name))).isSymbolicLink())throw Error('Linked ERP adapters are not supported.');
 const runtime=await import(pathToFileURL(resolve(root,'scripts/erpnext-runtime.mjs'))),plan=await runtime.validatePlan();
 if(plan.projectId!==project.id||plan.runtimeId!==project.contractRuntimeId||project.projectType!=='erpnext_business_app')throw Error('The ERP installation binding changed.');
 const state=resolve(root,'.coge/runtime');await mkdir(state,{recursive:true});const lock=await open(resolve(root,'.coge/operation.lock'),'wx',0o600);
 let server;
 try{
  let previous;try{previous=JSON.parse(await readFile(resolve(state,'listener.json'),'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
  try{const proof=await runtime.inspect();if(!proof.ready)throw Error('ERP is stopped.');}catch{
   await execute('docker',['compose','--project-name',plan.key,'-f',resolve(state,'compose.json'),'up','-d','--wait','--wait-timeout','180','database','cache','queue','backend','websocket','worker','scheduler','frontend'],{timeout:240000});
   await execute('docker',['compose','--project-name',plan.key,'-f',resolve(state,'compose.json'),'restart','frontend'],{timeout:60000});
   const proof=await runtime.inspect();if(!proof.ready||proof.projectId!==project.id||proof.runtimeId!==project.contractRuntimeId)throw Error('The existing ERP has not become ready.');
  }
  const connection=()=>verifiedErpNativeConnection(project,plan);await connection();
  const session=await import(pathToFileURL(resolve(root,'scripts/erpnext-session.mjs'))),{firstOwnerHandler}=await import(pathToFileURL(resolve(root,'scripts/first-owner.mjs'))),{establishOwnerSession}=await import(pathToFileURL(resolve(root,'scripts/owner-session.mjs')));
  const ownerOutput=await execute('docker',['compose','--project-name',plan.key,'-f',resolve(state,'compose.json'),'exec','-T','--workdir','/home/frappe/frappe-bench/sites','backend','/home/frappe/frappe-bench/env/bin/python','-'],{input:"import frappe,json\nfrappe.init(site='cogent.local');frappe.connect();print('COGENT_OWNER='+json.dumps({'ready':bool(frappe.db.get_default('cogent_initial_account'))}));frappe.destroy()\n",timeout:30000});
  const ownerLine=ownerOutput.split(/\r?\n/).find(line=>line.startsWith('COGENT_OWNER='));if(!ownerLine)throw Error('The existing ERP owner state could not be verified.');const ownerReady=JSON.parse(ownerLine.slice(13)).ready;
  const owner=firstOwnerHandler({scope:plan.key,ready:ownerReady,provision:input=>runtime.provisionInitialAccount({protocol:1,operation:'provision_initial',projectId:plan.projectId,runtimeId:plan.runtimeId,kind:'backend',jobId:'local-owner-'+plan.projectId,entryId:'first-owner',loginName:input.email,password:input.password,fullName:input.fullName}),signIn:async input=>establishOwnerSession({scope:plan.key,port:await connection(),email:input.email,password:input.password})});
  const gatewaySourceDigest=await erpGatewaySourceDigest();
  server=createErpAddressGateway({plan,inspect:()=>runtime.inspect(),connection,owner,session,gatewaySourceDigest});
  const saved=await readErpAddress(project);if(previous&&saved?.url===previous.url)await stopPrevious(project,previous);
  const address=await bindErpAddress(project,server);
  const temporary=resolve(state,'listener.'+process.pid+'.'+randomUUID()+'.tmp');
  try{
   await writeFile(temporary,JSON.stringify({projectId:project.id,runtimeId:project.contractRuntimeId,sourceDigest:plan.sourceDigest,planDigest:plan.planDigest,addressProtocol:1,gatewaySourceDigest,pid:process.pid,url:address.url},null,2)+'\n',{mode:0o600,flag:'wx'});
   if(!saved||previous?.url!==saved.url)await stopPrevious(project,previous);
   for(let attempt=0;;attempt++){try{await rename(temporary,resolve(state,'listener.json'));break;}catch(error){if(!['EACCES','EPERM','EBUSY'].includes(error.code)||attempt>=5)throw error;await delay(100);}}
  }finally{await unlink(temporary).catch(error=>{if(error.code!=='ENOENT')throw error;});}
  console.log(JSON.stringify({status:'running',engine:'erpnext',projectId:project.id,localUrl:address.url,addressProtocol:1}));
  const close=()=>server.close();process.once('SIGINT',close);process.once('SIGTERM',close);return server;
 }catch(error){server?.close();throw error;}finally{await lock.close();await unlink(resolve(root,'.coge/operation.lock'));}
}
