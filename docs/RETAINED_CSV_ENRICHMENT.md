# Add local reference data to a retained CSV report

`browse-retention enrich-csv` appends fields from a local CSV lookup to a verified
retained CSV artifact. For example, join a generated checks report's `area`
column to an ownership directory, adding owner and follow-up notes while keeping
every source row in its original order. The output is an ordinary reusable CSV
candidate, with a separate machine-readable provenance record.

This is local data integration after inspection. It does not run a workload,
modify either input, change a receipt, consume a grant, accept knowledge, or
promote files. The local lookup is supplied reference data; its digest is not
an executor attestation or evidence that its contents are correct.

## Command

Use the compiled command so build diagnostics cannot mix with the context:

```sh
export MOONFORT_EXECUTOR_CONFIG=/absolute/path/to/existing-executor-config.json
browse-retention enrich-csv checks.csv \
  --lookup local-owners.csv --source-key 2 --lookup-key 1 \
  --lookup-columns 2,3 --prefix ref_ \
  < receipt-binding.json > new-candidate.csv 2> new-candidate.context.json
```

- `PATH` is the exact relative artifact path in the bound retained result.
- `--lookup` reads an existing local regular UTF-8 CSV file, at most 1 MiB.
- Both key columns are required, one-based numeric positions. The first logical
  record is the header, and is never joined as a data row.
- `--lookup-columns` appends the selected positions in that order. Omit it to
  append every lookup column except its key. Selection must be nonempty and
  contain no repeated positions. The key itself may be explicitly selected.
- `--prefix` prefixes appended header names, default `lookup_`. Use `ref_` or
  another meaningful prefix to make the source of each field clear.

Source rows are left-joined by exact, case-sensitive string equality. There is
no trimming, normalization or numeric coercion: `01`, `1`, `A`, `a`, and ` A`
are distinct keys. Repeated source keys reuse the same lookup values. Lookup
keys must be nonempty and unique; duplicate keys refuse instead of choosing one
row or multiplying the source rows. Missing and empty source keys append empty
cells. An empty lookup table is allowed if its header supplies selected columns.
An empty source table produces only the enriched header.

Headers may be blank or duplicated, including collisions introduced by a prefix.
Columns remain unambiguous by their numeric positions, matching the retained CSV
browser. Missing matches and matched empty lookup values both produce empty
cells; context counts distinguish the overall match coverage, not individual
empty cells. To distinguish them per row, explicitly include the nonempty lookup
key among `--lookup-columns`.

## Output and provenance

On success stdout contains only the complete CSV candidate. Every field is
quoted, embedded quotes are doubled, and record endings use CRLF. Exact cell
strings, embedded newlines, leading zeroes, large integer strings, Unicode and
formula-looking cells remain unchanged. Nothing evaluates or neutralizes
formulas. Treat spreadsheet imports with the same care as the original data.

On success stderr is one JSON context record containing:

- `derived_candidate: true`, `derivation: moonfort-csv-left-join-v1`
- Original receipt binding and fingerprinted `source_file`
- SHA-256 and byte size of the exact supplied local lookup bytes
- One-based source/lookup key positions, selected lookup columns and prefix
- Source, lookup, matched, unmatched and unused-lookup row counts
- SHA-256 and byte size of the exact candidate bytes, including CRLF endings

Keep the candidate, context and exact lookup bytes together. Repeating the same
inputs and options produces the same candidate and context while the retained
record remains valid. Changing only lookup formatting changes its fingerprint,
even when parsed cells and resulting candidate are identical.

On failure exit status is nonzero and stderr is a diagnostic, not context.
All validation completes before output starts. I/O failure can still leave
partial redirected output; check status before using either file. Choose new
output paths: the shell creates/truncates them before the command starts.
Separate review and the destination's supported acceptance workflow are still
required. A derived candidate does not inherit the original artifact's digest.

## Limits and native API

Source, lookup and candidate are each at most 1 MiB. Each input has at most
20,000 data rows, 64 columns and 16,384 UTF-16 units per field. The joined result
must also fit 64 columns and its appended headers must fit the field limit.
The prefix is at most 128 UTF-16 units and cannot contain NUL. Invalid UTF-8,
malformed quoting, uneven record widths and NUL follow the existing CSV parser's
refusal behavior. Context must fit the configured protocol byte budget.

`enrich_retained_csv(binding, path, config, lookup, source_key~, lookup_key~,
lookup_columns?, prefix?)` returns `RetentionCsvEnrichment`. Its `csv` is the
candidate; `context()` returns provenance without candidate content or local
lookup path. The function reuses verified artifact retrieval and rechecks the
bound retained record. It writes no files. Callers must supply the exact lookup
bytes and retain them independently if future reproduction is needed.

This is one exact-key left join, not fuzzy matching, aggregation, a database
query language, a CSV editor, a new execution result, or a containment claim.

## Focused verification

Build `cmd/browse-retention` with the frozen native graph, set
`MOONFORT_ARTIFACT_READER_CLI` to the executable, then run
`executor/retention_csv_enrichment_wbtest.mbt`. Its five tests cover ordinary
joins, unmatched rows, repeated keys, Unicode/quoted multiline cells, exact
strings, empty tables, options, bounds, changed retained bytes and the actual
compiled local-file CLI. Set `MOONFORT_CSV_ENRICHMENT_EVIDENCE` to an existing
private directory to retain synthetic input and actual command output examples.
