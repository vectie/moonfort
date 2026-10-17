// Actual compiled publisher CLI. Only disposable synthetic grants are published.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const binary = path.resolve(process.argv[2] || '');
assert.ok(fs.statSync(binary).isFile(), 'pass the actual compiled grant-publisher binary');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fort-rehearsal-'));
fs.chmodSync(root, 0o700);
const dir = name => { const p=path.join(root,name); fs.mkdirSync(p,{recursive:true,mode:0o700}); return fs.realpathSync(p); };
const approval=dir('approval'); dir('approval/pending'); dir('approval/consumed');
const scratch=dir('scratch'); const retention=dir('retention'); dir('retention/output-artifacts'); dir('retention/live-output');
const workspace=dir('workspace');
const tool=path.join(root,'synthetic-tool'); fs.copyFileSync('/usr/bin/true',tool); fs.chmodSync(tool,0o700);
const alternateTool=path.join(root,'synthetic-alternate'); fs.copyFileSync('/usr/bin/false',alternateTool); fs.chmodSync(alternateTool,0o700);
const config={approval_root:approval,scratch_root:scratch,retention_root:retention,artifact_key_id:'synthetic-only',artifact_signing_key:'synthetic-fixture-not-a-real-secret-0123456789',
  workspaces:{demo:{root:workspace,read_only_roots:[workspace],allowed_backends:['LocalOs'],allowed_networks:['Deny'],allowed_egress:[],allowed_commands:['true'],allow_degraded:true}},
  local_tools:{true:tool},aen_backends:{},limits:{max_protocol_bytes:65536,max_wall_clock_ms:5000,max_cpu_seconds:2,max_memory_mib:256,max_disk_mib:32,max_processes:32,max_output_bytes:65536,max_model_output_bytes:32768,max_command_args:16,max_argument_bytes:4096,max_changed_paths:32,retention_ms:'60000'}};
const configPath=path.join(root,'config.json');
const saveConfig=()=>fs.writeFileSync(configPath,JSON.stringify(config),{mode:0o600}); saveConfig();
const grant={protocol_version:3,approval_id:'synthetic-review',request_id:'synthetic-request',workspace_id:'demo',backend:'LocalOs',enforcement_requirement:'AllowDegraded',network:'Deny',allowed_egress:[],allowed_commands:['true'],limits:{wall_clock_ms:2000,cpu_seconds:1,memory_mib:128,disk_mib:16,processes:16,output_bytes:8192},working_directory:'',command:['Exec',{tool:'true',args:[]}],backend_config_id:'local',expires_at_ms:String(Date.now()+60000)};
let checks=0;
function run(args,g=grant,raw){ const result=spawnSync(binary,args,{env:{...process.env,MOONFORT_EXECUTOR_CONFIG:configPath},input:raw??JSON.stringify({protocol_version:3,grant:g}),encoding:'utf8',timeout:10000}); assert.equal(result.status,0,result.stderr); return JSON.parse(result.stdout); }
function empty(){assert.deepEqual(fs.readdirSync(path.join(approval,'pending')),[]);assert.deepEqual(fs.readdirSync(path.join(approval,'consumed')),[]);assert.deepEqual(fs.readdirSync(scratch),[]);}
try {
  const invalid=structuredClone(grant); invalid.limits.memory_mib=1000;
  const fix=run(['--check'],invalid); assert.equal(fix.ready_for_review,false,JSON.stringify(fix)); assert.equal(fix.correction.field,'limits.memory_mib'); empty(); checks++;
  const review=run(['--check']); assert.equal(review.ready_for_review,true,JSON.stringify(review)); assert.equal(review.review_digest.length,64); assert.deepEqual(review.candidate,grant); empty(); checks++;
  const repeat=run(['--check']); assert.equal(repeat.review_digest,review.review_digest); empty(); checks++;
  const changed=structuredClone(grant); changed.command[1].args=['changed'];
  assert.equal(run(['--publish-reviewed',review.review_digest],changed).error.code,'review-stale'); empty(); checks++;
  config.local_tools.true=alternateTool; saveConfig();
  assert.equal(run(['--publish-reviewed',review.review_digest]).error.code,'review-stale'); empty(); checks++;
  config.local_tools.true=tool; saveConfig();
  assert.equal(run(['--publish-reviewed','']).published,false); empty(); checks++;
  const expired={...grant,expires_at_ms:'1'}; assert.equal(run(['--publish-reviewed',review.review_digest],expired).published,false); empty(); checks++;
  assert.equal(run(['--check','typo']).published,false); empty(); checks++;
  assert.equal(run(['--check'],grant,'{').published,false); empty(); checks++;
  const result=run(['--publish-reviewed',review.review_digest]); assert.equal(result.published,true,JSON.stringify(result));
  const saved=JSON.parse(fs.readFileSync(path.join(approval,'pending',grant.approval_id+'.json'),'utf8')); assert.deepEqual(saved,grant); assert.deepEqual(fs.readdirSync(path.join(approval,'consumed')),[]); assert.deepEqual(fs.readdirSync(scratch),[]); checks++;
  const duplicate=run(['--publish-reviewed',review.review_digest]); assert.equal(duplicate.error.code,'grant-conflict'); checks++;
  const legacy={...grant,approval_id:'synthetic-legacy'}; assert.equal(run([],legacy).published,true); checks++;
  console.log(JSON.stringify({passed:checks,failed:0,journey:'check → correct → recheck → changed-candidate refusal → explicit publish → duplicate refusal',execution_started:false,fixture:'disposable synthetic only'}));
} finally { fs.rmSync(root,{recursive:true,force:true}); }
