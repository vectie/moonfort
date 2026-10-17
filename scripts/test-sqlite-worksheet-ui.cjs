/* Product regression: production JavaScript, actual loopback readers and a small
 * DOM contract harness. This does not qualify graphical browser/file-picker UI. */
const vm=require('vm'),assert=require('assert');
class Element {
  constructor(tag){this.tagName=tag;this.children=[];this._value='';this.textContent='';this.disabled=false;this.files=[];}
  set value(value){this._value=value;}
  get value(){return this._value||(this.tagName==='select'&&this.children.length?this.children[0].value:'');}
  append(...items){for(const item of items){this.children.push(item);item.parent=this;}}
  replaceChildren(...items){this.children=[];this._value='';this.append(...items);}
  setAttribute(){}
  remove(){this.parent.children=this.parent.children.filter(item=>item!==this);}
}
async function boot(address,token) {
  const origin='http://'+address, html=await(await fetch(origin+'/')).text(), ids={};
  for(const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g)) ids[match[2]]=new Element(match[1]);
  const downloads=[],blobs=new Map(),timers=[],revoked=[],requests=[],pending=[];
  const state={pause:false};
  const document={body:new Element('body'),getElementById:id=>ids[id],createElement:tag=>{
    const element=new Element(tag);element.click=()=>downloads.push({name:element.download,blob:blobs.get(element.href)});return element;
  }};
  ids.maxRows.value='1000';ids.limit.value='25';ids.direction.value='asc';
  ids.saveWorksheet.disabled=true;ids.openWorksheet.disabled=true;
  const context={document,location:{hash:'#'+token},history:{replaceState(){}},structuredClone,Blob,TextDecoder,console,
    URL:{createObjectURL:blob=>{const id='blob:'+blobs.size;blobs.set(id,blob);return id;},revokeObjectURL:id=>revoked.push(id)},
    setTimeout:fn=>timers.push(fn),fetch:async(path,options)=>{
      requests.push(JSON.parse(options.body));options.headers.Origin=origin;
      const response=await fetch(origin+path,options);
      if(state.pause) await new Promise(resolve=>pending.push(resolve));
      return response;
    }};
  vm.createContext(context);vm.runInContext(await(await fetch(origin+'/app.js')).text(),context);
  await vm.runInContext('ready',context);
  assert(!ids.saveWorksheet.disabled&&!ids.openWorksheet.disabled);
  const snapshot=()=>({sql:ids.sql.value,max_rows:ids.maxRows.value,parameters:ids.parameters.children.map(row=>({
    type:row.children[0].children[0].value,value:row.children[0].children[1].value,disabled:row.children[0].children[1].disabled}))});
  const open=async value=>{
    ids.openWorksheet.files=[typeof value==='string'?new Blob([value]):value];
    await ids.openWorksheet.onchange();assert.equal(ids.openWorksheet.value,'');
  };
  const save=async()=>{
    const before=downloads.length;ids.saveWorksheet.onclick();assert.equal(downloads.length,before+1,ids.worksheetStatus.textContent);
    const download=downloads.at(-1);assert.equal(download.name,'moonfort-sql-worksheet.json');
    assert.equal(document.body.children.length,0);return await download.blob.text();
  };
  const results=()=>ids.results.children[0]?.children.slice(1).map(row=>row.children.map(cell=>cell.textContent));
  return {ids,requests,downloads,timers,revoked,state,pending,snapshot,open,save,results};
}
async function waitPending(ui) {while(!ui.pending.length)await new Promise(resolve=>setTimeout(resolve,5));}
(async()=>{
  const args=process.argv.slice(2),first=await boot(args[0],args[1]);
  const sql=' SELECT id, ?, ?, ?, ?, ?, ? FROM parents WHERE id = ?\n';
  const parameters=[{type:'text',value:'café 世界 <script>alert(1)</script>'},
    {type:'integer',value:'-9223372036854775808'},{type:'real',value:'1.2500e+0'},
    {type:'blob',value:'AP8='},{type:'null',value:'hidden draft text'},
    {type:'text',value:''},{type:'integer',value:'9007199254740993'}];
  first.ids.sql.value=sql;first.ids.maxRows.value='0010';
  for(const parameter of parameters) {
    first.ids.addParameter.onclick();const controls=first.ids.parameters.children.at(-1).children[0];
    controls.children[0].value=parameter.type;controls.children[0].onchange();controls.children[1].value=parameter.value;
  }
  const text=await first.save(),saved=JSON.parse(text),snapshot=first.snapshot();
  assert.deepEqual(Object.keys(saved).sort(),['database_sha256','format','max_rows','parameters','source','sql']);
  assert.deepEqual(Object.keys(saved.source).sort(),['artifact_path','bundle_sha256','manifest_sha256']);
  assert.deepEqual(saved.parameters,parameters);assert.equal(saved.sql,sql);assert.equal(saved.max_rows,'0010');
  assert.equal(first.requests.filter(request=>request.operation==='query').length,0);
  for(const secret of [args[1],first.requests[1].session])assert(!text.includes(secret));
  const fresh=await boot(args[2],args[3]);assert.notEqual(first.requests[1].session,fresh.requests[1].session);
  const before=fresh.requests.length;await fresh.open(text);
  assert.deepEqual(fresh.snapshot(),snapshot);assert.equal(fresh.requests.length,before);
  assert.equal(fresh.ids.results.children.length,0);assert(fresh.ids.downloadJson.disabled&&fresh.ids.back.disabled);
  assert.equal(fresh.ids.status.textContent,'Worksheet reopened. No query has run.');
  assert.equal(await fresh.save(),text);
  // Reopened rows are live editors, including text retained behind a NULL type.
  const nullable=fresh.ids.parameters.children[4].children[0];
  nullable.children[0].value='text';nullable.children[0].onchange();assert(!nullable.children[1].disabled);
  assert.equal(nullable.children[1].value,'hidden draft text');
  nullable.children[0].value='null';nullable.children[0].onchange();
  await fresh.ids.query.onclick();
  assert.deepEqual(fresh.results(),[['integer: 9007199254740993','text: café 世界 <script>alert(1)</script>',
    'integer: -9223372036854775808','real: 1.25','blob: AP8=','null: NULL','text: ']]);
  assert.equal(fresh.requests.at(-1).session,fresh.requests[1].session);
  assert.deepEqual(fresh.requests.at(-1).parameters,parameters.map(p=>p.type==='null'?{type:'null',value:null}:p));
  fresh.ids.parameters.children[0].children[0].children[1].value='edited after reopen';
  fresh.ids.parameters.children[0].children[0].children[1].oninput();
  await fresh.ids.query.onclick();assert.equal(fresh.results()[0][1],'text: edited after reopen');
  assert.equal(JSON.parse(await fresh.save()).parameters[0].value,'edited after reopen');
  fresh.ids.addParameter.onclick();fresh.ids.parameters.children.at(-1).children[1].onclick();
  assert.equal(fresh.ids.parameters.children.length,7);

  const prior=fresh.snapshot(), priorResults=fresh.results(), priorCalls=fresh.requests.length;
  const refuse=async(raw,pattern=/refused/)=>{
    await fresh.open(raw);assert(pattern.test(fresh.ids.worksheetStatus.textContent),fresh.ids.worksheetStatus.textContent);
    assert.deepEqual(fresh.snapshot(),prior);assert.deepEqual(fresh.results(),priorResults);
    assert.equal(fresh.requests.length,priorCalls);
  };
  const malformed=[null,[],{}, {...saved,format:'other'}, {...saved,session:'old'}, {...saved,rows:[]},
    {...saved,database_sha256:'0'.repeat(64)}, {...saved,source:{...saved.source,artifact_path:'other.sqlite'}},
    {...saved,source:{...saved.source,bundle_sha256:'0'.repeat(64)}}, {...saved,source:{...saved.source,manifest_sha256:'0'.repeat(64)}},
    {...saved,source:{...saved.source,token:'unused'}}, {...saved,sql:9}, {...saved,sql:'é'.repeat(32769)},
    {...saved,sql:'SELECT 1\r\n'}, {...saved,parameters:{}}, {...saved,parameters:Array(129).fill({type:'text',value:''})},
    {...saved,parameters:[{type:'integer',value:9007199254740992}]}, {...saved,parameters:[{type:'null',value:null}]},
    {...saved,parameters:[{type:'unknown',value:'1'}]}, {...saved,parameters:[{type:'text',value:'x',extra:1}]},
    {...saved,parameters:[{type:'text',value:'line\nbreak'}]}, {...saved,parameters:[{type:'text',value:'é'.repeat(32769)}]},
    {...saved,max_rows:10}, {...saved,max_rows:'foo'}, {...saved,max_rows:'9'.repeat(33)}];
  for(const bad of malformed)await refuse(JSON.stringify(bad));
  await refuse('{');await refuse(new Blob([new Uint8Array([0xc3,0x28])]));
  let oversizedRead=false;await refuse({size:262145,arrayBuffer:async()=>{oversizedRead=true;return new ArrayBuffer(0);}});
  assert(!oversizedRead);await refuse({size:1,arrayBuffer:async()=>{throw Error('file unavailable');}});
  fresh.ids.openWorksheet.files=[];await fresh.ids.openWorksheet.onchange();assert.deepEqual(fresh.snapshot(),prior);
  fresh.ids.openWorksheet.oncancel();assert.deepEqual(fresh.snapshot(),prior);assert.deepEqual(fresh.results(),priorResults);
  // A late file read cannot overwrite newer edits, a second selection, cancellation or Run.
  let release;
  const delayed=()=>({size:text.length,arrayBuffer:()=>new Promise(resolve=>{release=async()=>resolve(await new Blob([text]).arrayBuffer());})});
  const editing=fresh.open(delayed());fresh.ids.sql.value='SELECT id FROM parents';fresh.ids.sql.oninput();await release();await editing;
  assert.equal(fresh.ids.sql.value,'SELECT id FROM parents');assert(fresh.ids.worksheetStatus.textContent.includes('Editor changed'));
  const cancelled=fresh.open(delayed());fresh.ids.openWorksheet.oncancel();await release();await cancelled;
  assert.equal(fresh.ids.sql.value,'SELECT id FROM parents');assert(fresh.ids.worksheetStatus.textContent.includes('cancelled'));
  const old=fresh.open(delayed());await fresh.open(JSON.stringify({...saved,sql:'SELECT payload FROM parents',parameters:[]}));
  await release();await old;assert.equal(fresh.ids.sql.value,'SELECT payload FROM parents');
  const running=fresh.open(delayed());await fresh.ids.query.onclick();await release();await running;
  assert.equal(fresh.ids.sql.value,'SELECT payload FROM parents');assert.deepEqual(fresh.results(),[['blob: AP8=']]);
  // Conversely, reopening invalidates a query already in flight and clears old results.
  fresh.state.pause=true;const query=fresh.ids.query.onclick();await waitPending(fresh);
  await fresh.open(text);fresh.pending.shift()();await query;fresh.state.pause=false;
  assert.equal(fresh.ids.status.textContent,'Worksheet reopened. No query has run.');assert.equal(fresh.ids.results.children.length,0);

  // Unfinished drafts round-trip without coercion or implicit validation/execution.
  fresh.ids.sql.value='';fresh.ids.maxRows.value='';fresh.ids.parameters.children[0].children[0].children[0].value='integer';
  fresh.ids.parameters.children[0].children[0].children[1].value='unfinished';const draft=await fresh.save();
  await fresh.open(text);await fresh.open(draft);assert.equal(fresh.ids.sql.value,'');assert.equal(fresh.ids.maxRows.value,'');
  assert.equal(fresh.ids.parameters.children[0].children[0].children[1].value,'unfinished');
  await fresh.ids.query.onclick();assert(fresh.ids.status.textContent.includes('Review refused'));
  // The SQL authorizer still refuses writes after a structurally valid reopen.
  await fresh.open(JSON.stringify({...saved,sql:'DELETE FROM parents',parameters:[]}));
  await fresh.ids.query.onclick();assert(fresh.ids.status.textContent.includes('refused'));assert.equal(fresh.ids.results.children.length,0);
  await fresh.open(text);await fresh.ids.query.onclick();assert.equal(fresh.results()[0][0],'integer: 9007199254740993');

  // Save-side bounds refuse without producing a misleading/partial download.
  const downloadsBefore=fresh.downloads.length, callsBefore=fresh.requests.length;
  fresh.ids.sql.value='é'.repeat(32769);fresh.ids.saveWorksheet.onclick();
  assert.equal(fresh.downloads.length,downloadsBefore);assert(fresh.ids.worksheetStatus.textContent.includes('64 KiB'));
  fresh.ids.sql.value='\u0001'.repeat(65536);fresh.ids.saveWorksheet.onclick();
  assert.equal(fresh.downloads.length,downloadsBefore);assert(fresh.ids.worksheetStatus.textContent.includes('256 KiB'));
  fresh.ids.sql.value='x'.repeat(65536);await fresh.open(await fresh.save());assert.equal(fresh.ids.sql.value.length,65536);
  assert.equal(fresh.requests.length,callsBefore);assert.equal(fresh.ids.results.children.length,0);
  await fresh.open(JSON.stringify({...saved,parameters:Array(128).fill({type:'text',value:''})}));
  assert.equal(fresh.ids.parameters.children.length,128);await fresh.open(text);

  const sameDatabase=await boot(args[4],args[5]), changedDatabase=await boot(args[6],args[7]);
  assert.equal(sameDatabase.requests[1].database_sha256,saved.database_sha256);
  assert.notEqual(changedDatabase.requests[1].database_sha256,saved.database_sha256);
  for(const [other,message] of [[sameDatabase,'source identity'],[changedDatabase,'database fingerprint']]) {
    other.ids.sql.value='keep my draft';const calls=other.requests.length;await other.open(text);
    assert(other.ids.worksheetStatus.textContent.includes(message));assert.equal(other.ids.sql.value,'keep my draft');
    assert.equal(other.requests.length,calls);assert.equal(other.ids.results.children.length,0);
  }
  for(const ui of [first,fresh,sameDatabase,changedDatabase]) {
    ui.timers.forEach(fn=>fn());assert.equal(ui.revoked.length,ui.downloads.length);
  }
  console.log('PASS: SQL worksheet saves exact editor SQL, parameter order/types/raw text including latent NULL text, row-bound text, immutable database/bundle/manifest/artifact identity; no session authority or results.');
  console.log('PASS: fresh Workbench/session reopen restores editable controls with no API query; explicit Run returns actual read-only Int64/BLOB/NULL/Unicode values; edit, add/remove, save again and authorizer refusal remain functional.');
  console.log('PASS: '+malformed.length+' malformed/foreign identity cases, invalid JSON/UTF-8, size bounds, unreadable files and cancelled input preserve editor/results. Late file selections/edits/Run and older HTTP query cannot overwrite newer intent. Different database and same-database/different-source sessions refuse. Minimal DOM, not graphical browser qualification.');
})().catch(error=>{console.error(error);process.exitCode=1;});
