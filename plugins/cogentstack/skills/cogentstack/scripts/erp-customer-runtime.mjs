// Customer VRC tooling. Never edits the installed upstream or Cogent foundation.
import {createHash,randomUUID} from 'node:crypto';
import {createWriteStream} from 'node:fs';
import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdir,readdir,lstat,realpath,open,unlink,cp} from 'node:fs/promises';
import {resolve,dirname,relative,isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';

const hash=value=>createHash('sha256').update(value).digest('hex');
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const json=async path=>JSON.parse(await readFile(path,'utf8'));
const save=async(path,value)=>{await mkdir(dirname(path),{recursive:true});await writeFile(path,JSON.stringify(value,null,2)+'\n',{mode:0o600});};
const exists=async path=>{try{await lstat(path);return true;}catch(error){if(error.code==='ENOENT')return false;throw error;}};
export async function execute(program,args,{input,timeout=120000,logPath,captureStderr=false}={}){
 return new Promise((done,fail)=>{const child=spawn(program,args,{windowsHide:true,stdio:['pipe','pipe','pipe']});let output='',size=0,settled=false;
  const log=logPath?createWriteStream(logPath,{mode:0o600,flags:'a'}):null;
  const finish=error=>{if(settled)return;settled=true;clearTimeout(timer);log?.end();error?fail(error):done(output.trim());};
  const timer=setTimeout(()=>{child.kill();finish(Error('Customer release operation timed out. Inspect its state before retrying.'));},timeout);
  child.on('error',()=>finish(Error('A required local build tool is unavailable.')));child.stdout.on('data',chunk=>{log?.write(chunk);size+=chunk.length;if(size>4*1024*1024){child.kill();finish(Error('Build output exceeded its limit.'));}else output+=chunk;});
  // Process output may contain customer data. Return only structured receipts.
  child.stderr.on('data',chunk=>{log?.write(chunk);if(captureStderr){size+=chunk.length;if(size>4*1024*1024){child.kill();finish(Error('Build output exceeded its limit.'));}else output+=chunk;}});child.on('close',code=>finish(code===0?null:Error('Customer release operation failed ('+program+', exit '+code+').'+(logPath?' Inspect the private operation log.':''))));child.stdin.on('error',()=>{});child.stdin.end(input);
 });
}
const docker=(args,options)=>execute('docker',args,options);
async function safeRoot(path){if(!isAbsolute(path))throw Error('An absolute installation folder is required.');const root=await realpath(path);if(root.toLowerCase()!==resolve(path).toLowerCase()||(await lstat(path)).isSymbolicLink())throw Error('Linked installation folders are not supported.');return root;}
async function noLinks(root,path){let current=root;for(const part of relative(root,path).split(/[\\/]/)){if(!part||part==='..')throw Error('Invalid customer layer path.');current=resolve(current,part);if(await exists(current)&&(await lstat(current)).isSymbolicLink())throw Error('Linked customer source is not supported.');}}
export async function customerBinding(project,handoff){
 const root=await safeRoot(project.targetPath),runtime=await import(pathToFileURL(resolve(root,'scripts/erpnext-runtime.mjs'))),plan=await runtime.validatePlan();
 const work=handoff.erpCustomisation||handoff;
 if(project.projectType!=='erpnext_business_app'||!uuid(work.id)||work.installationId!==project.id||work.runtimeId!==project.contractRuntimeId||work.packVersion!==project.packVersion||work.packId!==project.packId||work.contextKey!==project.contextKey||plan.projectId!==project.id||plan.runtimeId!==project.contractRuntimeId||!Array.isArray(work.selectedApps)||!work.selectedApps.length||work.selectedApps.some(app=>!plan.apps.includes(app)))throw Error('The customer work does not match this installed ERP and module scope.');
 const app='customer_'+work.id.replaceAll('-','').slice(0,20),directory=resolve(root,'.coge/customer-vrc'),source=resolve(directory,'apps',app);
 await noLinks(root,directory);return {root,runtime,plan,work,app,directory,source,project};
}
export async function sourceInventory(directory){
 const rows=[];let bytes=0;
 async function walk(path=''){for(const name of(await readdir(resolve(directory,path))).sort()){
  if(['.git','__pycache__','node_modules','.venv','dist'].includes(name))continue;
  if(name==='.env'||name.startsWith('.env.')||/\.(pem|key|p12|pfx)$/i.test(name))throw Error('Keep credentials and private keys outside customer source packages.');
  const file=path?path+'/'+name:name,info=await lstat(resolve(directory,file));if(info.isSymbolicLink()||(!info.isDirectory()&&!info.isFile()))throw Error('Customer source must contain regular files only.');
  if(info.isDirectory())await walk(file);else{bytes+=info.size;if(info.size>2*1024*1024||bytes>8*1024*1024||rows.length>=300)throw Error('Customer source exceeds the package limit.');rows.push([file,hash(await readFile(resolve(directory,file)))]);}
 }}await walk();return {digest:hash(JSON.stringify(rows)),files:rows,bytes};
}
async function locked(binding,fn){await mkdir(binding.directory,{recursive:true});const path=resolve(binding.directory,'operation.lock'),basePath=resolve(binding.root,'.coge/operation.lock');let handle,baseHandle;
 try{baseHandle=await open(basePath,'wx',0o600);handle=await open(path,'wx',0o600);await handle.writeFile(JSON.stringify({pid:process.pid}));}catch{if(baseHandle){await baseHandle.close();await unlink(basePath);}throw Error('Another installation or customer release operation is running.');}
 try{return await fn();}finally{await handle.close();await unlink(path);await baseHandle.close();await unlink(basePath);}
}
export async function initializeCustomerLayer(project,handoff){const b=await customerBinding(project,handoff);return locked(b,async()=>{
 const identity={protocol:1,projectId:project.id,runtimeId:project.contractRuntimeId,customisationId:b.work.id,packId:project.packId,packVersion:project.packVersion,app:b.app};
 const manifest=resolve(b.directory,'identity.json');if(await exists(manifest)){if(JSON.stringify(await json(manifest))!==JSON.stringify(identity))throw Error('The customer layer identity changed.');return {status:'ready',...identity,sourceDirectory:b.source};}
 await mkdir(resolve(b.source,b.app,'public/js'),{recursive:true});await mkdir(resolve(b.source,b.app,'tests'),{recursive:true});
 const files={'pyproject.toml':`[build-system]\nrequires = ["flit_core>=3.4,<4"]\nbuild-backend = "flit_core.buildapi"\n[project]\nname = "${b.app}"\ndescription = "Installation-specific customer customisations"\nversion = "1.0.0"\ndependencies = []\n`,[b.app+'/__init__.py']:'__version__ = "1.0.0"\n',[b.app+'/hooks.py']:`app_name = "${b.app}"\napp_title = "Customer customisations"\napp_publisher = "Customer"\napp_description = "Installation-specific customer VRC layer"\napp_email = ""\napp_license = "GPL-3.0"\nrequired_apps = ["cogent_erp"]\napp_include_js = ["${b.app}.bundle.js"]\n`,[b.app+'/modules.txt']:'',[b.app+'/patches.txt']:'',[b.app+'/tests/__init__.py']:'',[b.app+'/public/js/'+b.app+'.bundle.js']:'// Add the approved customer interface changes here.\n', 'README.md':'Customer source only. Keep the ERPNext and Cogent foundations unchanged. Add meaningful Frappe application tests before building a release.\n'};
 for(const [path,content]of Object.entries(files))await writeFile(resolve(b.source,path),content,{flag:'wx'});await save(manifest,identity);
 return {status:'ready',...identity,sourceDirectory:b.source};
 });}
async function verifiedBase(b){const receipt=await json(resolve(b.root,'.coge/runtime/image.json'));if(!/^sha256:[a-f0-9]{64}$/.test(receipt.image)||receipt.sourceDigest!==b.plan.imageSourceDigest)throw Error('The installed foundation image is not verified.');
 const image=JSON.parse(await docker(['image','inspect',receipt.image]))[0];if(image.Config.Labels?.['com.cogentspec.erpnext.source']!==b.plan.imageSourceDigest)throw Error('The foundation image identity changed.');return {receipt,image};}
const coreGuard=`import pathlib,hashlib,json\ndef inventory():\n out=[]\n for app in ['frappe','erpnext','cogent_erp']:\n  root=pathlib.Path('apps')/app\n  for file in sorted(root.rglob('*')):\n   if any(p in ['node_modules','__pycache__','.git'] for p in file.parts):continue\n   if file.is_file() and not file.is_symlink():out.append([str(file),hashlib.sha256(file.read_bytes()).hexdigest()])\n return hashlib.sha256(json.dumps(out,separators=(',',':')).encode()).hexdigest()\n`;
export async function buildCustomerRelease(project,handoff,input){const b=await customerBinding(project,handoff);return locked(b,async()=>{
 if(!uuid(input.id)||!/^\d+\.\d+\.\d+$/.test(input.version)||!Number.isInteger(input.revision)||input.revision<1||input.workRevision!==b.work.updatedAt)throw Error('Choose a current versioned customer release.');
 await noLinks(b.root,b.source);const identity=await json(resolve(b.directory,'identity.json'));if(identity.customisationId!==b.work.id||identity.app!==b.app)throw Error('Initialise this customer layer first.');
 const inventory=await sourceInventory(b.source);if(!inventory.files.some(([path])=>path.startsWith(b.app+'/tests/test_')&&path.endsWith('.py')))throw Error('Add meaningful Frappe customer application tests before building.');
 const {receipt,image:base}=await verifiedBase(b),target=resolve(b.directory,'releases',input.id);await noLinks(b.root,target);if(await exists(target))throw Error('This release ID already exists.');await mkdir(resolve(target,'context'),{recursive:true});
 for(const [path]of inventory.files){const destination=resolve(target,'context',b.app,path);await mkdir(dirname(destination),{recursive:true});await writeFile(destination,await readFile(resolve(b.source,path)));}
 if((await sourceInventory(resolve(target,'context',b.app))).digest!==inventory.digest)throw Error('Customer source changed while it was being snapshotted.');
 const alias='cogent-vrc-base:'+receipt.image.slice(7);await docker(['tag',receipt.image,alias]);
 const before=coreGuard+"pathlib.Path('/tmp/cogent-foundation-digest').write_text(inventory())\n";
 const after=coreGuard+"assert inventory()==pathlib.Path('/tmp/cogent-foundation-digest').read_text(), 'Foundation source changed during customer build'\n";
 const pythonCommand=code=>`env/bin/python -c 'import base64;exec(base64.b64decode("${Buffer.from(code).toString('base64')}"))'`;
 const dependencyCheck=`import tomllib,pathlib\np=tomllib.loads(pathlib.Path('apps/${b.app}/pyproject.toml').read_text())['project']\nassert p.get('dependencies',[])==[], 'Customer dependencies require a separately reviewed offline bundle'\nassert p['version']==${JSON.stringify(input.version)}, 'Customer package version must match the release'\n`;
 const command=`set -e; node_dirs=(/home/frappe/.nvm/versions/node/*/bin); export PATH="\${node_dirs[0]}:$PATH"; ${pythonCommand(before)}; ${pythonCommand(dependencyCheck)}; env/bin/pip install --no-deps --no-build-isolation -e apps/${b.app}; printf '\\n${b.app}\\n' >> sites/apps.txt; bench build --app ${b.app} --production --force; ${pythonCommand(after)}`;
 const dockerfile=`FROM ${alias}\nUSER frappe\nWORKDIR /home/frappe/frappe-bench\nCOPY --chown=1000:0 ${b.app} apps/${b.app}\nRUN ["bash","-c",${JSON.stringify(command)}]\nLABEL com.cogentspec.customer.project="${project.id}" com.cogentspec.customer.runtime="${project.contractRuntimeId}" com.cogentspec.customer.work="${b.work.id}" com.cogentspec.customer.source="${inventory.digest}" com.cogentspec.customer.release="${input.id}" com.cogentspec.customer.base="${receipt.image}"\n`;
 await writeFile(resolve(target,'context/Dockerfile'),dockerfile);await docker(['build','--progress=plain','--pull=false','--network=none','--iidfile',resolve(target,'image.id'),resolve(target,'context')],{timeout:1200000,logPath:resolve(target,'build.log')});
 const imageId=(await readFile(resolve(target,'image.id'),'utf8')).trim(),image=JSON.parse(await docker(['image','inspect',imageId]))[0];
 if(!/^sha256:[a-f0-9]{64}$/.test(imageId)||!base.RootFS.Layers.every((layer,index)=>image.RootFS.Layers[index]===layer))throw Error('The customer image does not preserve the foundation layers.');
 const release={protocol:1,id:input.id,projectId:project.id,runtimeId:project.contractRuntimeId,customisationId:b.work.id,packId:project.packId,packVersion:project.packVersion,workRevision:b.work.updatedAt,selectedApps:b.work.selectedApps,app:b.app,version:input.version,revision:input.revision,sourceDigest:inventory.digest,baseImage:receipt.image,imageId,foundationSourceDigest:b.plan.sourceDigest,builtAt:new Date().toISOString()};
 await save(resolve(target,'release.json'),release);return {status:'built',...release};
 });}
async function readRelease(b,id){if(!uuid(id))throw Error('Choose a customer release.');await noLinks(b.root,resolve(b.directory,'releases',id,'release.json'));const release=await json(resolve(b.directory,'releases',id,'release.json'));
 if(release.id!==id||release.projectId!==b.project.id||release.runtimeId!==b.project.contractRuntimeId||release.customisationId!==b.work.id||release.packVersion!==b.project.packVersion||release.foundationSourceDigest!==b.plan.sourceDigest)throw Error('The customer release binding changed.');
 const {receipt,image:base}=await verifiedBase(b);if(receipt.image!==release.baseImage)throw Error('Customer release foundation changed.');const image=JSON.parse(await docker(['image','inspect',release.imageId]))[0],labels=image.Config.Labels||{};if(!base.RootFS.Layers.every((layer,index)=>image.RootFS.Layers[index]===layer))throw Error('Customer release foundation layers changed.');
 if(labels['com.cogentspec.customer.project']!==b.project.id||labels['com.cogentspec.customer.work']!==b.work.id||labels['com.cogentspec.customer.source']!==release.sourceDigest||labels['com.cogentspec.customer.release']!==id)throw Error('The customer image identity changed.');return release;
}
const result=output=>{const line=output.split('\n').findLast(line=>line.startsWith('COGENT_VRC='));if(!line)throw Error('A native customer release check did not return evidence.');return JSON.parse(line.slice(11));};
const baseLabels=b=>({'com.cogentspec.erpnext.project':b.project.id,'com.cogentspec.erpnext.root':b.plan.rootDigest});
async function assertResource(b,kind,name,releaseId){const data=JSON.parse(await docker([kind,'inspect',name]))[0],labels=data.Labels||data.Config?.Labels||{};for(const [key,value]of Object.entries(baseLabels(b)))if(labels[key]!==value)throw Error('An ERP resource belongs to another installation.');if(releaseId&&labels['com.cogentspec.customer.release']!==releaseId)throw Error('A customer release resource belongs to another operation.');return data;}
const composeArgs=(b,file,args)=>['compose','--project-name',b.plan.key,'-f',file,...args];
const siteSession="import frappe,json,pathlib,hashlib,os\nfrappe.init(site='cogent.local');frappe.connect();frappe.set_user('Administrator')\n";
const dataSnapshot=`def snapshot():\n result={}\n for table in sorted(frappe.db.get_tables()):\n  if table in ['tabSessions','tabError Log','tabAccess Log','tabActivity Log','tabScheduled Job Log','tabRoute History','tabConsole Log','tabPatch Log','tabVersion']:continue\n  rows=frappe.db.sql('select * from '+chr(96)+table.replace(chr(96),chr(96)*2)+chr(96))\n  values=sorted(json.dumps(row,default=str,separators=(',',':')) for row in rows)\n  result[table]=hashlib.sha256('\\n'.join(values).encode()).hexdigest()\n return result\n`;
async function python(b,file,code,mounts=[]){return result(await docker(composeArgs(b,file,['run','--rm','--no-deps','-T',...mounts,'--workdir','/home/frappe/frappe-bench/sites','backend','/home/frappe/frappe-bench/env/bin/python','-']),{input:code,timeout:900000,logPath:resolve(b.directory,'private-operation.log')}));}
export async function assertCustomerRuntime(project){
 const root=await safeRoot(project.targetPath),path=resolve(root,'.coge/customer-vrc/active.json');if(!await exists(path))return null;
 const active=await json(path),b=await customerBinding(project,active.binding),release=await readRelease(b,active.releaseId);
 if(hash(await readFile(resolve(root,'.coge/runtime/compose.json')))!==active.composeDigest||active.imageId!==release.imageId)throw Error('The active customer runtime configuration changed.');
 const config=await json(resolve(root,'.coge/runtime/compose.json'));for(const role of ['backend','worker','scheduler','websocket','frontend'])if(config.services[role].image!==release.imageId)throw Error('The active services do not match the customer release.');return active;
}
const writers=['backend','worker','scheduler','websocket'];
async function freeze(b){
 try{
  await compose(b,liveCompose(b),['stop','frontend','backend','scheduler','websocket'],{timeout:180000});
  for(let attempt=0;attempt<60;attempt++){
   const state=await python(b,liveCompose(b),siteSession+`from frappe.utils.background_jobs import get_queues\nfrom rq.registry import StartedJobRegistry,DeferredJobRegistry,ScheduledJobRegistry\nqueues=get_queues()\ncount=sum(q.count+sum(r(name=q.name,connection=q.connection).count for r in [StartedJobRegistry,DeferredJobRegistry,ScheduledJobRegistry]) for q in queues)\nfrappe.destroy();print('COGENT_VRC='+json.dumps({'pending':count}))\n`);
   if(state.pending===0){await compose(b,liveCompose(b),['stop','worker'],{timeout:180000});return;}
   await new Promise(done=>setTimeout(done,1000));
  }
  throw Error('Background work is still running. Retry when the ERP queue is empty.');
 }catch(error){await compose(b,liveCompose(b),['up','-d',...writers,'frontend'],{timeout:180000});throw error;}
}

const liveCompose=b=>resolve(b.root,'.coge/runtime/compose.json');
async function compose(b,file,args,options){return docker(composeArgs(b,file,args),{logPath:resolve(b.directory,'private-operation.log'),...options});}
const snapshotCode=`def protected_snapshot():\n tables={}\n modules=['CRM','Selling','Accounts','Buying','Stock','Manufacturing','Projects','Assets','Quality Management','Support']\n for app in frappe.get_installed_apps():\n  if app.startswith('customer_'):modules+=frappe.get_module_list(app)\n names=frappe.get_all('DocType',filters={'module':['in',modules],'issingle':0},pluck='name')\n names+=['__Auth']\n for name in sorted(set(names)):\n  table=name if name=='__Auth' else 'tab'+name\n  if table not in frappe.db.get_tables():continue\n  columns=frappe.db.get_table_columns(name if name!='__Auth' else '__Auth') if name!='__Auth' else [r[0] for r in frappe.db.sql('SHOW COLUMNS FROM '+chr(96)+table+chr(96))]\n  quoted=','.join(chr(96)+c.replace(chr(96),chr(96)*2)+chr(96) for c in columns)\n  rows=frappe.db.sql('SELECT '+quoted+' FROM '+chr(96)+table.replace(chr(96),chr(96)*2)+chr(96))\n  tables[table]={'columns':columns,'digest':hashlib.sha256('\\n'.join(sorted(json.dumps(r,default=str,separators=(',',':')) for r in rows)).encode()).hexdigest()}\n files={}\n for role in ['public/files','private/files']:\n  folder=pathlib.Path(frappe.get_site_path(role))\n  if folder.exists():\n   for path in sorted(folder.rglob('*')):\n    if path.is_symlink():raise Exception('Linked site files are unsupported')\n    if path.is_file():files[role+'/'+str(path.relative_to(folder))]=hashlib.sha256(path.read_bytes()).hexdigest()\n return {'tables':tables,'files':files,'encryptionKeyDigest':hashlib.sha256(str(frappe.conf.encryption_key).encode()).hexdigest()}\ndef assert_protected(expected):\n for table,entry in expected['tables'].items():\n  quoted=','.join(chr(96)+c.replace(chr(96),chr(96)*2)+chr(96) for c in entry['columns'])\n  rows=frappe.db.sql('SELECT '+quoted+' FROM '+chr(96)+table.replace(chr(96),chr(96)*2)+chr(96))\n  digest=hashlib.sha256('\\n'.join(sorted(json.dumps(r,default=str,separators=(',',':')) for r in rows)).encode()).hexdigest()\n  assert digest==entry['digest'],'Existing business records or credentials changed: '+table\n current=protected_snapshot()\n assert current['files']==expected['files'],'Uploaded files changed'\n assert current['encryptionKeyDigest']==expected['encryptionKeyDigest'],'Encryption configuration changed'\n`;
async function volume(b,name,id){if(await docker(['volume','ls','-q','--filter','name=^'+name+'$'])){await assertResource(b,'volume',name,id);return;}
 const labels={...baseLabels(b),'com.cogentspec.customer.release':id};await docker(['volume','create',...Object.entries(labels).flatMap(([k,v])=>['--label',k+'='+v]),name]);}
async function privateBackup(b,release){
 const id=randomUUID(),name=b.plan.key+'-vrc-backup-'+id.replaceAll('-','').slice(0,12);await volume(b,name,release.id);
 const current=await json(liveCompose(b));
 // The configuration is cloned volume-to-volume; credentials never cross the host or argv.
 await docker(['run','-i','--rm','--pull','never','--network','none','--user','0','--entrypoint','/home/frappe/frappe-bench/env/bin/python','--mount','type=volume,source='+name+',target=/backup',release.baseImage,'-'],{input:"import pathlib,os\np=pathlib.Path('/backup');os.chown(p,1000,0);p.chmod(0o700)\n"});
 const code=siteSession+snapshotCode+`from frappe.utils.backups import new_backup\nimport shutil\nsnapshot=protected_snapshot()\nbackup=new_backup(ignore_files=False,force=True)\nroles={}\nfor role,path in {'database':backup.backup_path_db,'public':backup.backup_path_files,'private':backup.backup_path_private_files,'config':backup.backup_path_conf}.items():\n file=pathlib.Path(path);name=role+''.join(file.suffixes);target=pathlib.Path('/backup')/name;shutil.copyfile(file,target);target.chmod(0o600);roles[role]=name\nmanifest={'protocol':1,'projectId':${JSON.stringify(b.project.id)},'runtimeId':${JSON.stringify(b.project.contractRuntimeId)},'releaseId':${JSON.stringify(release.id)},'snapshot':snapshot,'roles':roles}\nmanifest['digests']={name:hashlib.sha256((pathlib.Path('/backup')/name).read_bytes()).hexdigest() for name in roles.values()}\n(pathlib.Path('/backup')/'manifest.json').write_text(json.dumps(manifest));(pathlib.Path('/backup')/'manifest.json').chmod(0o600)\nfrappe.destroy();print('COGENT_VRC='+json.dumps({'backupVerified':True,'roles':list(roles),'snapshotDigest':hashlib.sha256(json.dumps(snapshot,sort_keys=True).encode()).hexdigest()}))\n`;
 const receipt=await python(b,liveCompose(b),code,['--volume',name+':/backup']);return {volume:name,id,...receipt,compose:current};
}
async function cloneConfiguration(b,release,configVolume,sourceConfig){
 await docker(['run','-i','--rm','--pull','never','--network','none','--user','0','--entrypoint','/home/frappe/frappe-bench/env/bin/python','--mount','type=volume,source='+sourceConfig+',target=/source,readonly','--mount','type=volume,source='+configVolume+',target=/target',release.baseImage,'-'],{input:"import pathlib,shutil,os\nsource=pathlib.Path('/source');target=pathlib.Path('/target');os.chown(target,1000,0)\nfor name in ['database-password','identity.json']:\n path=target/name;shutil.copyfile(source/name,path);path.chmod(0o400);os.chown(path,1000,0)\n"});
}
async function verificationSite(b,release,backup,{runTests=true}={}){
 const prefix=b.plan.key+'-vrc-'+release.id.replaceAll('-','').slice(0,12)+'-'+randomUUID().slice(0,8),document=structuredClone(backup.compose),resources=[];
 for(const [role,definition]of Object.entries(document.volumes)){const name=prefix+'-'+role;await volume(b,name,release.id);definition.name=name;resources.push(name);}
 const labels={...baseLabels(b),'com.cogentspec.customer.release':release.id};
 for(const [role,service]of Object.entries(document.services)){service.labels=labels;service.restart='no';if(['backend','worker','scheduler','websocket','frontend'].includes(role))service.image=release.imageId;if(role==='frontend')service.ports=['127.0.0.1::8080'];}
 for(const [role,network]of Object.entries(document.networks)){network.name=prefix+'-'+role;network.labels=labels;}
 const file=resolve(b.directory,'releases',release.id,'verify-'+prefix.slice(-8)+'.json');await save(file,document);
 const args=extra=>['compose','--project-name',prefix,'-f',file,...extra];
 const run=(extra,options)=>docker(args(extra),{logPath:resolve(b.directory,'private-operation.log'),...options});
 const site={prefix,file,document,resources};await save(resolve(b.directory,'releases',release.id,'verification-active.json'),site);
 try{
 await cloneConfiguration(b,release,document.volumes.config.name,backup.compose.volumes.config.name);
 await docker(['run','-i','--rm','--pull','never','--network','none','--user','0','--entrypoint','/home/frappe/frappe-bench/env/bin/python','--mount','type=volume,source='+document.volumes.sites.name+',target=/sites','--mount','type=volume,source='+document.volumes.logs.name+',target=/logs',release.imageId,'-'],{input:"import os\nos.chown('/sites',1000,0);os.chown('/logs',1000,0)\n"});
 await docker(args(['up','-d','--wait','--wait-timeout','180','database','cache','queue']),{timeout:240000});
 const restore=`import frappe,json,pathlib,secrets,hashlib\nfrom frappe.installer import _new_site,extract_files\np=pathlib.Path('.')\n(p/'common_site_config.json').write_text(json.dumps({'db_host':'database','db_port':3306,'redis_cache':'redis://cache:6379','redis_queue':'redis://queue:6379','redis_socketio':'redis://queue:6379','socketio_port':9000,'serve_default_site':True}))\n(p/'apps.txt').write_text('frappe\\nerpnext\\ncogent_erp\\n${release.app}\\n')\nmanifest=json.loads(pathlib.Path('/backup/manifest.json').read_text())\nassert manifest['projectId']==${JSON.stringify(b.project.id)} and manifest['runtimeId']==${JSON.stringify(b.project.contractRuntimeId)}\nfor name,digest in manifest['digests'].items():assert hashlib.sha256((pathlib.Path('/backup')/name).read_bytes()).hexdigest()==digest\nfrappe.init(site='cogent.local',new_site=True)\n_new_site(None,'cogent.local',db_root_username='root',db_root_password=pathlib.Path('/run/cogent/database-password').read_text(),admin_password=secrets.token_urlsafe(48),source_sql='/backup/'+manifest['roles']['database'],install_apps=['erpnext','cogent_erp'],mariadb_user_host_login_scope='%')\nfrappe.destroy()\nconfig=pathlib.Path('cogent.local/site_config.json');settings=json.loads(config.read_text());original=json.loads((pathlib.Path('/backup')/manifest['roles']['config']).read_text())\nfor key,value in original.items():\n if key not in ['db_name','db_password','db_user','db_host','db_port','db_type','redis_cache','redis_queue','redis_socketio']:settings[key]=value\nsettings['allow_tests']=True;settings['pause_scheduler']=True;config.write_text(json.dumps(settings));config.chmod(0o600)\nfor role in ['public','private']:extract_files('cogent.local','/backup/'+manifest['roles'][role])\nfrappe.init(site='cogent.local');frappe.connect();frappe.set_user('Administrator')\n`+snapshotCode+`assert_protected(manifest['snapshot'])\nfrappe.destroy();print('COGENT_VRC='+json.dumps({'restoreVerified':True,'credentialsPreserved':True,'filesPreserved':True,'businessRecordsPreserved':True}))\n`;
 const receipt=result(await run(['run','--rm','--no-deps','-T','--volume',backup.volume+':/backup:ro','--workdir','/home/frappe/frappe-bench/sites','backend','/home/frappe/frappe-bench/env/bin/python','-'],{input:restore,timeout:900000}));
 // Native Frappe installation, migrations and test discovery; never a simulated check.
 const installed=result(await run(['run','--rm','--no-deps','-T','--workdir','/home/frappe/frappe-bench/sites','backend','/home/frappe/frappe-bench/env/bin/python','-'],{input:siteSession+`print('COGENT_VRC='+json.dumps({'installed':${JSON.stringify(release.app)} in frappe.get_installed_apps()}));frappe.destroy()\n`}));
 if(!installed.installed)await run(['run','--rm','--no-deps','-T','backend','bench','--site','cogent.local','install-app',release.app],{timeout:900000});
 await run(['run','--rm','--no-deps','-T','backend','bench','--site','cogent.local','migrate'],{timeout:900000});
 let testCount=0;
 if(runTests){
  const output=await run(['run','--rm','--no-deps','-T','backend','bench','--site','cogent.local','run-tests','--app',release.app],{timeout:900000,captureStderr:true});
  const counts=[...output.matchAll(/Ran (\d+) tests? in /g)].map(match=>Number(match[1]));testCount=counts.reduce((sum,n)=>sum+n,0);
  const skipped=[...output.matchAll(/OK \(skipped=(\d+)\)/g)].reduce((sum,match)=>sum+Number(match[1]),0);
  if(!testCount||skipped>=testCount||!/^OK(?:\s|$)/m.test(output)||/^FAILED(?:\s|$)/m.test(output))throw Error('Customer application tests did not execute successfully.');
 }
 const after=result(await run(['run','--rm','--no-deps','-T','--volume',backup.volume+':/backup:ro','--workdir','/home/frappe/frappe-bench/sites','backend','/home/frappe/frappe-bench/env/bin/python','-'],{input:siteSession+snapshotCode+`manifest=json.loads(pathlib.Path('/backup/manifest.json').read_text());assert_protected(manifest['snapshot'])\nconfig=pathlib.Path('cogent.local/site_config.json');settings=json.loads(config.read_text());settings['allow_tests']=False;config.write_text(json.dumps(settings));config.chmod(0o600)\nfrappe.db.commit();frappe.destroy();print('COGENT_VRC='+json.dumps({'migrationVerified':True,'nativeTestsPassed':${runTests?'True':'False'},'credentialsPreserved':True,'filesPreserved':True,'businessRecordsPreserved':True}))\n`}));
 return {...site,receipt:{...receipt,...after,nativeTestCount:testCount}};
 }catch(error){await cleanupVerification(b,release,site).catch(()=>{});throw error;}
}
async function cleanupVerification(b,release,site,{keepVolumes=false}={}){
 if(!site)return;await docker(['compose','--project-name',site.prefix,'-f',site.file,'down','--remove-orphans'],{timeout:180000});
 if(!keepVolumes)for(const name of site.resources){await assertResource(b,'volume',name,release.id);await docker(['volume','rm',name]);}
}
export async function verifyCustomerRelease(project,handoff,id){const b=await customerBinding(project,handoff);return locked(b,async()=>{
 const release=await readRelease(b,id);if(release.workRevision!==b.work.updatedAt||(await sourceInventory(b.source)).digest!==release.sourceDigest)throw Error('Customer source or brief changed. Build a new release.');
 await assertLiveOwnership(b);let backup,site;await freeze(b);
 try{backup=await privateBackup(b,release);}finally{await compose(b,liveCompose(b),['up','-d',...writers],{timeout:180000});await compose(b,liveCompose(b),['restart','frontend']);}
 try{site=await verificationSite(b,release,backup);const proof={...release,status:'verified',backupVolume:backup.volume,backupSnapshotDigest:backup.snapshotDigest,...site.receipt,verifiedAt:new Date().toISOString()};await save(resolve(b.directory,'releases',id,'verification.json'),proof);return proof;}
 finally{await cleanupVerification(b,release,site);}
 });}
async function assertLiveOwnership(b){const document=await json(liveCompose(b));
 for(const definition of Object.values(document.volumes))await assertResource(b,'volume',definition.name);
 for(const [role,service]of Object.entries(document.services))for(const [key,value]of Object.entries(baseLabels(b)))if(service.labels?.[key]!==value)throw Error('Live service '+role+' belongs to another installation.');
 return document;
}
async function waitNativeHealth(b){for(let attempt=0;attempt<90;attempt++){try{const value=await b.runtime.inspect();if(value.ready)return value;}catch{}await new Promise(done=>setTimeout(done,1000));}throw Error('The deployed ERP did not pass its exact installation health check.');}
async function restoreOriginalFlags(b,file,backup){return python(b,file,siteSession+`original=json.loads((pathlib.Path('/backup')/json.loads(pathlib.Path('/backup/manifest.json').read_text())['roles']['config']).read_text())\npath=pathlib.Path('cogent.local/site_config.json');settings=json.loads(path.read_text())\nfor key,default in [('allow_tests',False),('pause_scheduler',False),('maintenance_mode',0)]:settings[key]=original.get(key,default)\npath.write_text(json.dumps(settings));path.chmod(0o600);frappe.destroy();print('COGENT_VRC='+json.dumps({'flagsRestored':True}))\n`,['--volume',backup.volume+':/backup:ro']);}
async function rollbackDigest(b){return python(b,liveCompose(b),siteSession+snapshotCode+`value=protected_snapshot()\nfor name in ['User','Has Role','User Permission','Custom Field','Property Setter','Workflow','Workflow Document State','Workflow Transition','Print Format','Client Script','Server Script','Custom DocPerm','DocPerm']:\n table='tab'+name\n if table not in frappe.db.get_tables():continue\n columns=[c for c in frappe.db.get_table_columns(name) if name!='User' or c not in ['last_login','last_active','last_ip']]\n quoted=','.join(chr(96)+c.replace(chr(96),chr(96)*2)+chr(96) for c in columns)\n rows=frappe.db.sql('SELECT '+quoted+' FROM '+chr(96)+table+chr(96))\n value['tables'][table]={'columns':columns,'digest':hashlib.sha256('\\n'.join(sorted(json.dumps(r,default=str,separators=(',',':')) for r in rows)).encode()).hexdigest()}\nfor app in frappe.get_installed_apps():\n if not app.startswith('customer_'):continue\n for module in frappe.get_module_list(app):\n  for name in frappe.get_all('DocType',filters={'module':module,'issingle':0},pluck='name'):\n   table='tab'+name\n   if table not in frappe.db.get_tables():continue\n   rows=frappe.db.sql('SELECT * FROM '+chr(96)+table.replace(chr(96),chr(96)*2)+chr(96))\n   value['tables'][table]={'digest':hashlib.sha256('\\n'.join(sorted(json.dumps(r,default=str,separators=(',',':')) for r in rows)).encode()).hexdigest()}\nfrappe.destroy();print('COGENT_VRC='+json.dumps({'digest':hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()}))\n`);}
export async function deployCustomerRelease(project,handoff,grant,authorize=async()=>{throw Error('Use the authorised customer release worker.');}){const b=await customerBinding(project,handoff);return locked(b,async()=>{
 await authorize();
 const release=await readRelease(b,grant.id),verification=await json(resolve(b.directory,'releases',release.id,'verification.json'));
 if(grant.state!=='deploying'||!uuid(grant.claim)||grant.work_revision!==b.work.updatedAt||grant.proof?.imageId!==release.imageId||grant.proof?.sourceDigest!==release.sourceDigest||verification.nativeTestsPassed!==true||(await sourceInventory(b.source)).digest!==release.sourceDigest)throw Error('An exact, current server-approved customer deployment is required.');
 const previous=await assertLiveOwnership(b),previousBytes=await readFile(liveCompose(b)),activePath=resolve(b.directory,'active.json'),previousActive=await exists(activePath)?await json(activePath):null;
 let backup,checked,clean,switched=false,opened=false;
 await freeze(b);
 try{
  backup=await privateBackup(b,release);
  checked=await verificationSite(b,release,backup);await cleanupVerification(b,release,checked);checked=null;
  // Deploy a separate clean restored copy. Test data can never enter production.
  clean=await verificationSite(b,release,backup,{runTests:false});await restoreOriginalFlags(b,clean.file,backup);
  await cleanupVerification(b,release,clean,{keepVolumes:true});
  const candidate=clean.document;for(const service of Object.values(candidate.services))service.restart='unless-stopped';
  await save(resolve(b.directory,'releases',release.id,'recovery.json'),{previousCompose:previous,previousActive,backupVolume:backup.volume,liveDataReplaced:false});
  await authorize();await save(liveCompose(b),candidate);switched=true;
  await compose(b,liveCompose(b),['up','-d','--wait','--wait-timeout','180','database','cache','queue'],{timeout:240000});
  await compose(b,liveCompose(b),['up','-d','backend','websocket'],{timeout:180000});
  // Check the native API inside the private network before exposing the frontend.
  const probe=`import time,urllib.request,json\nfor attempt in range(90):\n try:\n  request=urllib.request.Request('http://backend:8000/api/method/cogent_erp.api.health',headers={'Host':'cogent.local'});value=json.load(urllib.request.urlopen(request,timeout=3))['message']\n  assert value['projectId']==${JSON.stringify(project.id)} and value['runtimeId']==${JSON.stringify(project.contractRuntimeId)} and value['ready']\n  print('COGENT_VRC='+json.dumps({'ready':True}));break\n except Exception:time.sleep(1)\nelse:raise Exception('Native customer health check failed')\n`;
  await python(b,liveCompose(b),probe);
  const baseline=await rollbackDigest(b);
  const active={protocol:1,releaseId:release.id,imageId:release.imageId,composeDigest:hash(await readFile(liveCompose(b))),binding:b.work,rollbackDigest:baseline.digest,activatedAt:new Date().toISOString()};await save(activePath,active);
  await authorize();await compose(b,liveCompose(b),['up','-d','worker','scheduler','frontend'],{timeout:180000});opened=true;await waitNativeHealth(b);
  const proof={...release,previousReleaseId:previousActive?.releaseId||null,deployed:true,healthVerified:true,restoreVerified:true,migrationVerified:true,businessRecordsPreserved:true,credentialsPreserved:true,filesPreserved:true,cleanProductionCopy:true,deployedAt:new Date().toISOString()};await save(resolve(b.directory,'releases',release.id,'deployment.json'),proof);return proof;
 }catch(error){
  await compose(b,liveCompose(b),['stop','frontend',...writers],{timeout:180000}).catch(()=>{});
  if(opened){const active=await json(activePath),current=await rollbackDigest(b);if(current.digest!==active.rollbackDigest)throw Error('Deployment needs recovery review: post-release data changed. Both data copies and the recovery journal have been retained.');}
  if(switched)await writeFile(liveCompose(b),previousBytes);
  if(previousActive)await save(activePath,previousActive);else if(await exists(activePath))await unlink(activePath);
  await compose(b,liveCompose(b),['up','-d','database','cache','queue',...writers,'frontend'],{timeout:240000});throw error;
 }finally{await cleanupVerification(b,release,checked).catch(()=>{});if(clean&&!switched)await cleanupVerification(b,release,clean).catch(()=>{});}
 });}
export async function rollbackCustomerRelease(project,handoff,grant,authorize=async()=>{throw Error('Use the authorised customer release worker.');}){const b=await customerBinding(project,handoff);return locked(b,async()=>{
 await authorize();
 const active=await assertCustomerRuntime(project),release=await readRelease(b,grant.id);if(!active||active.releaseId!==grant.id||grant.state!=='rolling_back'||!uuid(grant.claim))throw Error('Approve rollback of the currently installed customer release.');
 await assertLiveOwnership(b);await freeze(b);
 try{
  if((await rollbackDigest(b)).digest!==active.rollbackDigest)throw Object.assign(Error('Business or configuration records changed after deployment. Automatic rollback is blocked; review recovery to preserve those changes.'),{code:'rollback_data_changed'});
  const recovery=await json(resolve(b.directory,'releases',release.id,'recovery.json'));for(const volume of Object.values(recovery.previousCompose.volumes))await assertResource(b,'volume',volume.name);
  await save(liveCompose(b),recovery.previousCompose);if(recovery.previousActive)await save(resolve(b.directory,'active.json'),recovery.previousActive);else await unlink(resolve(b.directory,'active.json'));
  await compose(b,liveCompose(b),['up','-d','database','cache','queue',...writers,'frontend'],{timeout:240000});await waitNativeHealth(b);
  return {...release,rolledBack:true,businessRecordsPreserved:true,credentialsPreserved:true,filesPreserved:true};
 }catch(error){await compose(b,liveCompose(b),['up','-d',...writers,'frontend'],{timeout:180000});throw error;}
 });}
