# Retrieve completed command output

When a command's screen output is shortened, the execution receipt can contain
an `output_artifact`. The new trusted `cmd/read-command-output` controller lets
an operator save the complete retained output or lets a host read resumable byte
chunks. It does not run the command again. Small inline-only results need no
reader; their complete output is already in the receipt.

This release provides a CLI and typed MoonFort API. It does not add a MoonClaw or
MoonDesk download button, install a reader automatically, or map a spool artifact
to another product's file store. A future client must use a fixed trusted reader
deployment and retain the originating receipt's bindings.

## Request

Copy the unchanged `output_artifact`, `run_id`, `approval_digest`, and
`command_digest` from the same execution receipt. The request is a closed JSON
object; extra fields, host paths, and commands are rejected. Example shape:

```json
{
  "protocol_version": 1,
  "reference": {
    "artifact_id": "COPY_EXACT_ARTIFACT_ID",
    "run_id": "COPY_EXACT_RUN_ID",
    "sha256": "COPY_EXACT_SHA256",
    "size_bytes": "2097152",
    "media_type": "text/plain; charset=utf-8",
    "expires_at_ms": "0",
    "key_id": "COPY_EXACT_KEY_ID",
    "signature": "COPY_EXACT_SIGNATURE"
  },
  "run_id": "COPY_EXACT_RUN_ID",
  "approval_digest": "COPY_EXACT_APPROVAL_DIGEST",
  "command_digest": "COPY_EXACT_COMMAND_DIGEST",
  "offset": "0",
  "max_bytes": 2097152
}
```

The placeholders and expiry above are deliberately unusable. Use the complete
signed reference returned by the executor. A request is not a new approval and
does not extend expiry. `max_bytes` must be positive and within the executor's
configured output ceiling.
MoonBit's existing wire format encodes Int64 values (`offset`, `next_offset`,
`size_bytes`, and `expires_at_ms`) as decimal strings. `max_bytes` and
`protocol_version` are JSON numbers. This preserves the signed reference's
existing representation. The reader requires a trusted protocol budget of at
least 4096 bytes.

## Save the full output

Use the executor's already configured trusted environment. Set `offset` to zero
and `max_bytes` to at least the signed `size_bytes` (use 1 for an empty output).
Then invoke the installed reader:

```sh
read-command-output --export < output-request.json > command-output.txt
```

For a source checkout, `moon build cmd/read-command-output --target native
--frozen` produces
`_build/native/debug/build/cmd/read-command-output/read-command-output.exe`;
use that explicit executable path in place of `read-command-output`. The
trusted `MOONFORT_EXECUTOR_CONFIG` environment must already be configured.

`--export` validates the full retained object exactly once and writes its exact
bytes to standard output once, without base64 or a trailing newline. Validation
finishes before any output bytes are written. A refused export exits nonzero,
writes a generic diagnostic to standard error, and emits no output bytes. Shell
redirection creates or truncates the destination before the reader runs, so use
a new filename and check the exit status before using that file. The reader
accepts no destination path and does not promote sandbox changes.

## Resume a host download

Without `--export`, standard output is one JSON `CommandOutputReadResponse`:

- `reference`: the exact unchanged signed reference on success
- `offset` and `next_offset`: byte cursors
- `content_base64`: exact bytes, which may split a UTF-8 character
- `eof`: true only when the verified object ends at `next_offset`
- `status`: `available`, `expired`, `unavailable`, or `refused`
- `error`: a bounded code and message, or null

Ask for a page, append decoded bytes only after validating the returned identity
and cursor, then retain `next_offset`. Repeating the same cursor returns the same
bytes while the artifact remains valid. A host must replace a repeated range,
not append it twice. Reading exactly at end returns an empty successful page
with `eof: true`; a cursor beyond end is refused.

Pages are capped at 32 KiB and reduced further to fit the trusted protocol
budget. Every page reuses the existing full-object signature, binding, expiry,
regular-file, size, and SHA-256 verifier. This costs a full read/hash per page;
prefer `--export` or `export_command_output` for a complete multi-megabyte file.
There is no verification cache and no weaker partial-range integrity path.

Expired or missing output remains unavailable. Changed bytes, forged references,
wrong receipt bindings, unsafe paths, and invalid cursors return no content.
Clients must not respond by rerunning execution, minting a grant, extending
retention, or falling back to a host path. `output_truncated` still means the
original command hit its approved hard ceiling: export recovers all retained
bytes, not bytes the executor never captured.

## Verification scope

The focused fixture tests create private retained-output records directly,
without starting a sandbox command or contacting a provider. They cover
multi-page Unicode/NUL bytes, duplicate reads, final and invalid cursors,
protocol bounds, empty output, wrong identities, expiry, missing/substituted
bytes, full-file export, and a 2 MiB single-export timing sample. The export
implementation contains one call to the existing full-object reader and no page
loop. Empty approval-consumption and scratch directories verify that retrieval
did not execute a command. None of this qualifies a sandbox deployment.

Run the focused checks, including the optional CLI integration leg, with:

```sh
moon build cmd/read-command-output --target native --frozen
MOONFORT_OUTPUT_READER_CLI="$PWD/_build/native/debug/build/cmd/read-command-output/read-command-output.exe" moon test executor/command_output_read_wbtest.mbt executor/command_output_read_test.mbt executor/output_artifact_wbtest.mbt --target native --frozen
```

That environment variable enables exact 2 MiB stdout and destination-file
readback, a JSON-page response, and a refused export with empty stdout and
nonzero exit status. Without it, only the typed API/spool fixture cases run.
