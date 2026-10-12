# Find diagnostic lines across a retained run

Use this when you know the message to find but not which retained file contains
it. `search-all` scans the selected retained manifest in lexical path order,
returns matching one-based line numbers and readable excerpts, and includes the
original receipt binding and each matching file's saved SHA-256 fingerprint.
It does not run a payload, consume approval, write a retained file or promote it.

With the existing trusted `MOONFORT_EXECUTOR_CONFIG` and the five-field
`receipt-binding.json` accepted by `browse-retention`:

```sh
browse-retention search-all --query error --ignore-case --prefix logs/ \
  --limit 20 < receipt-binding.json
browse-retention search-all --query error --ignore-case --prefix logs/ \
  --limit 20 --json < receipt-binding.json > new-search-page.json
```

The query is literal, not a regular expression. `--ignore-case` folds ASCII only.
`--prefix` and `--contains` are literal, case-sensitive path filters used together.
Searching without them selects all regular files in the retained manifest;
new scratch files absent from that manifest are not searched.

## Continue a result

When `has_more` is true, take both `next_after_path` and `next_after_line` from
the JSON result. Pass the literal decoded path and integer line to:

```sh
browse-retention search-all --query error --ignore-case --prefix logs/ \
  --after-path 'logs/build.log' --after-line 42 --limit 20 --json \
  < receipt-binding.json > new-next-page.json
```

Keep the same binding, query, case mode and path filters. The path/line pair is
an exclusive position in lexical path / increasing line order. `after_line=0`
starts before the named file's first line. An absent, filtered-out, skipped or
out-of-range cursor refuses. Counts cover the whole selected corpus on every
page; a repeated request is deterministic while evidence remains valid.

One match represents a matching line, even if the query occurs several times.
Excerpts show the first occurrence with up to 40 UTF-16 units before it and 80
after it, preserving whole Unicode characters. Ellipses/omission flags identify
truncation. LF delimits lines and a trailing CR is stripped from each displayed
line, supporting CRLF logs. A terminal LF creates no extra line. Export the
original artifact if you need exact bytes or complete lines.

## Understand coverage

The response gives selected, searched and matching file counts, searched bytes,
and total matching lines. Every skipped file is listed with its manifest entry:

- `over_1_mib`: larger than 1 MiB; bytes were not read or verified
- `invalid_utf8`: bytes verified against the manifest, but not UTF-8 text
- `contains_nul`: bytes verified, but contains NUL and was not text searched

A result with skipped files is not a complete content search of those files.
Inspect them separately with preview/export. Missing, changed, unreadable or
expired evidence fails the entire request rather than quietly becoming a skip.
The API returns `RetentionRunSearch`; `search_retained_run` exposes the same
query, filters, cursors and limits as the CLI. Machine-readable match entries
contain `file` (path, fingerprint and size) and `hit` (line, excerpt and flags).
As in existing MoonFort responses, Int64 byte counts serialize as decimal strings.

## Limits and boundaries

- Query: nonempty, at most 128 UTF-8 bytes; no CR, LF or NUL
- At most 128 selected files; at most 8 MiB in files eligible for text decoding
- Each text candidate: at most 1 MiB; page limit 1–100 (default 20)
- JSON including its newline fits the configured protocol budget; pages can
  contain fewer matches than requested. Narrow filters if metadata alone or one
  match cannot fit. Nothing is silently dropped to meet the budget.
- All eligible selected files are read and reverified on each page, including
  files before the cursor. Over-limit corpora refuse with a narrower-filter hint.
- Fingerprints identify verified bytes read, not an atomic filesystem snapshot.
  The retention record is rechecked before returning, but no snapshot is locked.

Text output escapes terminal controls. JSON preserves excerpt strings for
consumers, which should render them as text. Check exit status before consuming
redirected output; shell redirection creates or truncates its destination before
the command runs, so use new output paths. This feature qualifies retained
inspection only, not execution containment, promotion, a provider or deployment.
