# Find diagnostics inside retained output

An operator can now locate a failure, decision or review note inside a retained
text artifact without exporting the whole file or guessing byte offsets. Search
uses the receipt binding and saved manifest already used by `browse-retention`.
Each read verifies the complete selected file against its saved fingerprint.

```text
browse-retention search build.log --query error --ignore-case --limit 1 < receipt-binding.json
browse-retention search build.log --query error --ignore-case --after-line 3 --json < receipt-binding.json
```

Use the existing `MOONFORT_EXECUTOR_CONFIG`. The binding must contain the five
fields documented by the artifact browser: `protocol_version`, `retention_id`,
`workspace_id`, `approval_digest`, and `command_digest`. `list` locates the file;
`search` locates relevant lines inside that file. `preview` and `export` remain
available when an excerpt needs more surrounding context.

## Results and continuation

- Literal substring search, case-sensitive by default. `--ignore-case` folds
  ASCII A–Z only; it does not perform locale-specific Unicode case folding.
- Results are one hit per matching line, in source order, with 1-based line
  numbers. Repeated occurrences on the same line count once. CRLF and LF line
  endings are supported. A final newline does not add a phantom empty line.
- Excerpts show the first occurrence, up to 40 UTF-16 units before and 80 after
  the query, extending to a character boundary where necessary. Omission flags
  in JSON and ellipses in human output distinguish excerpts from whole lines.
- JSON includes the receipt binding, file fingerprint, query/case mode, total
  lines, matching-line count, matches, `next_after_line`, and `has_more`.
- If `has_more` is true, pass `next_after_line` as `--after-line`, keeping the
  same file, query and case mode. The cursor excludes that previously returned
  line. Every page rereads and verifies the file; changed bytes refuse.
- The response respects the configured protocol byte ceiling. A page can
  contain fewer hits than the requested limit. Text output escapes terminal
  control and bidirectional formatting characters.

## Deliberate limits

One UTF-8 text file at a time, up to 1 MiB and the existing export/disk limit.
Queries must contain 1–128 UTF-8 bytes, without CR, LF or NUL. Files containing
NUL or invalid UTF-8 refuse. Limits are 1–100 hits per page, default 20. Search
is not a regular-expression engine or an index; each page scans the whole file
to report a consistent total. A cursor beyond the end refuses. Missing files,
expired records, mismatched receipt bindings and changed fingerprints refuse.

This is read-only inspection of generated output, not execution, approval,
promotion or acceptance. It does not qualify a sandbox backend or change the
authority represented by a receipt. JSON is data: downstream renderers must
escape it for their own presentation context.
