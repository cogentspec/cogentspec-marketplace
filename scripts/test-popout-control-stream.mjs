import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {resolve} from 'node:path';
const worker='aaaaaaaa-1111-1111-1111-111111111111',owner='bbbbbbbb-1111-1111-1111-111111111111',key='a'.repeat(64);
let connects=0;const acks=[],sent=new Map(),roundTrips=new Map(),responses=new Set(),timers=new Set();
const later=(fn,ms)=>{const timer=setTimeout(()=>{timers.delete(timer);fn();},ms);timers.add(timer);};
const server=createServer((req,res)=>{
 assert.equal(req.headers.authorization,'Bearer test-only-stream-token');
 const url=new URL(req.url,'http://127.0.0.1');
 assert.equal(url.pathname,'/api/plugin/desktop-popout-control-stream');
 assert.equal(url.searchParams.get('workerId'),worker);assert.equal(url.searchParams.get('fingerprint'),key);
 if(req.method==='POST'){
  acks.push(Object.fromEntries(url.searchParams));
  const seq=Number(url.searchParams.get('sequence'));
  if(sent.has(seq)&&!roundTrips.has(seq))roundTrips.set(seq,performance.now()-sent.get(seq));
  res.setHeader('Content-Type','application/json');res.end('{"accepted":true}');return;
 }
 connects++;responses.add(res);res.on('close',()=>responses.delete(res));
 res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
 const send=(seq,state,window=key,id=worker,age=0)=>{
  if(res.destroyed)return;const now=Date.now();if(seq<900&&!age&&!sent.has(seq))sent.set(seq,performance.now());
  res.write(`event: control\ndata: v1\t${id}\t${owner}\t${window}\t${seq}\t${state}\t0\t${now-age}\n\n`);
 };
 if(connects===1){
  send(1,'active');later(()=>send(2,'hidden'),180);later(()=>send(3,'active'),360);
  later(()=>send(900,'close','b'.repeat(64)),400);
  later(()=>send(901,'close',key,'cccccccc-1111-1111-1111-111111111111'),430);
  // A buffered obsolete frame must force reconnection, never act on stale hide.
  later(()=>send(4,'hidden',key,worker,5000),600);
 }else{
  send(5,'active');later(()=>send(6,'close'),180);
  later(()=>send(6,'close'),1000);later(()=>send(6,'close'),2000);later(()=>send(6,'close'),3000);
 }
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
try{
 const output=await new Promise((done,fail)=>{
  const child=spawn(process.env.COGENTSPEC_TEST_POWERSHELL||'powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',resolve(import.meta.dirname,'test-popout-control-stream.ps1'),'-ServiceUrl',`http://127.0.0.1:${server.address().port}`],{windowsHide:true});
  let text='';child.stdout.on('data',c=>text+=c);child.stderr.on('data',c=>text+=c);child.on('error',fail);
  child.on('exit',code=>code===0?done(text):fail(Error(text)));
 });
 const report=JSON.parse(output.trim());const unique=new Map(report.frames.map(f=>[f.Sequence,f]));
 for(const seq of [1,2,3,5,6])assert.ok(unique.has(seq),`missing ${seq}`);
 for(const seq of [4,900,901])assert.ok(!unique.has(seq),`accepted stale/foreign ${seq}`);
 assert.ok(connects>=2);assert.ok(acks.some(a=>a.outcome==='close_confirmed'&&a.ownerId===owner));
 assert.equal(report.nativeWindowCallsPerformed,false);assert.equal(report.fresh,true);
 // One monotonic clock includes both delivery and acknowledgment. Comparing
 // Node Date.now with .NET UtcNow gives false negative times on Windows clocks.
 const latency=[1,2,3,5].map(seq=>roundTrips.get(seq));
 assert.ok(latency.every(ms=>ms>=0&&ms<500),`loopback acknowledgment too slow: ${latency}`);
 console.log(JSON.stringify({status:'passed',connects,acknowledgmentMilliseconds:latency.map(x=>Math.round(x)),mainThreadBlockedSeconds:5,
  nativeWindowCallsPerformed:false,physicalAcceptance:'not_performed'}));
}finally{
 for(const timer of timers)clearTimeout(timer);for(const response of responses)response.destroy();
 server.closeAllConnections();await new Promise(r=>server.close(r));
}
