# Export a retained review package

`browse-retention bundle` exports a selected multi-file result as one ordinary
ZIP. Open its CSV, JSON, Markdown, binary or Unicode-named files in familiar
review tools without repeatedly retrieving each artifact. This extends the
retained browser and PRD W04/W06 review handoff; it does not change any execution,
acceptance or promotion authority.

Use the existing executor configuration and the same five-field receipt binding
as `list`, `preview` and `export`:

```text
browse-retention list --prefix reports/ < receipt-binding.json
browse-retention bundle --prefix reports/ < receipt-binding.json > review.zip
unzip -l review.zip
unzip -p review.zip artifacts/reports/checks.csv
browse-retention bundle --contains .csv < receipt-binding.json > csv-review.zip
```

Filters are literal and case-sensitive. With no filters all retained manifest
files are selected. The command collects all matching list pages automatically;
there is no page limit option that silently drops files. No matches is an error.
For an exact arbitrary selection, call the native public API
`export_retained_bundle(binding, paths, config)` with distinct relative paths.

## Package layout and meaning

- `manifest.json`: format version 1, review-only purpose, complete original
  receipt/workspace/digest binding, source expiry, sorted selected file metadata
  and digests, combined uncompressed artifact byte count.
- `artifacts/<original relative path>`: exact verified retained bytes. The
  reserved prefix keeps an artifact named `manifest.json` distinct from metadata.

The package contains no host storage paths, executor configuration, keys, grant,
or execution authority. Its binding is identification, not a signed transferable
attestation. Source expiry governs retrieval; a downloaded copy does not disappear
at expiry. Treat the whole ZIP as potentially private output and review sharing
separately. Extract into a fresh review directory using a trusted ZIP reader.
Do not extract over a canonical workspace as a promotion shortcut.

Every selected file is checked against its saved digest before any archive bytes
are returned. A changed, missing, expired or promotion-locked source refuses.
The saved record is rechecked during and after collection. The ZIP is a copy of
verified recorded bytes, not a filesystem snapshot or a promise that scratch
will never change afterward. The implementation does not execute or consume
approval, write retained state, or promote artifacts.

## Deliberate bounds

1..200 files; at most 16 MiB combined artifact bytes and the configured disk
limit, whichever is smaller. Relative path UTF-8 is at most 4096 bytes. Metadata
and ZIP headers add modest bounded overhead. ZIP store method, UTF-8 names,
fixed 1980-01-01 timestamps; no compression, directory entries, executable bits,
symlinks or ZIP64. Output is deterministic for the same retained record/selection.
A single invalid selection fails the whole operation, never silently skips files.

The archive is assembled in memory before stdout. Check exit status; shell
redirection may create/truncate the destination before a refusal and I/O failure
may leave a partial file. Prefer a fresh temporary output name, then rename only
on success. Retained output remains separate from reviewed promotion. This
feature establishes no stronger sandbox or backend enforcement claim.
