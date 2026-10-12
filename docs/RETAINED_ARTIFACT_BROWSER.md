# Browse retained generated files

`browse-retention` opens the ordinary files a completed run retained for review.
Use it when a task produces a report, CSV, JSON, image, or other generated file
and the receipt's path list is not enough to inspect the result. The separate
`read-command-output` command still retrieves terminal output.

The workflow is: copy one receipt's identity → list/filter its generated files
→ preview a file → export that exact file for inspection. This is a local CLI
and typed API; there is no new MoonClaw or MoonDesk panel.

## Use an existing execution result

Build `cmd/browse-retention` with `moon build cmd/browse-retention --target native
--frozen`. Its default binary is
`_build/native/debug/build/cmd/browse-retention/browse-retention.exe`.
The examples below assume that binary is installed as `browse-retention` and
the existing trusted `MOONFORT_EXECUTOR_CONFIG` is set.

Copy the retention ID, approval digest, and command digest from one receipt
into a local `receipt-binding.json`. Use the `workspace_id` from that task's
original approved grant (the receipt itself does not carry this field).
Keep the digests unchanged:

```json
{
  "protocol_version": 1,
  "retention_id": "COPY_RECEIPT_RETENTION_ID",
  "workspace_id": "COPY_ORIGINAL_GRANT_WORKSPACE_ID",
  "approval_digest": "COPY_RECEIPT_APPROVAL_DIGEST",
  "command_digest": "COPY_RECEIPT_COMMAND_DIGEST"
}
```

These placeholders are intentionally unusable. This read-only identity is
neither an approval grant nor a promotion request.

```sh
browse-retention list < receipt-binding.json
browse-retention list --prefix reports/ --contains .csv < receipt-binding.json
browse-retention list --prefix reports/ --limit 2 --json < receipt-binding.json
browse-retention list --prefix reports/ --limit 2 --after reports/details.json --json < receipt-binding.json
browse-retention preview reports/launch-summary.md < receipt-binding.json
browse-retention preview notes/review.txt --offset 0 --bytes 1024 --json < receipt-binding.json
browse-retention export reports/checks.csv < receipt-binding.json > new-checks.csv
```

Paths are literal, case-sensitive, relative to this run's retained scratch.
`--prefix` and `--contains` combine with AND. List order is lexical by path;
repeat the same filters with the returned `next_after` to fetch another page.
`total_files`/`total_bytes` describe the whole manifest;
`matched_files`/`matched_bytes` describe all matching files, including later pages.
An empty filter result succeeds with zero matches. Default page size is 50;
maximum is 200, reduced further when the protocol byte budget requires it.

Listing describes the saved manifest, not a new verification of every file.
The preview/export step reads the selected regular file without following
symlinks and checks its complete bytes against the retained size and SHA-256.
Unlisted scratch files cannot be opened through this reader.

## Preview and save

Human preview prints the path, digest, byte range, readable UTF-8 text, and an
end/more marker. Terminal control characters are visibly escaped. A binary
or split UTF-8 page asks you to use JSON or export instead of corrupting it.
JSON previews return `content_base64`, `offset`, `next_offset`, and `eof` plus
the bound identity and saved file metadata. Offsets count bytes, not characters.
Concatenate decoded pages before decoding UTF-8. Repeated cursors return the
same saved revision while it remains available; replace a retried range rather
than appending it twice. `--bytes` defaults to 4096 and is capped at 32768.

Export verifies one complete file before emitting its exact bytes to stdout,
including binary data, empty files, and missing final newlines. It adds no
header or newline. A refused export exits nonzero with stderr and no artifact bytes.
Shell redirection opens/truncates its destination before the reader starts:
use a new filename and check exit status before using the file.

Preview and export are bounded to the smaller of 16 MiB and the configured
scratch disk allowance. Larger files remain listable and are labeled as over
the export limit. Each preview page rereads and hashes the full file; prefer
export for a complete download. This reader does not stream very large files.

Expiry, consumed/claimed retention, unknown paths, changed bytes, wrong receipt
bindings, and unavailable files refuse. Reading never extends retention,
consumes grants, launches a command, or changes the workspace. Export is an
inspection copy, not a promotion or acceptance receipt; use the existing
reviewed promotion workflow for durable canonical changes.

## Disposable six-file example

`examples/retention-browser/prepare-demo.mbtx` makes a new private synthetic
store from the checked-in Maple release samples. It also creates a seven-byte
binary measurement and an empty file. It starts no backend, writes no grant,
and needs no account or provider. Choose a new absolute directory:

```sh
moon run examples/retention-browser/prepare-demo.mbtx -- "$PWD/examples/retention-browser" /tmp/moonfort-artifact-demo
MOONFORT_EXECUTOR_CONFIG=/tmp/moonfort-artifact-demo/config.json browse-retention list < /tmp/moonfort-artifact-demo/receipt-binding.json
MOONFORT_EXECUTOR_CONFIG=/tmp/moonfort-artifact-demo/config.json browse-retention preview reports/launch-summary.md < /tmp/moonfort-artifact-demo/receipt-binding.json
MOONFORT_EXECUTOR_CONFIG=/tmp/moonfort-artifact-demo/config.json browse-retention export reports/checks.csv < /tmp/moonfort-artifact-demo/receipt-binding.json > /tmp/maple-checks-copy.csv
cmp /tmp/maple-checks-copy.csv examples/retention-browser/files/reports/checks.csv
```

The demo uses exact script dependencies async 0.22.4 and x 0.5.5, independent
of the unchanged product graph. Its synthetic record expires after 24 hours;
create a new demo directory when needed. Do not install its fixture config as
a real executor deployment or infer execution/containment from it.

## Tests and scope

Focused tests exercise multi-file discovery, combined filters and repeatable
pagination, byte previews across Unicode boundaries, binary/empty exports,
and an exact 100,000-row CSV export through both the API and compiled CLI,
receipt selection, limits, and unavailable revisions. Set
`MOONFORT_ARTIFACT_READER_CLI` to the freshly built executable to enable the
compiled CLI journey in `executor/retention_browser_cli_wbtest.mbt`; optionally
set `MOONFORT_ARTIFACT_EVIDENCE` to save its readback outputs. Run:

```sh
moon test executor/retention_browser_wbtest.mbt executor/retention_browser_cli_wbtest.mbt executor/retention_browser_large_wbtest.mbt cmd/browse-retention/main_wbtest.mbt --target native --frozen
```

The tests use synthetic completed-retention fixtures. They establish retrieval
and exact local output readback, not sandbox execution, graphical UI, AEN,
macOS, production deployment, or a wider test-suite pass.

For numeric durations or quantities, [decimal CSV aggregation](RETAINED_CSV_AGGREGATES.md)
provides exact grouped totals, min/max/mean, explicit missing counts, a whole-report
total, and original source-row drillback through `aggregate-csv`.
