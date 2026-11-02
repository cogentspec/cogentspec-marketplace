// Trusted local test host. It receives only collected compiled output, never the
// registered source folder, normal databases, saved settings or Bridge token.
import {createServer} from 'node:http';
import {readFile,realpath} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {randomBytes} from 'node:crypto';
let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>8192)throw Error('Invalid test host input.');}
const config=JSON.parse(input),root=await realpath(config.root),require=createRequire(path.join(config.runtimeRoot,'package.json'));
const types={html:'text/html',css:'text/css',js:'application/javascript',mjs:'application/javascript',json:'application/json',svg:'image/svg+xml',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',webp:'image/webp',ico:'image/x-icon',woff2:'font/woff2'};
const assets=path.join(root,config.kind==='static'?'bundle':'bundle/assets');
async function asset(request){try{const pathname=decodeURIComponent(new URL(request.url).pathname);if(pathname.includes('\\')||pathname.split('/').some(p=>p==='..'||p.startsWith('.')))return new Response('Not found',{status:404});const file=await realpath(path.resolve(assets,'.'+(pathname==='/'?'/index.html':pathname)));if(!file.startsWith(assets+path.sep))return new Response('Not found',{status:404});return new Response(await readFile(file),{headers:{'content-type':types[path.extname(file).slice(1)]||'application/octet-stream'}});}catch{return new Response('Not found',{status:404});}}
let env,worker,mf,origin;
const server=createServer(async(incoming,outgoing)=>{
 try{if(!env){outgoing.writeHead(503);outgoing.end();return;}const url=new URL(incoming.url||'/',origin);const chunks=[];let size=0;for await(const chunk of incoming){size+=chunk.length;if(size>1024*1024)throw Error();chunks.push(chunk);}
  const request=new Request(url,{method:incoming.method,headers:incoming.headers,...(!['GET','HEAD'].includes(incoming.method)?{body:Buffer.concat(chunks)}:{})});
  let response;if(config.kind==='static'||/\.(?:css|js|mjs|png|jpe?g|webp|svg|woff2|ico)$/.test(url.pathname))response=await asset(request);else response=await worker.fetch(request,env,{waitUntil(p){void Promise.resolve(p).catch(()=>{});},passThroughOnException(){}});
  const body=Buffer.from(await response.arrayBuffer());if(body.length>16*1024*1024)throw Error();const headers=Object.fromEntries(response.headers);headers['cache-control']='no-store';if(response.headers.getSetCookie)headers['set-cookie']=response.headers.getSetCookie();outgoing.writeHead(response.status,headers);outgoing.end(body);
 }catch{outgoing.writeHead(502);outgoing.end('The isolated test request failed.');}
});
process.on('message',message=>{if(message?.action==='stop')void close();});
await new Promise(done=>server.listen(0,'127.0.0.1',done));origin='http://127.0.0.1:'+server.address().port;
if(config.kind!=='static'){
 const {Miniflare}=await import(pathToFileURL(require.resolve('miniflare')).href);
 mf=new Miniflare({modules:true,script:"export default{fetch(){return new Response('test')}}",d1Databases:['DB'],d1Persist:path.join(root,'test-data')});
 const sharp=(await import(pathToFileURL(require.resolve('sharp')).href)).default;
 env={DB:await mf.getD1Database('DB'),ASSETS:{fetch:asset},BETTER_AUTH_URL:origin,BETTER_AUTH_SECRET:randomBytes(48).toString('base64url'),
  ADMIN_LOCAL_SETUP_MODE:'loopback-trusted-v1',ADMIN_LOCAL_BIND_ADDRESS:'127.0.0.1',AUTH_EMAIL_CAPTURE_MODE:'local-owner-capture-v1',
  IMAGES:{input(stream){let options={};return{transform(value){options=value;return this;},async output({format,quality}){let image=sharp(Buffer.from(await new Response(stream).arrayBuffer()),{limitInputPixels:40000000});if(options.width)image=image.resize({width:options.width,withoutEnlargement:true});const bytes=await image.toFormat(format==='image/webp'?'webp':format==='image/avif'?'avif':'jpeg',{quality}).toBuffer();return{response:()=>new Response(bytes,{headers:{'content-type':format}})};}};}}};
 // Ordinary fetch-based external integrations are disabled in this test host.
 // This is a separate-data test process, not an OS sandbox for hostile code.
 const originalFetch=globalThis.fetch;globalThis.fetch=(request,options)=>{const url=new URL(typeof request==='string'||request instanceof URL?request:request.url);if(url.origin!==origin)return Promise.reject(Error('External services and working previews are disabled during Polish.'));return originalFetch(request,options);};
 worker=(await import(pathToFileURL(path.join(root,'bundle/app/index.js')).href)).default;if(typeof worker?.fetch!=='function')throw Error('Unsupported test output.');
}else env={};
process.stdout.write(JSON.stringify({ready:true,origin,isolatedData:true})+'\n');
async function close(){server.closeAllConnections();server.close();await mf?.dispose();process.exit(0);}
process.on('SIGTERM',()=>void close());process.on('SIGINT',()=>void close());
