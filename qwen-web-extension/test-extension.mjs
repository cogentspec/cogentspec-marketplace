import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {commandBinding,validQwenConversation,verifiedReceipt} from './policy.mjs';

const id='a'.repeat(32),request={protocol:'cogentspec-qwen-web-command-v1',command:'$qwenweb',requestId:crypto.randomUUID()};
const sender={id,documentId:crypto.randomUUID(),url:'https://chat.qwen.ai/c/private-conversation-id'};
const proof={protocol:'cogentspec-workspace-beacon-start-v1',status:'connected',workspaceConnected:true,acknowledgementVerified:true,
 browserReused:true,browserOpened:false,browserHandoff:'authenticated-workspace-reuse',surface:'qwen-web',experience:'web'};
test('browser frames bind only the exact Qwen conversation and never send its URL to the host',async()=>{
 const binding=await commandBinding(request,sender,id);assert.match(binding.contextKey,/^ctx-[a-f0-9]{64}$/);
 assert.doesNotMatch(JSON.stringify(binding),/private-conversation|https:|cookie|path|token/);
 assert.equal((await commandBinding(request,{...sender,documentId:'different'},id)).contextKey,binding.contextKey,'Reload keeps an existing conversation isolated and stable');
 assert.notEqual((await commandBinding(request,{...sender,url:sender.url+'-other'},id)).contextKey,binding.contextKey);
 for(const patch of [{id:'other'},{documentId:''},{url:'https://qwen.ai.attacker.invalid/c/abc'},{url:'http://qwen.ai/c/abc'},{url:'https://qwen.ai:444/c/abc'}])assert.equal(await commandBinding(request,{...sender,...patch},id),null);
 for(const path of ['/','/auth','/auth/login','/login','/settings']) assert.equal(validQwenConversation('https://chat.qwen.ai'+path),null);
 for(const patch of [{command:'$qwenlocal'},{command:'powershell.exe'},{requestId:'bad'},{script:'arbitrary'}])assert.equal(await commandBinding({...request,...patch},sender,id),null);
});
test('only fresh Qwen Web authenticated reuse receipts qualify as connected',()=>{
 assert.equal(verifiedReceipt(proof),true);
 for(const patch of [{surface:'chatgpt'},{experience:'split-screen'},{acknowledgementVerified:false},{browserOpened:true},{browserReused:false},{status:'ready'}])assert.equal(verifiedReceipt({...proof,...patch}),false);
});
test('worker uses native messaging only, fences duplicate requests and strips host output',{timeout:5000},async()=>{
 const source=await readFile(new URL('./worker.mjs',import.meta.url),'utf8');let handler,finish,calls=0,started;
 const nativeStarted=new Promise(resolve=>{started=resolve;});
 const chrome={runtime:{id,onMessage:{addListener:value=>handler=value},sendNativeMessage:async(name,binding)=>{
  assert.equal(name,'com.cogentspec.qwen_web');assert.deepEqual(Object.keys(binding).sort(),['command','contextKey','protocol','requestId']);calls++;
  return new Promise(resolve=>{finish=()=>resolve({...proof,requestId:binding.requestId,secret:'private'});started();});
 }}};
 runInNewContext(source.replace(/^import [^\r\n]+[\r\n]+/,''),{chrome,commandBinding,verifiedReceipt,Set});
 let replyFirst;const firstReply=new Promise(resolve=>{replyFirst=resolve;});handler(request,sender,replyFirst);await nativeStarted;
 const second=await new Promise(resolve=>handler({...request,requestId:crypto.randomUUID()},sender,resolve));
 assert.equal(calls,1);assert.equal(second.connected,false);finish();const first=await firstReply;
 assert.deepEqual(JSON.parse(JSON.stringify(first)),{connected:true,message:'Bridge connected.'});
 chrome.runtime.sendNativeMessage=async()=>({...proof,requestId:'stale'});
 const stale=await new Promise(resolve=>handler({...request,requestId:crypto.randomUUID()},sender,resolve));assert.equal(stale.connected,false);
 assert.doesNotMatch(source,/tabs\.|windows\.|fetch\(|postMessage/);
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
 assert.deepEqual(Object.keys(sent[0]).sort(),['command','protocol','requestId']);
 assert.doesNotMatch(source,/preventDefault|stopPropagation|window\.postMessage\s*\(|tabs\.|innerHTML|localStorage/);
});
test('native transport compiles, validates framing, rejects arbitrary execution and redacts its reply',{skip:process.platform!=='win32'},()=>{
 const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./test-native.ps1',import.meta.url))],{encoding:'utf8',windowsHide:true,timeout:15000});
 assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'passed');
});
test('extension permissions exclude credentials, CogentSpec pages, tab control and external messages',async()=>{
 const manifest=JSON.parse(await readFile(new URL('./manifest.json',import.meta.url),'utf8'));
 assert.deepEqual(manifest.permissions,['nativeMessaging']);assert.equal(manifest.externally_connectable,undefined);
 assert.ok(manifest.content_scripts[0].all_frames);assert.ok(manifest.host_permissions.every(host=>host.includes('qwen.ai')));
});
