'use strict';
const $ = id => document.getElementById(id);
const node = (tag, text) => { const element = document.createElement(tag); if (text !== undefined) element.textContent = text; return element; };
const option = (select, value, label=value) => { const item = node('option', label); item.value = value; select.append(item); };
const token = location.hash.slice(1);
history.replaceState(null, '', '/');
let binding, worksheetSource, tables = [], current = null, stack = [], generation = 0;
let worksheetLoad = 0, editorRevision = 0;
const worksheetEdited = () => { ++editorRevision; };
async function api(body) {
  const response = await fetch('/api', {method:'POST', headers:{'Content-Type':'application/json', 'X-Review-Token':token}, body:JSON.stringify({...binding, ...body})});
  const data = await response.json(); if (!response.ok) throw Error(data.error || 'Review refused'); return data;
}
function typed(container, kinds=['text','integer','real','blob','null'], initial=null, edited=()=>{}) {
  const wrap=node('span'); wrap.className='typed'; const type=node('select'), value=node('input');
  type.setAttribute('aria-label','Storage type'); value.setAttribute('aria-label','Exact value (BLOB uses base64)');
  for(const kind of kinds) option(type,kind);
  type.onchange=()=>{value.disabled=type.value==='null';edited();}; value.oninput=edited;
  if(initial) {type.value=initial.type;value.value=initial.value;value.disabled=type.value==='null';}
  wrap.append(type,value); container.append(wrap);
  const recipe=()=>({type:type.value,value:type.value==='null'?null:value.value});
  recipe.editor=()=>({type:type.value,value:value.value});
  return recipe;
}
function removeButton(row, edited=()=>{}) { const remove=node('button','Remove'); remove.onclick=()=>{row.remove();edited();}; row.append(remove); }
function addFilter() {
  const row=node('div'), column=node('select'), op=node('select'); column.setAttribute('aria-label','Filter column'); op.setAttribute('aria-label','Operator');
  const table=tables.find(t=>t.name===$('table').value);
  for(const c of table.columns.filter(c=>!c.generated)) option(column,c.name);
  for(const name of ['eq','gt','gte','lt','lte','between','contains','starts_with']) option(op,name);
  row.append(column,op); const lower=typed(row); const upperWrap=node('span',' Upper (between only): '); const upper=typed(upperWrap); row.append(upperWrap);
  row.recipe=()=>({column:column.value,op:op.value,value:lower(),...(op.value==='between'?{upper:upper()}: {})});
  removeButton(row); $('filters').append(row);
}
function parameterRow(initial=null) {
  const row=node('div'); row.recipe=typed(row,undefined,initial,worksheetEdited);
  removeButton(row,worksheetEdited); return row;
}
function addParameter() {$('parameters').append(parameterRow());worksheetEdited();}

// A worksheet is bounded, untrusted editor data. It never carries session
// authority or results, and even an unfinished draft can be saved for editing.
const MAX_WORKSHEET_BYTES=256*1024;
function worksheetKeys(value, keys) {
  return value!==null&&typeof value==='object'&&!Array.isArray(value)&&
    Object.keys(value).length===keys.length&&keys.every(key=>Object.hasOwn(value,key));
}
function checkWorksheet(value) {
  const require=(ok,message)=>{if(!ok) throw Error(message);};
  require(worksheetSource,'Pinned source is not ready');
  require(worksheetKeys(value,['format','database_sha256','source','sql','parameters','max_rows'])&&
    value.format==='moonfort.sql-worksheet.v1','Unsupported worksheet format or fields');
  require(value.database_sha256===binding.database_sha256,'Worksheet database fingerprint does not match this pinned copy');
  require(worksheetKeys(value.source,['bundle_sha256','manifest_sha256','artifact_path'])&&
    Object.keys(worksheetSource).every(key=>value.source[key]===worksheetSource[key]),
    'Worksheet source identity does not match this retained bundle and artifact');
  require(typeof value.sql==='string'&&!value.sql.includes('\r')&&new Blob([value.sql]).size<=65536,
    'Worksheet SQL must be LF editor text within 64 KiB');
  require(Array.isArray(value.parameters)&&value.parameters.length<=128,'Worksheet requires at most 128 typed parameter editors');
  require(value.parameters.every(p=>worksheetKeys(p,['type','value'])&&
    ['text','integer','real','blob','null'].includes(p.type)&&typeof p.value==='string'&&!/[\r\n]/.test(p.value)),
    'Worksheet parameters require a storage type and exact editor text');
  require(new Blob([JSON.stringify(value.parameters)]).size<=65536,'Worksheet parameter editors exceed 64 KiB');
  require(typeof value.max_rows==='string'&&value.max_rows.length<=32&&
    (value.max_rows===''||(/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.max_rows)&&Number.isFinite(Number(value.max_rows)))),
    'Worksheet row bound must be numeric editor text within 32 characters, or empty');
  return value;
}
function saveWorksheet() {
  try {
    const value=checkWorksheet({format:'moonfort.sql-worksheet.v1',database_sha256:binding&&binding.database_sha256,
      source:worksheetSource,sql:$('sql').value,parameters:Array.from($('parameters').children,r=>r.recipe.editor()),max_rows:$('maxRows').value});
    const text=JSON.stringify(value,null,2)+'\n';
    if(new Blob([text]).size>MAX_WORKSHEET_BYTES) throw Error('Worksheet exceeds 256 KiB');
    downloadText(text,'application/json;charset=utf-8','moonfort-sql-worksheet.json');
    $('worksheetStatus').textContent='Worksheet downloaded. SQL and parameter text may be private; keep this file local.';
  } catch(error) {$('worksheetStatus').textContent='Worksheet save refused: '+error.message;}
}
async function openWorksheet() {
  const ticket=++worksheetLoad, revision=editorRevision, file=$('openWorksheet').files[0];
  $('openWorksheet').value=''; // Permit selecting the same file again after refusal.
  if(!file) {$('worksheetStatus').textContent='No worksheet selected. Editor unchanged.';return;}
  $('worksheetStatus').textContent='Reading worksheet locally…';
  try {
    if(file.size>MAX_WORKSHEET_BYTES) throw Error('Worksheet exceeds 256 KiB');
    const bytes=await file.arrayBuffer();
    if(ticket!==worksheetLoad) return;
    if(bytes.byteLength>MAX_WORKSHEET_BYTES) throw Error('Worksheet exceeds 256 KiB');
    const value=checkWorksheet(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)));
    if(revision!==editorRevision) throw Error('Editor changed while the file was loading; choose the worksheet again to replace it');
    const rows=value.parameters.map(parameterRow);
    $('sql').value=value.sql; $('maxRows').value=value.max_rows; $('parameters').replaceChildren(...rows); worksheetEdited();
    // Neither an older displayed result nor an in-flight query belongs to this
    // newly opened draft. Only the user's next explicit Run can produce rows.
    ++generation; current=null; stack=[]; $('results').replaceChildren(); exportControls(null);
    $('back').disabled=true; $('previous').disabled=true; $('next').disabled=true;
    $('status').textContent='Worksheet reopened. No query has run.';
    $('worksheetStatus').textContent='Review or edit the restored SQL and parameters, then press Run read-only query.';
  } catch(error) {
    if(ticket===worksheetLoad) $('worksheetStatus').textContent='Worksheet open refused: '+error.message+'. Editor unchanged.';
  }
}
function addBoundary() {
  const row=node('div'); row.recipe=typed(row,['integer','real']);
  removeButton(row); $('boundaries').append(row);
}
function tableChanged() {
  $('filters').replaceChildren(); $('order').replaceChildren(); option($('order'),'','Locator order');
  const table=tables.find(t=>t.name===$('table').value);
  $('rowAxis').replaceChildren(); $('columnAxis').replaceChildren(); $('numericColumn').replaceChildren();
  if(table) {
    const columns=table.columns.filter(c=>!c.generated);
    for(const c of columns) {option($('order'),c.name);option($('rowAxis'),c.name);option($('columnAxis'),c.name);option($('numericColumn'),c.name);}
    if(columns.length>1) $('columnAxis').value=columns[1].name;
    $('crosstab').disabled=columns.length<2;
    $('histogram').disabled=columns.length===0;
  }
}
function relation(row, fk, incoming, result) {
  const selection={database_sha256:binding.database_sha256,table:result.selection.table,locator:row.locator,foreign_key:fk.id};
  if(incoming) selection.child_table=fk.child_table;
  return {operation:incoming?'referencing':'related',selection,offset:0,limit:current.request.limit};
}
const typedLabel = value => value.type+': '+(value.type==='null'?'NULL':value.value);
function exportScope(result) {
  if(!result || !Array.isArray(result.rows)) return 'Open table, query, or member records to download them.';
  const page=['rows','related','referencing'].includes(result.operation);
  return page ? 'Displayed page only: '+result.rows.length+' rows at offset '+result.offset+'. Other pages are not included.' :
    'Complete displayed '+(result.operation==='query'?'query result':'member selection')+': '+result.rows.length+' rows.';
}
function exportControls(result) {
  const enabled=!!result&&Array.isArray(result.rows);
  $('downloadCsv').disabled=!enabled; $('downloadJson').disabled=!enabled;
  $('downloadScope').textContent=exportScope(result);
}
function downloadDisplayed(format) {
  const result=current&&current.result;
  if(!result || !Array.isArray(result.rows)) return;
  const query=result.operation==='query', columns=query?result.columns:result.selection.columns;
  let text;
  if(format==='csv') {
    const quote=value=>'"'+String(value).replaceAll('"','""')+'"';
    const rows=result.rows.map(row=>(query?row:row.values).map(cell=>cell.type==='null'?'':cell.value));
    text=[columns,...rows].map(row=>row.map(quote).join(',')).join('\r\n')+'\r\n';
  } else {
    const snapshot={};
    for(const key of ['operation','database_sha256','source','selection','locator','offset','has_more','cell_label','band_label'])
      if(Object.hasOwn(result,key)) snapshot[key]=result[key];
    text=JSON.stringify({format:'moonfort.displayed-records.v1',scope:exportScope(result),...snapshot,columns,rows:result.rows},null,2)+'\n';
  }
  downloadText(text,format==='csv'?'text/csv;charset=utf-8':'application/json;charset=utf-8','moonfort-displayed-records.'+format);
}
function downloadText(text,type,filename) {
  const blob=new Blob([text],{type});
  const url=URL.createObjectURL(blob), link=node('a');
  link.href=url; link.download=filename;
  document.body.append(link); link.click(); link.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
}
function renderHistogram(result) {
  const table=node('table'), head=node('tr');
  head.append(node('th',result.selection.column+' range'),node('th','Count')); table.append(head);
  const groupRow=(label,group)=>{
    const row=node('tr'), cell=node('td'), button=node('button',String(group.count));
    row.append(node('th',label));
    button.onclick=()=>{
      ++generation; ++worksheetLoad; stack.push(current);
      const detail={...result,operation:'histogram-members',selection:{...result.selection,columns:result.columns},
        rows:group.rows,offset:0,has_more:false,band_label:label};
      current={request:current.request,result:detail}; render(detail);
    };
    cell.append(button); row.append(cell); table.append(row);
  };
  for(const band of result.bands) {
    const label=band.lower_inclusive===null?'Below '+typedLabel(band.upper_exclusive):
      'At least '+typedLabel(band.lower_inclusive)+(band.upper_exclusive===null?'':' and below '+typedLabel(band.upper_exclusive));
    groupRow(label,band);
  }
  for(const kind of ['null','text','blob']) groupRow('Excluded '+kind,result.excluded[kind]);
  const total=node('tr');total.append(node('th','Total matching rows'),node('td',String(result.selected_row_count)));table.append(total);
  $('results').append(table);
  const numeric=result.bands.reduce((sum,band)=>sum+band.count,0);
  $('status').textContent=result.selection.table+' · Numeric bands · '+result.selected_row_count+' matching rows · '+numeric+' numeric · '+(result.selected_row_count-numeric)+' excluded';
  $('previous').disabled=true;$('next').disabled=true;$('back').disabled=stack.length===0;
}
function renderCrosstab(result) {
  const table=node('table'), head=node('tr');
  head.append(node('th',result.selection.row_column+' / '+result.selection.column_column));
  for(const key of result.column_keys) head.append(node('th',typedLabel(key)));
  head.append(node('th','Total')); table.append(head);
  result.row_keys.forEach((key,i)=>{
    const row=node('tr');row.append(node('th',typedLabel(key)));
    result.column_keys.forEach((_,j)=>{
      const cell=node('td'), button=node('button',String(result.counts[i][j]));
      button.onclick=()=>{
        ++generation; ++worksheetLoad; stack.push(current);
        const members=result.cells.find(c=>c.row_index===i&&c.column_index===j);
        const detail={...result,operation:'crosstab-members',selection:{...result.selection,columns:result.columns},
          rows:members?members.rows:[],offset:0,has_more:false,
          cell_label:typedLabel(key)+' × '+typedLabel(result.column_keys[j])};
        current={request:current.request,result:detail}; render(detail);
      };cell.append(button);row.append(cell);
    });
    row.append(node('td',String(result.row_totals[i])));table.append(row);
  });
  const totals=node('tr');totals.append(node('th','Total'));
  for(const count of result.column_totals) totals.append(node('td',String(count)));
  totals.append(node('td',String(result.selected_row_count)));table.append(totals);$('results').append(table);
  $('status').textContent=result.selection.table+' · Crosstab · '+result.selected_row_count+' matching rows · exact typed categories';
  $('previous').disabled=true;$('next').disabled=true;$('back').disabled=stack.length===0;
}
function render(result) {
  exportControls(result);
  $('source').textContent=JSON.stringify(result.source,null,2);
  $('results').replaceChildren();
  if(result.operation==='crosstab') return renderCrosstab(result);
  if(result.operation==='histogram') return renderHistogram(result);
  const members=result.operation==='crosstab-members'||result.operation==='histogram-members';
  const table=node('table'), head=node('tr'), query=result.operation==='query';
  const columns=query?result.columns:result.selection.columns;
  for(const column of columns) head.append(node('th',column));
  if(!query&&!members) head.append(node('th','Declared references (not integrity certification)'));
  table.append(head);
  const metadata=!query&&!members?tables.find(t=>t.name===result.selection.table):null;
  for(const row of result.rows) {
    const tr=node('tr'); for(const value of query?row:row.values) tr.append(node('td',value.type+': '+(value.type==='null'?'NULL':value.value)));
    if(metadata) {
      const actions=node('td');
      for(const [incoming, keys] of [[false,metadata.foreign_keys],[true,metadata.incoming_foreign_keys]]) for(const fk of keys) {
        const button=node('button',(incoming?'From '+fk.child_table:'To '+fk.referenced_table)+' [FK '+fk.id+']');
        button.onclick=()=>navigate(relation(row,fk,incoming,result)); actions.append(button);
      }
      tr.append(actions);
    }
    table.append(tr);
  }
  $('results').append(table);
  $('status').textContent=(query?'Query':result.selection.table)+' · '+result.rows.length+' rows'+(query?'': ' · offset '+result.offset)+(result.reference_status?' · '+result.reference_status:'');
  if(members) $('status').textContent=result.selection.table+' · '+(result.operation==='histogram-members'?'Band '+result.band_label:'Cell '+result.cell_label)+' · '+result.rows.length+' exact member rows';
  $('previous').disabled=query||members||result.offset===0; $('next').disabled=query||members||!result.has_more; $('back').disabled=stack.length===0;
}
async function navigate(request, remember=true) {
  ++worksheetLoad;
  const ticket=++generation; $('status').textContent='Reading pinned copy…';
  try {
    const result=await api(request);
    if(ticket!==generation) return;
    if(result.session!==binding.session || result.database_sha256!==binding.database_sha256) throw Error('Stale response refused');
    if(remember&&current) stack.push(current);
    current={request:structuredClone(request),result}; render(result);
  } catch(error) {if(ticket===generation) $('status').textContent='Review refused: '+error.message;}
}
$('addFilter').onclick=addFilter; $('addParameter').onclick=()=>addParameter(); $('table').onchange=tableChanged;
$('saveWorksheet').onclick=saveWorksheet; $('openWorksheet').onchange=openWorksheet;
$('openWorksheet').onclick=()=>{++worksheetLoad;};
$('openWorksheet').oncancel=()=>{++worksheetLoad;$('worksheetStatus').textContent='Worksheet selection cancelled. Editor unchanged.';};
$('sql').oninput=worksheetEdited; $('maxRows').oninput=worksheetEdited;
$('addBoundary').onclick=addBoundary;
$('downloadCsv').onclick=()=>downloadDisplayed('csv');
$('downloadJson').onclick=()=>downloadDisplayed('json');
$('browse').onclick=()=>{
  const selection={table:$('table').value,where:Array.from($('filters').children,r=>r.recipe())};
  if($('order').value) selection.order_by=[{column:$('order').value,direction:$('direction').value}];
  return navigate({operation:'rows',selection,offset:0,limit:Number($('limit').value)});
};
$('crosstab').onclick=()=>navigate({operation:'crosstab',selection:{database_sha256:binding.database_sha256,table:$('table').value,row_column:$('rowAxis').value,column_column:$('columnAxis').value,where:Array.from($('filters').children,r=>r.recipe())}});
$('histogram').onclick=()=>navigate({operation:'histogram',selection:{database_sha256:binding.database_sha256,table:$('table').value,column:$('numericColumn').value,boundaries:Array.from($('boundaries').children,r=>r.recipe()),where:Array.from($('filters').children,r=>r.recipe())}});
$('back').onclick=()=>{++generation; ++worksheetLoad; if(stack.length){current=stack.pop();render(current.result);}};
$('next').onclick=()=>navigate({...current.request,offset:current.result.next_offset});
$('previous').onclick=()=>navigate({...current.request,offset:Math.max(0,current.result.offset-current.request.limit)});
$('query').onclick=()=>navigate({operation:'query',sql:$('sql').value,parameters:Array.from($('parameters').children,r=>r.recipe()),max_rows:Number($('maxRows').value)});
const ready=(async()=>{
  try {
    binding=await api({operation:'bootstrap'});
    const schema=await api({operation:'schema'}); tables=schema.objects;
    if(schema.session!==binding.session||schema.database_sha256!==binding.database_sha256) throw Error('Stale schema refused');
    worksheetSource={bundle_sha256:schema.source.bundle_sha256,manifest_sha256:schema.source.manifest_sha256,
      artifact_path:schema.source.source_file.relative_path};
    $('saveWorksheet').disabled=false; $('openWorksheet').disabled=false;
    for(const table of tables.filter(t=>t.row_selection_supported)) option($('table'),table.name);
    $('source').textContent=JSON.stringify(schema.source,null,2); tableChanged();
    addBoundary(); $('boundaries').children[0].children[0].children[1].value='0';
    $('status').textContent='Pinned copy ready. Choose a table.';
  } catch(error) {$('status').textContent='Review refused: '+error.message;}
})();
