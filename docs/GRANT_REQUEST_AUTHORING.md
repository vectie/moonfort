# Author an ordinary bounded command REQUEST offline

An operator can prepare the existing v3 `GrantPublicationRequest` without hand
editing the complete request document. This is a request-authoring aid for the
operator, not a founder-facing approval console or a trusted publisher.

```sh
# Node 20+; choose a private output directory that already exists.
umask 077
node tools/grant-request-form.mjs > /private/output/grant-request-form.html
```

Open that local HTML file in a modern browser. No server, package installation,
network, browser storage, executor configuration or credentials are needed.
The generator accepts no template or output-path arguments and emits only HTML
to standard output. Select the output directory yourself; do not overwrite a
protected file. The generated page contains no template until you open one.

## Operator journey

1. Choose an existing ordinary v3 publication REQUEST JSON template, at most
   64 KiB, then explicitly click **Open template**. Selecting a file alone does
   not read it. Do not select a protected executor config, credential file,
   published grant, invocation, approval response, or rehearsal response.
2. Edit `approval_id`, `request_id`, the opaque registered `workspace_id`, safe
   workspace-relative `working_directory` as one JSON string (including quotes),
   exact decimal-string expiry, and
   any of the six resource limits. Limits remain requested values; the page
   does not know deployment ceilings or workspace mappings. Use `""` for the
   workspace root, `"src/check"` for a normal relative directory, and escaped
   `"src\r\nreview"` if CR/LF are genuinely part of the directory name. This
   lossless encoding prevents HTML text inputs from silently stripping CR/LF.
3. Edit each argument independently. Each box is one JSON string, including
   quotes. For example, `"two words"` is one argument, `""` is an empty argument,
   and `"line\nnext"` contains a newline. Add or remove arguments using the
   corresponding buttons. This deliberate string encoding preserves CR/LF,
   quotes, backslashes, leading/trailing spaces and Unicode without browser
   text-input normalization or shell parsing. Arguments are never joined or
   split into a command line.
4. Inspect the fixed template policy. `backend`, `backend_config_id`,
   `enforcement_requirement`, network mode, egress and command capability
   arrays, command tool, and protocol versions stay explicit and unchanged.
   Supply a different operator template to request a different policy. No
   `AllowDegraded` choice is inserted implicitly.
5. Click **Preview exact REQUEST** and review every field. The full displayed
   JSON, including its final newline, is exactly the download body. Every
   edit, reset, replacement or cancel revokes the preview. Download also
   revalidates expiry and compares every field, guarding against a stale
   preview even when a control changed without an input event.
6. Click **Download REQUEST JSON**. The fixed filename is
   `moonfort-request.json`. This downloads an ordinary version-3 request with
   no approval flag, signature, review digest or new protocol extension.
7. Separately follow [grant rehearsal and approval](GRANT_REHEARSAL.md): the
   trusted operator runs `grant-publisher --check` using protected executor
   configuration, corrects policy failures, reviews exact candidate and host
   bindings with the named approver, and uses the existing publication flow
   only after actual approval. Do not treat local preview or download as a
   grant, approval, native check, execution, or enforcement qualification.

**Reset to opened template** restores the original parsed request and requires
another preview. **Cancel and clear** discards template and preview from the
page, including any late asynchronous file read. It does not delete prior
browser downloads. A newer selected/opened file cannot be replaced by a stale
read finishing later. A malformed replacement clears the old candidate.

## Supported shape and bounds

Only the exact v3 wrapper `{ "protocol_version": 3, "grant": ... }` and its
known fields are accepted. Missing or extra fields are rejected. The command
must be the existing `Exec` tuple with a tool and an argument array. `Shell`
and `shell-compat` authoring are excluded. `LocalOs` and `MicroVm` templates
are accepted, with explicit `AllowDegraded` or `RequireEnforced`; this does not
claim either combination will pass native policy or execution-time checks.

The page is deliberately bounded to 64 KiB input and pretty-printed output,
256 arguments, positive Int32 resource values, valid Unicode without NUL,
128-character safe IDs and a 4096-byte relative directory. Expiry remains an
exact nonnegative Int64 decimal string, including values above JavaScript's
safe-number range; it must be in the future at preview and download. The native
publisher may impose tighter deployment limits and remains authoritative.
An expired template can be opened so its expiry can be corrected.

Untrusted template text is assigned only to text/value properties, never HTML.
The generated page declares hash-bound script/style CSP, denies connections,
and has no network/storage APIs or publisher/executor bridge. Files remain in
memory until reset/replaced/canceled or the page is closed. Browser-managed
saved downloads and the original template remain the operator's responsibility.

## Bounded tests and evidence

```sh
node tests/grant-request-form.mjs
# Exact native closure verification must precede any retained binary test:
# use the accompanying round run-focused.sh for the native check-only run.
```

The Node test executes the actual script emitted into the HTML against a small
DOM/event harness, including actual Blob/download handlers and a narrow model
of HTML text-input CR/LF sanitization. Directory and argument JSON strings are
round-tripped through that model, including reset and native digest equality. It tests explicit
file reading, edits, add/remove, zero/empty/escaped arguments, exact preview and
download, expiry, invalid types and bounds, unknown fields, strict policy
preservation, repeated actions, failed replacements, stale asynchronous reads,
reset and cancel. It does not qualify a full browser, file picker, download
manager, CSP enforcement, accessibility tooling or browser history behavior.

The round's focused runner first invokes the unchanged R579 `verify-build.mjs`
against its `build-receipt.json`, then verifies all 193 recorded source files
against the current source and permits only the two new noncompiled authoring
and test modules. Both retained native artifacts are rehashed. No compilation
or dependency copy is performed. The actual retained native publisher is then
invoked with **only `--check`**, using private synthetic configuration and the
real form-handler download. It verifies exact candidate equality, repeated
checks, resource correction/recheck, unknown workspace and expired request, plus exact original/download equality
and identical native review digests for a CR/LF-containing directory.
Approval stores, scratch, retention, workspace, configuration and synthetic tool
are snapshot-compared after every check; a target-process sentinel must remain
absent. Disposable fixtures are retained inside the round's private worker.

These are development compatibility checks, not release, native containment,
production AEN/Firecracker, hostile-host, full-browser, or physical-runtime
qualification. No real approval, grant publication, grant consumption, backend
probe, payload execution, permission change or deployment is performed.
