import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {commandBinding,validQwenConversation,verifiedHandoff,workspaceTab} from './policy.mjs';

const id='a'.repeat(32),request={protocol:'cogentspec-qwen-web-command-v1',command:'$qwenweb',requestId:crypto.randomUUID()};
const sender={id,documentId:crypto.randomUUID(),url:'https://chat.qwen.ai/c/private-conversation-id'};
const context='ctx-'+'a'.repeat(64);
const proof={protocol:'cogentspec-qwenweb-navigation-v1',status:'ready',browserOpened:false,
 workspaceUrl:'https://cogentspec.app/stack?surface=qwen-web&context='+context+'&experience=web&open=web&nav='+'b'.repeat(32)+'#desktop-web=cgw_'+'c'.repeat(40)};
test('browser frames bind only the exact Qwen conversation and never send its URL to the host',async()=>{
 const binding=await commandBinding(request,sender,id);assert.match(binding.contextKey,/^ctx-[a-f0-9]{64}$/);
 assert.doesNotMatch(JSON.stringify(binding),/private-conversation|https:|cookie|path|token/);
 assert.equal((await commandBinding(request,{...sender,documentId:'different'},id)).contextKey,binding.contextKey,'Reload keeps an existing conversation isolated and stable');
 assert.notEqual((await commandBinding(request,{...sender,url:sender.url+'-other'},id)).contextKey,binding.contextKey);
 for(const patch of [{id:'other'},{documentId:''},{url:'https://qwen.ai.attacker.invalid/c/abc'},{url:'http://qwen.ai/c/abc'},{url:'https://qwen.ai:444/c/abc'}])assert.equal(await commandBinding(request,{...sender,...patch},id),null);
 for(const path of ['/','/auth','/auth/login','/login','/settings']) assert.equal(validQwenConversation('https://chat.qwen.ai'+path),null);
 for(const patch of [{command:'$qwenlocal'},{command:'powershell.exe'},{requestId:'bad'},{script:'arbitrary'}])assert.equal(await commandBinding({...request,...patch},sender,id),null);
});
test('only exact provider/context Web grants reach navigation',()=>{
 const binding={contextKey:context,requestId:request.requestId},value={...proof,requestId:request.requestId};
 assert.equal(verifiedHandoff(value,binding),proof.workspaceUrl);
 for(const patch of [{requestId:'stale'},{status:'connected'},{browserOpened:true},
  {workspaceUrl:proof.workspaceUrl.replace('qwen-web','chatgpt')},
  {workspaceUrl:proof.workspaceUrl.replace('cogentspec.app','attacker.invalid')},
  {workspaceUrl:proof.workspaceUrl.replace(context,'ctx-'+'d'.repeat(64))},
  {workspaceUrl:proof.workspaceUrl.replace('&open=web','&open=web&open=web')},
  {workspaceUrl:proof.workspaceUrl.split('#')[0]}])assert.equal(verifiedHandoff({...value,...patch},binding),null);
 assert.equal(workspaceTab('https://cogentspec.app/stack?surface=chatgpt&experience=web'),false);
});

test('worker delivers one private handoff and requires page verification, failing closed for ambiguity and cancellation',async()=>{
 const source=await readFile(new URL('./worker.mjs',import.meta.url),'utf8');
 const binding=await commandBinding(request,sender,id);
 let handler,updates=[],mode='success';
 const chrome={runtime:{id,onMessage:{addListener:fn=>handler=fn},sendNativeMessage:async()=>({...proof,requestId:binding.requestId,
  workspaceUrl:proof.workspaceUrl.replace(context,binding.contextKey)})},tabs:{
  query:async()=>mode==='ambiguous'?[{id:1,url:proof.workspaceUrl},{id:2,url:proof.workspaceUrl}]:[{id:1,url:proof.workspaceUrl}],
  sendMessage:async(_id,message)=>message.operation==='prepare'?{approved:mode!=='cancel'}:{connected:mode!=='unverified'},
  update:async(id,args)=>updates.push({id,args})}};
 runInNewContext(source.replace(/^import [^\r\n]+[\r\n]+/,''),{chrome,commandBinding,verifiedHandoff,workspaceTab,Set,Promise,Error,setTimeout:fn=>fn()});
 const send=()=>new Promise(resolve=>handler(request,sender,resolve));
 assert.equal((await send()).connected,true);assert.equal(updates.length,1);assert.equal(updates[0].id,1);
 for(const failure of ['ambiguous','cancel','unverified']){mode=failure;const before=updates.length;assert.equal((await send()).connected,false);assert.equal(updates.length,before+(failure==='unverified'?1:0));}
 assert.doesNotMatch(source,/tabs\.create|windows\.|fetch\(|postMessage/);
});

test('only real exact-command Send or Enter actions trigger the content script',async()=>{
 const source=await readFile(new URL('./command.js',import.meta.url),'utf8'),listeners=new Map(),sent=[];
 class Element {
  constructor(kind='editor'){this.kind=kind;this.value='$qwenweb';this.textContent='';this.style={};}
  closest(selector){if(selector.startsWith('[hidden]'))return null;if(selector==='button,[role="button"]')return this.kind==='button'?this:null;return this.kind==='editor'?this:null;}
  getClientRects(){return [1];} getAttribute(name){return this.kind==='button'&&name==='aria-label'?'Send':null;}
  matches(){return this.kind==='button';} attachShadow(){return {append(){}};} setAttribute(){} append(){} remove(){}
 }
 const editor=new Element(),button=new Element('button');
 const document={addEventListener:(name,fn)=>listeners.set(name,fn),createElement:()=>new Element('status'),documentElement:new Element('root'),querySelector:()=>editor};
 runInNewContext(source,{document,Element,location:{pathname:'/c/example'},crypto,Date,Promise,
  setTimeout:()=>1,clearTimeout(){},chrome:{runtime:{sendMessage:async message=>{sent.push(message);return {connected:true,message:'Bridge connected.'};}}}});
 const enter={isTrusted:true,isComposing:false,key:'Enter',target:editor};
 for(const event of [{...enter,isTrusted:false},{...enter,isComposing:true},{...enter,shiftKey:true},{...enter,key:'a'}])listeners.get('keydown')(event);
 assert.equal(sent.length,0);
 editor.value='ordinary message';listeners.get('keydown')(enter);assert.equal(sent.length,0);
 editor.value='$qwenweb';listeners.get('keydown')(enter);await new Promise(resolve=>setImmediate(resolve));assert.equal(sent.length,1);
 listeners.get('focusin')({target:editor});listeners.get('click')({isTrusted:true,target:button});await new Promise(resolve=>setImmediate(resolve));assert.equal(sent.length,2);
 const envelope='$qwenweb\n\nCogentSpec $qwenweb instructions, version 1.0.0, marketplace revision '+'a'.repeat(40)+'.\n'
  +'--- BEGIN plugins/cogentspec/skills/qwenweb/SKILL.md ---\nOfficial instructions\n--- END plugins/cogentspec/skills/qwenweb/SKILL.md ---\n\n'
  +'--- BEGIN qwen-web-extension/README.md ---\nSetup instructions\n--- END qwen-web-extension/README.md ---\n\n'
  +'Work area: https://cogentspec.app/stack?experience=web&surface=qwen-web';
 for(const value of [envelope.replace('$qwenweb','$qwenlocal'), envelope.replace('surface=qwen-web','surface=chatgpt'), '$qwenweb\nPlease connect', envelope+' extra']) {
  editor.value=value;listeners.get('keydown')(enter);await new Promise(resolve=>setImmediate(resolve));assert.equal(sent.length,2);
 }
 editor.value=envelope;listeners.get('keydown')(enter);await new Promise(resolve=>setImmediate(resolve));assert.equal(sent.length,3);
 editor.value=envelope.replace(/\n/g,'\r\n');listeners.get('keydown')(enter);await new Promise(resolve=>setImmediate(resolve));assert.equal(sent.length,4);
 assert.deepEqual(Object.keys(sent[0]).sort(),['command','protocol','requestId']);
 assert.doesNotMatch(source,/preventDefault|stopPropagation|window\.postMessage\s*\(|tabs\.|innerHTML|localStorage/);
});
test('native transport compiles, validates framing, rejects arbitrary execution and redacts its reply',{skip:process.platform!=='win32'},()=>{
 const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./test-native.ps1',import.meta.url))],{encoding:'utf8',windowsHide:true,timeout:15000});
 assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'passed');
});
test('extension permissions are limited to native messaging and provider/work-area hosts',async()=>{
 const manifest=JSON.parse(await readFile(new URL('./manifest.json',import.meta.url),'utf8'));
 assert.deepEqual(manifest.permissions,['nativeMessaging']);assert.equal(manifest.externally_connectable,undefined);
 assert.ok(manifest.content_scripts[0].all_frames);assert.ok(manifest.host_permissions.every(host=>host.includes('qwen.ai')||host==='https://cogentspec.app/stack*'));
});

test('workspace confirmation and verification require the exact page, consumed grant, green status and authorized library',async()=>{
 const source=await readFile(new URL('./workspace.js',import.meta.url),'utf8');
 let handler,approved=true,green=true,status=200,calls=0;
 const location={href:proof.workspaceUrl.split('#')[0]};
 runInNewContext(source,{URL,location,window:{confirm:()=>approved},AbortSignal,
  document:{querySelector:()=>green?{}:null},chrome:{runtime:{id,onMessage:{addListener:fn=>handler=fn}}},
  fetch:async url=>{calls++;assert.equal(url,'/api/project-requests?surface=qwen-web&context='+context);return {ok:status===200,json:async()=>({requests:[]})};}});
 const send=(operation,change={},senderId=id)=>new Promise(resolve=>{
  const pending=handler({protocol:'cogentspec-qwen-web-page-v1',operation,contextKey:context,...change},{id:senderId},resolve);
  if(!pending)resolve(undefined);
 });
 assert.equal((await send('prepare')).approved,true);approved=false;assert.equal((await send('prepare')).approved,false);
 assert.equal((await send('verify')).connected,true);
 green=false;assert.equal((await send('verify')).connected,false);green=true;
 status=401;assert.equal((await send('verify')).connected,false);status=200;
 const before=calls;assert.equal(await send('verify',{contextKey:'ctx-'+'f'.repeat(64)}),undefined);
 assert.equal(await send('verify',{},'other-extension'),undefined);location.href=proof.workspaceUrl;
 assert.equal(await send('verify'),undefined);assert.equal(calls,before,'Unconsumed or mismatched handoffs must not query a library');
});
