// Real generated-page event handlers in a deliberately minimal DOM harness.
// This is not browser, download-manager, CSP-enforcement, or containment evidence.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {generateHtml,requestAuthoringRuntime} from '../tools/grant-request-form.mjs';

class Element {
  constructor(tag,doc) { this.tagName=tag;this.doc=doc;this.children=[];this.listeners={};this.value='';this.textContent='';this.disabled=false;this.files=[];this.attributes={}; }
  // Model HTML text-input CR/LF sanitization; this is not actual browser evidence.
  set value(value) { this._value=this.tagName==='input' && this.type==='text' ? String(value).replace(/[\r\n]/g,'') : String(value); }
  get value() { return this._value; }
  set innerHTML(_) { throw Error('Unsafe innerHTML use'); }
  setAttribute(key,value) { this.attributes[key]=value; }
  append(...children) { for(const child of children){child.parent=this;this.children.push(child);} }
  replaceChildren(...children) { this.children.forEach(x=>x.parent=null);this.children=[];this.append(...children); }
  remove() { if(this.parent){this.parent.children=this.parent.children.filter(x=>x!==this);this.parent=null;} }
  addEventListener(type,handler) { (this.listeners[type] ||= []).push(handler); }
  async fire(type) { for(const handler of this.listeners[type] || []) await handler({target:this,preventDefault(){}}); }
  click() { if(this.tagName==='a')this.doc.downloads.push({href:this.href,name:this.download});else return this.fire('click'); }
}
const html=generateHtml();
const script=html.match(/<script>([\s\S]*)<\/script>/)[1];
const now={value:Date.now()};
function harness() {
  const doc={downloads:[],elements:{},getElementById(id){assert.ok(this.elements[id],'HTML id '+id);return this.elements[id];},createElement(tag){return new Element(tag,this);}};
  doc.body=doc.createElement('body');
  for(const match of html.matchAll(/\bid="([^"]+)"/g))doc.elements[match[1]]=doc.createElement('div');
  const blobs=new Map(),revoked=[],timers=[];
  const urls={createObjectURL(blob){const id='blob:test-'+blobs.size;blobs.set(id,blob);return id;},revokeObjectURL(id){revoked.push(id);}};
  const context=vm.createContext({document:doc,TextEncoder,Blob,URL:urls,Date:{now:()=>now.value},setTimeout:fn=>timers.push(fn)});
  vm.runInContext(script,context,{timeout:1000});
  return {doc,blobs,revoked,timers,get:id=>doc.getElementById(id),async pick(raw,{size,reader}={}){const f=this.get('template-file');f.files=[{size:size??Buffer.byteLength(raw),text:reader??(()=>Promise.resolve(raw))}];await f.fire('change');},async open(request){await this.pick(typeof request==='string'?request:JSON.stringify(request));await this.get('open').click();},field(name){const row=this.get('fields').children.find(x=>x.children[0].textContent===name);assert.ok(row,'field '+name);return row.children[1];},args(){return this.get('arguments').children.map(row=>row.children[0].children[1]);},async edit(name,value){const input=this.field(name);input.value=value;await input.fire('input');},async preview(){await this.get('preview').click();return this.get('preview-json').textContent;},async download(){const previous=this.doc.downloads.length;await this.get('download').click();if(this.doc.downloads.length===previous)return null;const download=this.doc.downloads.at(-1);return {text:await this.blobs.get(download.href).text(),...download};}};
}
function fixture() {
  return {protocol_version:3,grant:{protocol_version:3,approval_id:'synthetic-request-authoring',request_id:'request-authoring',workspace_id:'demo',backend:'LocalOs',enforcement_requirement:'AllowDegraded',network:'Deny',allowed_egress:[],allowed_commands:['probe'],limits:{wall_clock_ms:2000,cpu_seconds:1,memory_mib:128,disk_mib:16,processes:16,output_bytes:8192},working_directory:'',command:['Exec',{tool:'probe',args:['two words','','line\nnext','\r\n','"quoted"','雪 🚀']}],backend_config_id:'local',expires_at_ms:String(now.value+300000)}};
}
let checks=0;
async function test(name,fn){await fn();checks++;console.log('PASS '+name);}
const runtime=requestAuthoringRuntime(), h=harness();
await test('initial page cannot preview/download; no template auto-read',async()=> {
  assert.equal(h.get('download').disabled,true);assert.equal(await h.download(),null);
  let reads=0;await h.pick(JSON.stringify(fixture()),{reader:()=>{reads++;return Promise.resolve(JSON.stringify(fixture()));}});assert.equal(reads,0);
  await h.get('open').click();assert.equal(reads,1);assert.equal(h.doc.downloads.length,0);
});
await test('generated script/styles have exact CSP hashes and no network paths',()=> {
  const sha=s=>createHash('sha256').update(s).digest('base64');
  assert.ok(html.includes("script-src 'sha256-"+sha(script)+"'"));assert.ok(html.includes("style-src 'sha256-"+sha(html.match(/<style>([\s\S]*)<\/style>/)[1])+"'"));
  assert.ok(html.includes("connect-src 'none'"));assert.ok(!/\b(fetch|XMLHttpRequest|WebSocket|localStorage|sessionStorage|indexedDB)\b/.test(script));
});
await test('unmodified template round-trips exact v3 shape, argument boundaries and decimal string',async()=> {
  const template=fixture();await h.open(template);const preview=await h.preview();assert.deepEqual(JSON.parse(preview),template);
  const download=await h.download();assert.equal(download.name,'moonfort-request.json');assert.equal(download.text,preview);assert.equal(h.blobs.get(download.href).type,'application/json');
  h.timers.splice(0).forEach(fn=>fn());assert.ok(h.revoked.includes(download.href));
});
await test('JSON-string directory editing preserves CR LF tabs Unicode and escapes under text-input sanitization',async()=> {
  for (const directory of ['src\r\nreview','src\rreview','src\nreview','src\treview','雪/\"quoted\"\\path','']) {
    const f=fixture();f.grant.working_directory=directory;await h.open(f);
    assert.equal(h.field('working_directory').value,JSON.stringify(directory));
    assert.deepEqual(JSON.parse(await h.preview()),f);assert.deepEqual(JSON.parse((await h.download()).text),f);
    const edited=directory+'suffix';await h.edit('working_directory',JSON.stringify(edited));assert.equal(h.get('download').disabled,true);
    assert.equal(JSON.parse(await h.preview()).grant.working_directory,edited);assert.equal(JSON.parse((await h.download()).text).grant.working_directory,edited);
    await h.get('reset').click();assert.equal(h.field('working_directory').value,JSON.stringify(directory));assert.equal(h.get('preview-json').textContent,'');
  }
  for(const invalid of ['src','null','123','[]','{\"directory\":\"src\"}']){await h.edit('working_directory',invalid);assert.equal(await h.preview(),'');assert.equal(await h.download(),null);assert.match(h.get('status').textContent,/JSON string/);}
});
await test('individual argument edit/add/remove preserves spaces empty strings and Unicode',async()=> {
  await h.open(fixture());
  h.args()[0].value=JSON.stringify('  one argument  ');await h.args()[0].fire('input');assert.equal(h.get('download').disabled,true);
  await h.get('add-argument').click();assert.equal(h.args().at(-1).value,'""');
  const rows=h.get('arguments').children;await rows[1].children[1].click();
  assert.equal(h.get('arguments').children[1].children[0].children[0].textContent,'Argument 1 (JSON string)');
  const request=JSON.parse(await h.preview());assert.deepEqual(request.grant.command[1].args,['  one argument  ','line\nnext','\r\n','"quoted"','雪 🚀','']);
});
await test('workspace expiry and all six resource fields edit without policy mutation',async()=> {
  const fixed=fixture().grant;await h.open({protocol_version:3,grant:fixed});
  await h.edit('approval_id','edited-approval');await h.edit('request_id','edited-request');await h.edit('workspace_id','other-workspace');await h.edit('working_directory',JSON.stringify('src/check'));await h.edit('expires_at_ms','9223372036854775807');
  for(const key of Object.keys(fixed.limits))await h.edit('limits.'+key,'42');
  const edited=JSON.parse(await h.preview()).grant;
  assert.equal(edited.expires_at_ms,'9223372036854775807');assert.equal(edited.workspace_id,'other-workspace');assert.equal(edited.working_directory,'src/check');
  for(const key of Object.keys(fixed.limits))assert.equal(edited.limits[key],42);
  for(const key of ['backend','backend_config_id','enforcement_requirement','network','allowed_egress','allowed_commands'])assert.deepEqual(edited[key],fixed[key]);
  assert.ok(h.get('authority').textContent.includes('AllowDegraded'));
});
await test('preview invalidates on input and detects changed controls even without input event',async()=> {
  await h.edit('workspace_id','demo');assert.equal(h.get('preview-json').textContent,'');assert.equal(await h.download(),null);
  await h.preview();h.field('request_id').value='unannounced-change';assert.equal(await h.download(),null);assert.match(h.get('status').textContent,/stale/);
});
await test('expired preview cannot download; expiry uses Int64 without precision loss',async()=> {
  const f=fixture();f.grant.expires_at_ms=String(now.value+1);await h.open(f);await h.preview();now.value+=2;
  assert.equal(await h.download(),null);assert.match(h.get('status').textContent,/expired/);
  for(const invalid of [9223372036854775807,'9223372036854775808','1e15','1.0','01','-1',' 10','']){const x=fixture();x.grant.expires_at_ms=invalid;assert.throws(()=>runtime.validate(x),/decimal string/);}
});
await test('reset restores exact template and revokes preview; zero arguments stay zero',async()=> {
  const f=fixture();f.grant.command[1].args=[];await h.open(f);await h.get('add-argument').click();await h.edit('workspace_id','changed');await h.preview();await h.get('reset').click();
  assert.equal(h.args().length,0);assert.equal(h.get('preview-json').textContent,'');assert.equal(h.get('download').disabled,true);assert.deepEqual(JSON.parse(await h.preview()),f);
});
await test('cancel clears template preview fields and blocks repeated download',async()=> {
  await h.get('cancel').click();assert.equal(h.get('fields').children.length,0);assert.equal(h.get('arguments').children.length,0);assert.equal(h.get('authority').textContent,'');
  assert.equal(h.get('editor').disabled,true);assert.equal(h.get('template-file').value,'');assert.equal(await h.download(),null);await h.get('cancel').click();assert.equal(await h.download(),null);
});
await test('canceled asynchronous read never resurrects a draft',async()=> {
  let resolve;await h.pick('{}',{reader:()=>new Promise(r=>resolve=r)});const opening=h.get('open').click();await h.get('cancel').click();resolve(JSON.stringify(fixture()));await opening;
  assert.equal(h.get('fields').children.length,0);assert.equal(await h.download(),null);
});
await test('newer selection/open wins over an older read completion',async()=> {
  let resolve;await h.pick('{}',{reader:()=>new Promise(r=>resolve=r)});const older=h.get('open').click();
  const next=fixture();next.grant.workspace_id='newest';await h.open(next);resolve(JSON.stringify(fixture()));await older;
  assert.equal(h.field('workspace_id').value,'newest');
});
await test('failed or oversized replacement discards prior preview',async()=> {
  await h.preview();await h.open('{');assert.equal(h.get('fields').children.length,0);assert.equal(await h.download(),null);
  let read=false;await h.pick('{}',{size:65537,reader:()=>{read=true;return Promise.resolve('{}');}});await h.get('open').click();assert.equal(read,false);assert.match(h.get('status').textContent,/64 KiB/);
  await h.pick('{}',{reader:()=>Promise.reject(Error('synthetic read failure'))});await h.get('open').click();assert.match(h.get('status').textContent,/read failure/);
});
await test('HTML/script-looking input stays inert text and downloads exactly',async()=> {
  const f=fixture(), attack='</script><img src=x onerror="throw 1"><script>fetch("https://example.test")</script>';
  f.grant.command[1].args=[attack,'\\','\t','\r','a\u2028b'];await h.open(f);assert.deepEqual(JSON.parse(await h.preview()),f);assert.deepEqual(JSON.parse((await h.download()).text),f);
  assert.equal(h.get('preview-json').children.length,0);
});
await test('invalid argument JSON, scalar types and NUL cannot produce a download',async()=> {
  await h.open(fixture());for(const invalid of ['no quotes','[]','123','null','"\\u0000"','"\\ud800"']){h.args()[0].value=invalid;await h.args()[0].fire('input');await h.preview();assert.equal(await h.download(),null);}
});
await test('resource, identifier and relative-directory invalid edits fail closed',async()=> {
  await h.open(fixture());
  for(const value of ['0','-1','1.5','1e3',' 12','2147483648','999999999999999999']){await h.edit('limits.memory_mib',value);assert.equal(await h.preview(),'');}
  await h.get('reset').click();
  for(const value of ['/tmp','../outside','a//b','a/../b','a/','./x']){await h.edit('working_directory',JSON.stringify(value));assert.equal(await h.preview(),'');}
  await h.get('reset').click();await h.edit('workspace_id','../../host');assert.equal(await h.preview(),'');
});
await test('templates reject omitted explicit authority, extra fields, wrong types and Shell',()=> {
  const mutations=[x=>delete x.grant.backend,x=>delete x.grant.enforcement_requirement,x=>x.protocol_version=4,x=>x.grant.protocol_version=2,x=>x.grant.backend='Unavailable',x=>x.grant.enforcement_requirement='',x=>x.grant.network='Guess',x=>x.approved=true,x=>x.grant.host_path='/private',x=>x.grant.command=['Shell',{script:'echo wrong'}],x=>x.grant.command[1].tool='shell-compat',x=>x.grant.command[1].args='joined string',x=>x.grant.allowed_commands=['other'],x=>x.grant.allowed_commands.push('probe'),x=>x.grant.limits.memory_mib='128',x=>x.grant.limits.extra=1];
  for(const mutate of mutations){const x=fixture();mutate(x);assert.throws(()=>runtime.validate(x));}
  assert.throws(()=>runtime.parse(JSON.stringify(fixture().grant)));assert.throws(()=>runtime.parse('{"protocol_version":3,"grant":null}'));
});
await test('argument count and output byte budgets are enforced without truncation',async()=> {
  const f=fixture();f.grant.command[1].args=Array(256).fill('');await h.open(f);await h.get('add-argument').click();assert.equal(h.args().length,256);assert.match(h.get('status').textContent,/256/);
  const tooMany=fixture();tooMany.grant.command[1].args=Array(257).fill('');assert.throws(()=>runtime.validate(tooMany),/256/);
  const huge=fixture();huge.grant.command[1].args=['a'.repeat(65536)];assert.throws(()=>runtime.validate(huge),/64 KiB/);
});
await test('strict MicroVm template stays strict with explicit policy unchanged',async()=> {
  const f=fixture();Object.assign(f.grant,{backend:'MicroVm',backend_config_id:'production',enforcement_requirement:'RequireEnforced',network:'AllowList',allowed_egress:['https://example.invalid']});
  await h.open(f);assert.deepEqual(JSON.parse(await h.preview()),f);assert.ok(h.get('authority').textContent.includes('RequireEnforced'));
});
await test('repeated explicit download is byte-identical; reset invalidates it',async()=> {
  const first=await h.download(),second=await h.download();assert.equal(first.text,second.text);await h.get('reset').click();assert.equal(await h.download(),null);
});

if(process.argv[2]) {
  const binary=path.resolve(process.argv[2]);assert.ok(fs.statSync(binary).isFile());
  // run-focused.sh verifies the exact retained native source/binary closure before this test.
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'grant-authoring-'));fs.chmodSync(root,0o700);
  const dir=name=>{const p=path.join(root,name);fs.mkdirSync(p,{recursive:true,mode:0o700});return fs.realpathSync(p);};
  const approval=dir('approval'),scratch=dir('scratch'),retention=dir('retention'),workspace=dir('workspace');
  dir('approval/pending');dir('approval/consumed');dir('retention/output-artifacts');dir('retention/live-output');
  const sentinel=path.join(root,'PROCESS_STARTED'),tool=path.join(root,'synthetic-probe');
  fs.writeFileSync(tool,'#!/bin/sh\nprintf unexpected > "'+sentinel+'"\nexit 99\n',{mode:0o700});
  const config={approval_root:approval,scratch_root:scratch,retention_root:retention,artifact_key_id:'synthetic-only',artifact_signing_key:'synthetic-fixture-not-real-secret-0123456789',workspaces:{demo:{root:workspace,read_only_roots:[workspace],allowed_backends:['LocalOs'],allowed_networks:['Deny'],allowed_egress:[],allowed_commands:['probe'],allow_degraded:true}},local_tools:{probe:tool},aen_backends:{},limits:{max_protocol_bytes:65536,max_wall_clock_ms:5000,max_cpu_seconds:2,max_memory_mib:256,max_disk_mib:32,max_processes:32,max_output_bytes:65536,max_model_output_bytes:32768,max_command_args:16,max_argument_bytes:4096,max_changed_paths:32,retention_ms:'60000'}};
  const configPath=path.join(root,'config.json');fs.writeFileSync(configPath,JSON.stringify(config),{mode:0o600});
  function snapshot() {
    const values={};function walk(p){const stat=fs.lstatSync(p);values[path.relative(root,p)]={mode:stat.mode,size:stat.isFile()?stat.size:null,content:stat.isFile()?createHash('sha256').update(fs.readFileSync(p)).digest('hex'):null};if(stat.isDirectory())for(const name of fs.readdirSync(p).sort())walk(path.join(p,name));}walk(root);return values;
  }
  const before=snapshot();
  function check(raw) {
    const result=spawnSync(binary,['--check'],{env:{PATH:'/usr/bin:/bin',HOME:process.env.HOME,XDG_CONFIG_HOME:process.env.XDG_CONFIG_HOME,XDG_CACHE_HOME:process.env.XDG_CACHE_HOME,XDG_DATA_HOME:process.env.XDG_DATA_HOME,XDG_STATE_HOME:process.env.XDG_STATE_HOME,XDG_RUNTIME_DIR:process.env.XDG_RUNTIME_DIR,TMPDIR:process.env.TMPDIR,TMP:process.env.TMPDIR,TEMP:process.env.TMPDIR,MOONFORT_EXECUTOR_CONFIG:configPath},input:raw,encoding:'utf8',timeout:10000,maxBuffer:131072});
    assert.equal(result.error,undefined);assert.equal(result.status,0,result.stderr);assert.equal(result.stderr,'');assert.equal(fs.existsSync(sentinel),false,'synthetic command must never execute');assert.deepEqual(snapshot(),before,'--check must not mutate disposable configuration, approval stores, scratch, retention or workspace');
    return JSON.parse(result.stdout);
  }
  let output;
  await test('native --check accepts real form-handler download with exact argument scope',async()=> {
    await h.open(fixture());await h.edit('request_id','edited-native-request');await h.edit('working_directory',JSON.stringify('src'));
    h.args()[0].value=JSON.stringify('one argument with spaces');await h.args()[0].fire('input');await h.preview();output=(await h.download()).text;
    const response=check(output);assert.equal(response.ready_for_review,true,JSON.stringify(response));assert.deepEqual(response.candidate,JSON.parse(output).grant);assert.match(response.review_digest,/^[0-9a-f]{64}$/);
  });
  await test('repeated native checks remain read-only',()=>{const a=check(output),b=check(output);assert.equal(a.review_digest,b.review_digest);});
  await test('native --check preserves CRLF directory and exact digest through generated form',async()=> {
    const f=fixture();f.grant.working_directory='src\r\nreview';await h.open(f);await h.preview();
    const downloaded=(await h.download()).text;assert.deepEqual(JSON.parse(downloaded),f);
    const original=check(JSON.stringify(f)),authored=check(downloaded);
    assert.equal(original.ready_for_review,true);assert.equal(authored.ready_for_review,true);
    assert.equal(authored.candidate.working_directory,'src\r\nreview');assert.equal(authored.review_digest,original.review_digest);
  });

  await test('native policy correction rejects edited resource excess without effects',async()=> {
    await h.edit('limits.memory_mib','1000');await h.preview();const bad=(await h.download()).text;const response=check(bad);assert.equal(response.ready_for_review,false);assert.equal(response.correction.field,'limits.memory_mib');
    await h.edit('limits.memory_mib','128');await h.preview();assert.equal(check((await h.download()).text).ready_for_review,true);
  });
  await test('native rejects unknown workspace and expired request without effects',()=> {
    const unknown=JSON.parse(output);unknown.grant.workspace_id='unregistered';assert.equal(check(JSON.stringify(unknown)).correction.field,'workspace_id');
    const expired=JSON.parse(output);expired.grant.expires_at_ms='1';assert.equal(check(JSON.stringify(expired)).correction.field,'expires_at_ms');
  });
  console.log(JSON.stringify({native_fixture:root,retained:true,actual_invocation:'grant-publisher --check only',payload_sentinel_absent:!fs.existsSync(sentinel),fixture_snapshot_unchanged:true}));
}
console.log(JSON.stringify({passed:checks,failed:0,qualification:'Node generated-page event handlers; optional native check-only compatibility. Full browser and containment unqualified.'}));
