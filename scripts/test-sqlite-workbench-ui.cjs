/* Minimal DOM contract harness, with real HTTP and production app.js. No layout/browser claim. */
const fs=require('fs'),vm=require('vm'),assert=require('assert');
class Element {
 constructor(tag){this.tagName=tag;this.children=[];this._value='';this.textContent='';this.disabled=false;}
 set value(v){this._value=v;} get value(){return this._value || (this.tagName==='select'&&this.children.length?this.children[0].value:'');}
 append(...items){for(const item of items){this.children.push(item);item.parent=this;}}
 replaceChildren(...items){this.children=[];this._value='';this.append(...items);}
 setAttribute(){} remove(){this.parent.children=this.parent.children.filter(x=>x!==this);}
}
const ids={};for(const id of ['source','table','limit','filters','addFilter','order','direction','browse','back','previous','next','status','results','sql','parameters','addParameter','maxRows','query','rowAxis','columnAxis','crosstab','numericColumn','boundaries','addBoundary','histogram','downloadCsv','downloadJson','downloadScope','saveWorksheet','openWorksheet','worksheetStatus']) ids[id]=new Element(['table','order','direction','rowAxis','columnAxis','numericColumn'].includes(id)?'select':'div');
ids.limit.value='1'; ids.maxRows.value='1000';ids.direction.value='desc';
const address=process.argv[2], token=process.argv[3], origin='http://'+address;
let pause=false, pending=[], stale=false;
const downloads=[], blobs=new Map(), revoked=[], timers=[];
Element.prototype.click=function(){downloads.push({name:this.download,blob:blobs.get(this.href)});};
const context={document:{body:new Element('body'),getElementById:id=>ids[id],createElement:tag=>new Element(tag)},location:{hash:'#'+token},history:{replaceState(){}},structuredClone,console,Blob,
 URL:{createObjectURL:blob=>{const url='blob:'+blobs.size;blobs.set(url,blob);return url;},revokeObjectURL:url=>revoked.push(url)},setTimeout:fn=>timers.push(fn),
 fetch:async(path,options)=>{options.headers.Origin=origin; const response=await fetch(origin+path,options);if(pause) await new Promise(resolve=>pending.push(resolve));if(stale)return {ok:true,json:async()=>({...await response.json(),session:'old'})};return response;}};
vm.createContext(context);
(async()=>{
 const html=await (await fetch(origin+'/')).text();assert(html.includes('Retained SQLite review'));
 const js=await (await fetch(origin+'/app.js')).text();assert(!js.includes('innerHTML'));
 vm.runInContext(js,context);await vm.runInContext('ready',context);
 const download=async(format)=>{ids[format==='csv'?'downloadCsv':'downloadJson'].onclick();const item=downloads.at(-1);assert.equal(item.name,'moonfort-displayed-records.'+format);assert.equal(context.document.body.children.length,0);return await item.blob.text();};
 ids.downloadCsv.onclick();assert.equal(downloads.length,0);
 ids.table.value='samples';ids.table.onchange();ids.addFilter.onclick();
 const filter=ids.filters.children[0];filter.children[0].value='status';filter.children[1].value='eq';filter.children[2].children[0].value='text';filter.children[2].children[1].value='failed';
 ids.order.value='id';await ids.browse.onclick();assert(ids.status.textContent.includes('samples'));assert(ids.results.children[0].children[1].children[0].textContent==='integer: 2');
 let saved=JSON.parse(await download('json'));assert.equal(saved.rows.length,1);assert.equal(saved.rows[0].values[0].value,'2');assert.equal(saved.offset,0);assert(saved.has_more);assert(saved.scope.includes('page only'));assert(!('session' in saved));assert(saved.database_sha256);assert(saved.rows[0].locator);
 assert.equal(await download('csv'),'"id","parent","status"\r\n"2","9007199254740993","failed"\r\n');
 await ids.next.onclick();assert(ids.results.children[0].children[1].children[0].textContent==='integer: 1');
 assert.equal(JSON.parse(await download('json')).offset,1);
 await ids.results.children[0].children[1].children.at(-1).children[0].onclick();assert(ids.status.textContent.includes('parents'));assert(ids.results.children[0].children[1].children[0].textContent==='integer: 9007199254740993');
 assert(ids.results.children[0].children[1].children[1].textContent==='blob: AP8=');assert(ids.results.children[0].children[1].children[2].textContent==='null: NULL');
 saved=JSON.parse(await download('json'));assert.deepEqual(saved.rows[0].values,[{type:'integer',value:'9007199254740993'},{type:'blob',value:'AP8='},{type:'null',value:null}]);assert((await download('csv')).includes('"9007199254740993","AP8=",""'));
 await ids.results.children[0].children[1].children.at(-1).children[0].onclick();assert(ids.status.textContent.includes('samples'));ids.back.onclick();assert(ids.status.textContent.includes('parents'));ids.back.onclick();assert(ids.status.textContent.includes('samples'));
 ids.sql.value='SELECT id FROM parents WHERE id=?';ids.addParameter.onclick();const param=ids.parameters.children[0].children[0];param.children[0].value='integer';param.children[1].value='9007199254740993';await ids.query.onclick();assert(ids.results.children[0].children[1].children[0].textContent==='integer: 9007199254740993');
 saved=JSON.parse(await download('json'));assert(saved.scope.includes('Complete displayed query'));assert.equal(saved.rows[0][0].value,'9007199254740993');assert(!('locator' in saved));
 ids.parameters.replaceChildren();ids.sql.value=`SELECT '=SUM(1,2)' AS "same", 'a,"b"\ncafé 世界' AS "same", '' AS "" FROM parents`;await ids.query.onclick();
 assert.equal(await download('csv'),'"same","same",""\r\n"=SUM(1,2)","a,""b""\ncafé 世界",""\r\n');
 ids.sql.value='SELECT id FROM parents WHERE id=0';await ids.query.onclick();assert.equal(await download('csv'),'"id"\r\n');assert.deepEqual(JSON.parse(await download('json')).rows,[]);
 ids.back.onclick();assert((await download('csv')).includes('SUM(1,2)'));ids.back.onclick();
 ids.table.value='<img onerror=alert(1)>';ids.table.onchange();await ids.browse.onclick();assert(ids.results.children[0].children[1].children[0].textContent==='text: <script>alert(1)</script>');
 ids.table.value='categories';ids.table.onchange();ids.rowAxis.value='category';ids.columnAxis.value='channel';ids.addFilter.onclick();
 const included=ids.filters.children[0];included.children[0].value='included';included.children[1].value='eq';included.children[2].children[0].value='integer';included.children[2].children[1].value='1';
 await ids.crosstab.onclick();assert(ids.status.textContent.includes('6 matching rows'));
 assert(ids.downloadCsv.disabled&&ids.downloadJson.disabled);const beforeMatrix=downloads.length;ids.downloadJson.onclick();assert.equal(downloads.length,beforeMatrix);
 let matrix=ids.results.children[0];assert.deepEqual(matrix.children[0].children.map(c=>c.textContent),['category / channel','text: A','text: B','Total']);
 assert.deepEqual(matrix.children.at(-1).children.map(c=>c.textContent),['Total','5','1','6']);
 assert(ids.next.disabled&&ids.previous.disabled);
 for(const [label,expected] of [['null: NULL',['integer: 1','integer: 7']],['text: NULL',['integer: 2']],['integer: 7',['integer: 3']],['text: 7',['integer: 4']]]) {
   matrix=ids.results.children[0];const axis=matrix.children.find(r=>r.children[0].textContent===label);
   axis.children[1].children[0].onclick();
   assert.deepEqual(ids.results.children[0].children.slice(1).map(r=>r.children[0].textContent),expected);
   assert(ids.status.textContent.includes('exact member rows'));assert(ids.next.disabled&&ids.previous.disabled);
   saved=JSON.parse(await download('json'));assert.equal(saved.rows.length,expected.length);assert(!('cells' in saved));assert(saved.cell_label);assert(saved.scope.includes('member selection'));
   ids.back.onclick();assert(ids.status.textContent.includes('6 matching rows'));
 }
 matrix=ids.results.children[0];matrix.children.find(r=>r.children[0].textContent==='text: NULL').children[2].children[0].onclick();
 assert(ids.status.textContent.includes('0 exact member rows'));assert.deepEqual(JSON.parse(await download('json')).rows,[]);assert.equal((await download('csv')).split('\r\n').length,2);ids.back.onclick();
 ids.back.onclick();assert(ids.status.textContent.includes('<img onerror=alert(1)>'));
 ids.table.value='categories';ids.table.onchange();ids.rowAxis.value='category';ids.columnAxis.value='category';await ids.crosstab.onclick();assert(ids.status.textContent.includes('distinct stored columns'));
 ids.table.value='measurements';ids.table.onchange();ids.numericColumn.value='latency';ids.addFilter.onclick();
 const measureFilter=ids.filters.children[0];measureFilter.children[0].value='included';measureFilter.children[2].children[0].value='integer';measureFilter.children[2].children[1].value='1';
 ids.boundaries.replaceChildren();
 const edges=[['integer','0'],['real','1.5'],['integer','10'],['integer','9007199254740992'],['integer','9007199254740993']];
 for(const [kind,value] of edges){ids.addBoundary.onclick();const typed=ids.boundaries.children.at(-1).children[0];typed.children[0].value=kind;typed.children[1].value=value;}
 ids.addBoundary.onclick();ids.boundaries.children.at(-1).children[1].onclick();assert.equal(ids.boundaries.children.length,5);
 await ids.histogram.onclick();assert(ids.status.textContent.includes('11 matching rows · 8 numeric · 3 excluded'));
 assert(ids.downloadCsv.disabled&&ids.downloadJson.disabled);
 const distribution=()=>ids.results.children[0];
 const snapshot=()=>distribution().children.map(row=>row.children.map(cell=>cell.textContent||cell.children.map(x=>x.textContent).join('')));
 const original=snapshot();
 assert.deepEqual(original.slice(1,-1).map(row=>row[1]),['1','1','1','3','1','1','1','1','1']);
 assert(original[5][0].includes('9007199254740992')&&original[5][0].includes('9007199254740993'));
 assert.deepEqual(original.at(-1),['Total matching rows','11']);assert(ids.next.disabled&&ids.previous.disabled);
 const expectedMembers=[['1'],['2'],['3'],['4','5','12'],['11'],['9'],['6'],['7'],['8']];
 for(let i=0;i<expectedMembers.length;i++){
   distribution().children[i+1].children[1].children[0].onclick();
   const rows=distribution().children.slice(1);
   assert.deepEqual(distribution().children[0].children.map(c=>c.textContent),['id','latency','included','note']);
   assert.deepEqual(rows.map(r=>r.children[0].textContent),expectedMembers[i].map(id=>'integer: '+id));
   assert(rows.every(r=>r.children[2].textContent==='integer: 1'));
   if(i===5){assert.equal(rows[0].children[1].textContent,'integer: 9007199254740993');assert.equal(rows[0].children[3].textContent,'text: large exact');}
   assert(ids.status.textContent.includes('exact member rows'));ids.back.onclick();assert.deepEqual(snapshot(),original);
 }
 // Editing controls does not change the successful distribution or its members.
 ids.boundaries.children[0].children[0].children[1].value='100';measureFilter.children[2].children[1].value='0';
 distribution().children[1].children[1].children[0].onclick();ids.back.onclick();assert.deepEqual(snapshot(),original);
 await ids.histogram.onclick();assert(ids.status.textContent.includes('strictly increasing'));assert.deepEqual(snapshot(),original);
 ids.boundaries.children[0].children[0].children[1].value='0';measureFilter.children[2].children[1].value='1';
 // A late histogram cannot overwrite a clicked member, nor a Back navigation.
 pause=true;const lateBand=ids.histogram.onclick();while(!pending.length)await new Promise(r=>setTimeout(r,5));
 distribution().children[6].children[1].children[0].onclick();const memberStatus=ids.status.textContent;pending.shift()();await lateBand;
 const memberDownload=await download('json');saved=JSON.parse(memberDownload);assert.equal(saved.rows[0].values[1].value,'9007199254740993');assert(!('bands' in saved));assert(!('excluded' in saved));
 assert.equal(ids.status.textContent,memberStatus);ids.back.onclick();assert.deepEqual(snapshot(),original);pause=false;
 stale=true;await ids.histogram.onclick();stale=false;assert(ids.status.textContent.includes('Stale response refused'));assert.deepEqual(snapshot(),original);
 measureFilter.children[0].value='id';measureFilter.children[2].children[1].value='999';await ids.histogram.onclick();
 assert(ids.status.textContent.includes('0 matching rows'));assert(snapshot().slice(1,-1).every(row=>row[1]==='0'));
 distribution().children[1].children[1].children[0].onclick();assert(ids.status.textContent.includes('0 exact member rows'));ids.back.onclick();ids.back.onclick();assert.deepEqual(snapshot(),original);
 pause=true;const lateHistogram=ids.histogram.onclick();while(!pending.length)await new Promise(r=>setTimeout(r,5));ids.back.onclick();const beforeHistogramReply=ids.status.textContent;pending.shift()();await lateHistogram;assert.equal(ids.status.textContent,beforeHistogramReply);pause=false;
 pause=true;const delayed=ids.browse.onclick();while(!pending.length)await new Promise(r=>setTimeout(r,5));ids.back.onclick();const previous=ids.status.textContent;pending.shift()();await delayed;assert.equal(ids.status.textContent,previous);
 pause=false;ids.table.value='samples';ids.table.onchange();ids.limit.value='1';await ids.browse.onclick();const stable=await download('json');
 ids.table.value='parents';ids.table.onchange();assert.equal(await download('json'),stable);
 pause=true;const pendingRead=ids.browse.onclick();while(!pending.length)await new Promise(r=>setTimeout(r,5));assert.equal(await download('json'),stable);pending.shift()();await pendingRead;pause=false;
 const successful=await download('json');ids.sql.value='DELETE FROM parents';await ids.query.onclick();assert(ids.status.textContent.includes('refused'));assert.equal(await download('json'),successful);
 assert.equal(timers.length,downloads.length);timers.forEach(fn=>fn());assert.equal(revoked.length,downloads.length);
 console.log('PASS: displayed-record downloads: exact page/offset, CSV quoting/Unicode-capable strings/formula-like text, duplicate labels, typed Int64/BLOB/NULL and locators, query/empty results, cell/band members only, disabled aggregate downloads, edited controls/pending/refused requests preserve successful view, Back, object URL revocation.');
 console.log('PASS: production UI + real HTTP: typed filters/order, page, forward/reverse FK, back, parameterized SQL, Int64/BLOB/NULL, hostile literals, stale in-flight response. Crosstab typed axes, filtered totals, exact members, zero cells and Back. Numeric typed boundaries, exact adjacent Int64 edges, filtered complete totals, excluded NULL/text/BLOB, original member records, empty bands, unchanged distribution on edited controls/refusal/Back, stale histogram replies after member navigation/Back, mismatched session refusal. Minimal DOM only.');
})().catch(error=>{console.error(error);process.exitCode=1;});
