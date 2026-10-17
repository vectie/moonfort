#!/usr/bin/env node
// Offline request authoring only. This module has no publisher/executor binding.
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';

export function requestAuthoringRuntime() {
  const MAX_BYTES = 65536, MAX_ARGS = 256;
  const limitKeys = ['wall_clock_ms','cpu_seconds','memory_mib','disk_mib','processes','output_bytes'];
  const grantKeys = ['protocol_version','approval_id','request_id','workspace_id','backend','enforcement_requirement','network','allowed_egress','allowed_commands','limits','working_directory','command','backend_config_id','expires_at_ms'];
  const editableKeys = ['approval_id','request_id','workspace_id','working_directory','expires_at_ms'];
  const bytes = value => new TextEncoder().encode(value).length;
  const clone = value => JSON.parse(JSON.stringify(value));
  const require = (condition, message) => { if (!condition) throw Error(message); };
  function keys(value, expected, label) {
    require(value !== null && typeof value === 'object' && !Array.isArray(value), label+' must be an object');
    require(Object.keys(value).sort().join('|') === [...expected].sort().join('|'), label+' has missing or unsupported fields');
  }
  function text(value, label) {
    require(typeof value === 'string' && !value.includes('\0') && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value), label+' must be a valid Unicode string without NUL');
  }
  function identifier(value, label) { require(typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value), label+' must be 1–128 letters, digits, underscores or hyphens'); }
  function validate(request, now = null) {
    keys(request, ['protocol_version','grant'], 'Request');
    require(request.protocol_version === 3, 'Only ordinary v3 publication REQUEST templates are supported');
    const g = request.grant;
    keys(g, grantKeys, 'Request grant');
    require(g.protocol_version === 3, 'Grant protocol_version must be 3');
    for (const key of ['approval_id','request_id','workspace_id']) identifier(g[key], key);
    require(['LocalOs','MicroVm'].includes(g.backend), 'An explicit supported backend is required');
    require(['RequireEnforced','AllowDegraded'].includes(g.enforcement_requirement), 'Explicit enforcement_requirement is required');
    require(['Deny','AllowList','Unrestricted'].includes(g.network), 'Explicit network mode is required');
    identifier(g.backend_config_id, 'backend_config_id');
    for (const key of ['allowed_egress','allowed_commands']) {
      require(Array.isArray(g[key]) && g[key].length <= 256, key+' must be a bounded string array');
      g[key].forEach(value => text(value,key));
      require(new Set(g[key]).size === g[key].length, key+' must contain no duplicates');
    }
    g.allowed_commands.forEach(value => identifier(value,'allowed_commands entry'));
    keys(g.limits, limitKeys, 'limits');
    for (const key of limitKeys) require(Number.isInteger(g.limits[key]) && g.limits[key] > 0 && g.limits[key] <= 2147483647, 'limits.'+key+' must be a positive Int32 integer');
    text(g.working_directory,'working_directory');
    require(bytes(g.working_directory) <= 4096 && (g.working_directory === '' || (!g.working_directory.startsWith('/') && !g.working_directory.endsWith('/') && !g.working_directory.includes('//') && !g.working_directory.split('/').some(x=>x==='.' || x==='..'))), 'working_directory must be a safe workspace-relative directory');
    require(Array.isArray(g.command) && g.command.length === 2 && g.command[0] === 'Exec', 'Only pre-tokenized Exec templates are supported; Shell is not authored here');
    keys(g.command[1], ['tool','args'], 'Exec command');
    identifier(g.command[1].tool, 'Exec tool');
    require(g.command[1].tool !== 'shell-compat', 'Shell compatibility is not authored here');
    require(g.allowed_commands.includes(g.command[1].tool), 'Exec tool must appear in the template allowed_commands');
    require(Array.isArray(g.command[1].args) && g.command[1].args.length <= MAX_ARGS, 'At most 256 individual arguments are supported');
    g.command[1].args.forEach(arg => { text(arg,'Argument'); require(bytes(arg) <= MAX_BYTES,'Argument is too large'); });
    require(typeof g.expires_at_ms === 'string' && /^(0|[1-9][0-9]{0,18})$/.test(g.expires_at_ms) && BigInt(g.expires_at_ms) <= 9223372036854775807n, 'expires_at_ms must be an exact nonnegative Int64 decimal string');
    if (now !== null) require(BigInt(g.expires_at_ms) > BigInt(now), 'Request has expired; enter a future decimal-string expiry and preview again');
    require(bytes(JSON.stringify(request, null, 2)+'\n') <= MAX_BYTES, 'Request exceeds the 64 KiB authoring limit');
    return request;
  }
  function parse(raw) {
    require(typeof raw === 'string' && bytes(raw) <= MAX_BYTES, 'Template exceeds the 64 KiB authoring limit');
    let value;
    try { value = JSON.parse(raw); } catch { throw Error('Template must be valid JSON'); }
    return validate(value);
  }
  function mount(doc, platform = {}) {
    const get = id => doc.getElementById(id);
    const now = platform.now || (() => Date.now());
    const urls = platform.URL || URL, BlobType = platform.Blob || Blob;
    const schedule = platform.setTimeout || setTimeout;
    let template = null, revision = 0, preview = null, loadEpoch = 0;
    const inputs = {}, argInputs = [];
    function message(value) { get('status').textContent = value; }
    function invalidate() {
      revision++; preview = null;
      get('preview-json').textContent = '';
      get('download').disabled = true;
      message(template ? 'Draft changed. Preview the exact request before downloading.' : 'Choose a v3 REQUEST template, then open it.');
    }
    function clear() {
      loadEpoch++; template = null; invalidate();
      get('editor').disabled = true; get('reset').disabled = true;
      get('authority').textContent = ''; get('fields').replaceChildren(); get('arguments').replaceChildren();
      get('template-file').value = ''; argInputs.length = 0;
      for (const key of Object.keys(inputs)) delete inputs[key];
    }
    function run(action) {
      try { return action(); } catch (error) { invalidate(); message(error.message); return null; }
    }
    function inputRow(parent, label, value) {
      const row = doc.createElement('label'); row.className = 'field';
      const title = doc.createElement('span'); title.textContent = label;
      const input = doc.createElement('input'); input.type = 'text'; input.value = value; input.autocomplete = 'off'; input.spellcheck = false;
      input.addEventListener('input', invalidate);
      row.append(title,input); parent.append(row);
      return input;
    }
    function addArgument(value) {
      require(template, 'Open a template first');
      require(argInputs.length < MAX_ARGS, 'At most 256 individual arguments are supported');
      const row = doc.createElement('div'); row.className = 'argument';
      const label = doc.createElement('label'); label.className = 'field';
      const title = doc.createElement('span');
      const input = doc.createElement('input'); input.type = 'text'; input.value = JSON.stringify(value); input.autocomplete = 'off'; input.spellcheck = false;
      const remove = doc.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove';
      const entry = {row,title,input,remove}; argInputs.push(entry);
      const number = () => argInputs.forEach((item,index)=> { item.title.textContent = 'Argument '+index+' (JSON string)'; item.remove.setAttribute('aria-label','Remove argument '+index); });
      input.addEventListener('input',invalidate);
      remove.addEventListener('click',()=> { const index=argInputs.indexOf(entry); if(index<0) return; argInputs.splice(index,1); row.remove(); number(); invalidate(); });
      label.append(title,input); row.append(label,remove); get('arguments').append(row); number();
    }
    function render() {
      get('fields').replaceChildren(); get('arguments').replaceChildren(); argInputs.length = 0;
      const g = template.grant;
      for (const key of editableKeys) inputs[key] = inputRow(get('fields'),key,key === 'working_directory' ? JSON.stringify(g[key]) : g[key]);
      for (const key of limitKeys) {
        inputs['limits.'+key] = inputRow(get('fields'),'limits.'+key,String(g.limits[key]));
        inputs['limits.'+key].inputMode = 'numeric';
      }
      const authority = {};
      for (const key of ['protocol_version','backend','backend_config_id','enforcement_requirement','network','allowed_egress','allowed_commands']) authority[key] = g[key];
      authority.command_tool = g.command[1].tool;
      get('authority').textContent = JSON.stringify(authority,null,2);
      for (const arg of g.command[1].args) addArgument(arg);
      get('editor').disabled = false; get('reset').disabled = false; invalidate();
      message('Template opened. These are requested fields, not approval. Edit, then preview.');
    }
    function current() {
      require(template,'Open a template first');
      const request = clone(template), g = request.grant;
      for (const key of editableKeys) {
        if (key === 'working_directory') {
          try { g[key] = JSON.parse(inputs[key].value); } catch { throw Error('working_directory must be one JSON string, including quotes'); }
          require(typeof g[key] === 'string','working_directory must be one JSON string');
        } else g[key] = inputs[key].value;
      }
      for (const key of limitKeys) {
        const raw = inputs['limits.'+key].value;
        require(/^[1-9][0-9]{0,9}$/.test(raw),'limits.'+key+' must be a positive decimal integer');
        g.limits[key] = Number(raw);
      }
      g.command[1].args = argInputs.map(({input},index)=> {
        let arg;
        try { arg = JSON.parse(input.value); } catch { throw Error('Argument '+index+' must be one JSON string, including quotes'); }
        require(typeof arg === 'string','Argument '+index+' must be one JSON string');
        return arg;
      });
      return validate(request,now());
    }
    function serializeCurrent() { return JSON.stringify(current(),null,2)+'\n'; }
    get('template-file').addEventListener('change',()=> {
      // Selection alone never reads the file. Revoke the old candidate immediately.
      loadEpoch++; template = null; invalidate();
      get('editor').disabled = true; get('reset').disabled = true;
      get('authority').textContent = ''; get('fields').replaceChildren(); get('arguments').replaceChildren(); argInputs.length = 0;
      message('File selected. Click Open template to read it locally.');
    });
    get('open').addEventListener('click',async()=> {
      const epoch = ++loadEpoch;
      // Also revoke on repeated open, failed reads and canceled selection.
      template = null; invalidate(); get('editor').disabled = true; get('reset').disabled = true;
      get('authority').textContent = ''; get('fields').replaceChildren(); get('arguments').replaceChildren(); argInputs.length = 0;
      const file = get('template-file').files?.[0];
      if (!file) { message('Choose a v3 REQUEST template first.'); return; }
      if (file.size > MAX_BYTES) { message('Template exceeds the 64 KiB authoring limit'); return; }
      message('Reading the selected template locally…');
      try {
        const raw = await file.text();
        if (epoch !== loadEpoch) return;
        template = clone(parse(raw)); render();
      } catch (error) { if(epoch === loadEpoch) { template = null; invalidate(); message(error.message); } }
    });
    get('add-argument').addEventListener('click',()=>run(()=> { addArgument(''); invalidate(); }));
    get('preview').addEventListener('click',()=>run(()=> {
      const serialized = serializeCurrent(); preview = {serialized,revision};
      get('preview-json').textContent = serialized; get('download').disabled = false;
      message('Exact REQUEST preview ready. This is not approval, a published grant, or an enforcement check.');
    }));
    get('download').addEventListener('click',()=>run(()=> {
      const serialized = serializeCurrent();
      require(preview && preview.revision === revision && preview.serialized === serialized,'Preview is stale or missing. Preview the exact request again.');
      const url = urls.createObjectURL(new BlobType([serialized],{type:'application/json'}));
      const anchor = doc.createElement('a'); anchor.href = url; anchor.download = 'moonfort-request.json';
      try { doc.body.append(anchor); anchor.click(); } finally { anchor.remove(); schedule(()=>urls.revokeObjectURL(url),0); }
      message('REQUEST download prepared. A trusted operator must separately check policy and obtain named approval. Nothing was published or executed.');
    }));
    get('reset').addEventListener('click',()=>run(()=> { require(template,'Open a template first'); loadEpoch++; render(); message('Restored the opened template. Preview again before downloading.'); }));
    get('cancel').addEventListener('click',()=> { clear(); message('Canceled. Template and preview cleared from this page. Existing downloaded files are unchanged.'); });
    clear();
    return {current, inputs, argInputs};
  }
  return {parse,validate,mount};
}

export function generateHtml() {
  const script = `(${requestAuthoringRuntime.toString()})().mount(document);`;
  const style = 'body{font:16px system-ui,sans-serif;line-height:1.5;max-width:960px;margin:32px auto;padding:0 20px;color:#182337;background:#f5f7fa}h1{font-size:1.9rem}section,fieldset{background:white;border:1px solid #bbc6d5;border-radius:10px;padding:20px;margin:18px 0}legend{font-weight:bold}button,input{font:inherit}button{padding:8px 14px;margin:5px 6px 5px 0;cursor:pointer}button:disabled{cursor:default}input{box-sizing:border-box;width:100%;padding:8px;border:1px solid #8493a8;border-radius:4px}.field{display:block;margin:12px 0}.field span{display:block;font-size:.9rem;font-weight:600;margin-bottom:4px}#fields{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:0 20px}.argument{display:flex;align-items:end;gap:10px}.argument label{flex:1;min-width:0}.argument button{margin-bottom:12px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#eef2f7;padding:14px;border-radius:4px}#status{font-weight:600;border-left:4px solid #315a93;padding:10px}small{display:block}strong{color:#843515}button:focus-visible,input:focus-visible{outline:3px solid #315a93;outline-offset:2px}';
  const hash = text => createHash('sha256').update(text).digest('base64');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-${hash(script)}'; style-src 'sha256-${hash(style)}'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>MoonFort · Author a command request</title><style>${style}</style></head><body>
<h1>Author a bounded command request</h1>
<p><strong>A REQUEST is not approval or a grant.</strong> This offline page edits one ordinary v3 request. It cannot check trusted policy, publish a grant, run a command, or qualify enforcement.</p>
<section aria-label="Open request template"><label for="template-file">Choose an existing v3 REQUEST JSON template (64 KiB maximum)</label>
<input id="template-file" type="file" accept=".json,application/json"><button id="open" type="button">Open template</button><button id="cancel" type="button">Cancel and clear</button>
<small>Only the selected file is read, after Open template. No network, browser storage, directory scanning, or automatic downloads. Never open protected executor configuration or credential files here.</small></section>
<p id="status" role="status" aria-live="polite"></p>
<fieldset id="editor" disabled><legend>Requested scope</legend>
<p>Workspace is an opaque registered ID. Working directory is one JSON string, including quotes, relative to that workspace; "" means its root. Escapes preserve exact directory characters. Expiry is epoch milliseconds as an exact decimal string. Resource limits are requests subject to trusted ceilings.</p>
<div id="fields"></div>
<h2>Fixed template policy</h2><p>These explicit backend, enforcement, network and capability fields are preserved. A trusted operator must supply a different template to request another policy. They do not establish authority.</p><pre id="authority"></pre>
<h2>Individual command arguments</h2><p>Each box is one JSON string, including quotes: "two words" stays one argument; "" is an empty argument; "\\n" is a newline. No shell parsing, splitting or joining occurs.</p>
<div id="arguments"></div><button id="add-argument" type="button">Add empty argument</button>
<button id="preview" type="button">Preview exact REQUEST</button></fieldset>
<button id="reset" type="button" disabled>Reset to opened template</button>
<section aria-label="Exact request preview"><h2>Exact download preview</h2><p>Every edit or reset clears this preview. Expiry is checked again at download. Review all fields and argument boundaries.</p><pre id="preview-json"></pre><button id="download" type="button" disabled>Download REQUEST JSON</button></section>
<p>Next: the trusted operator separately runs grant-publisher --check against protected configuration, reviews the exact candidate and host bindings with the named approver, and follows the existing approval process. Passing that check still does not certify backend containment.</p>
<script>${script}</script></body></html>\n`;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 2) { console.error('Usage: node tools/grant-request-form.mjs > /private/path/grant-request-form.html'); process.exitCode = 2; }
  else process.stdout.write(generateHtml());
}
