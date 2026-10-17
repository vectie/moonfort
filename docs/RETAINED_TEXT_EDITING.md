# Retained plain-text editing

`browse-retention edit-text PATH --recipe LOCAL.json` derives a separate candidate
from a verified retained artifact. It writes exact candidate bytes to stdout and
a small provenance context to stderr. Keep original, recipe, candidate and
context together. A candidate is not a retained execution result or approval.

## Recipe

```json
{
  "version": 1,
  "source_fingerprint": "the lowercase SHA-256 from the inspected artifact",
  "operations": [
    {
      "start_line": 2,
      "end_line": 3,
      "expected": "status: draft\r\n",
      "replacement": "status: reviewed locally\r\n"
    }
  ]
}
```

Coordinates are one-based boundaries in the ORIGINAL file. `[2,3)` selects line
2 including its newline; `[2,2)` inserts before line 2 and must expect `""`.
An empty replacement deletes the range. `[N+1,N+1)` appends at EOF. An empty or
BOM-only file has zero lines and accepts insertion at `[1,1)`. An unterminated
final line is a line; appending does not invent a newline, so include `\n` in the
replacement when wanted.

LF separates lines, and CRLF stays intact inside each selected line. A lone CR
is ordinary line content. The leading UTF-8 BOM is excluded from coordinates
and expected text, and is always preserved. Unchanged bytes, blank lines,
Unicode, mixed endings and missing final newline are not normalized.

All ranges and expected strings are checked against the original before output.
Edits are sorted by start boundary. Overlapping ranges or equal start boundaries
(including multiple insertions at the same anchor) refuse. Touching nonempty
ranges, or an insertion after a preceding range, are allowed. Recipe order does
not shift later coordinates. Exact expected strings include line endings.

The native CLI emits no candidate bytes on validation failure. Shell redirection
can create an empty destination before the command starts; stream write failures
are not transactional. Choose NEW output paths so a failure cannot truncate a
valuable file.

## Review and reopen

1. Inspect `list --json`, `preview`, or export to obtain the fingerprint and exact
   bytes. The retained search reader numbers original lines.
2. Save an editable recipe with that fingerprint and exact expected ranges.
3. Run `edit-text` into separate new candidate/context files; check exit status.
4. Reopen in a text viewer and compare against the exported original with a
   standard text diff. The existing MoonFort unified-diff engine accepts these
   limits; tests also apply its patch with a standard patch reader.
5. Keep subsequent review and authorization separate. This command does not
   create a retained binding, run code, consume grants or promote anything.

## Portable synthetic example

Build `cmd/browse-retention` for native with an absolute external target directory.
Prepare a NEW disposable demo:

```text
moon run examples/text-edits/prepare-demo.mbtx ABSOLUTE_EXAMPLES_DIRECTORY NEW_ABSOLUTE_DEMO_DIRECTORY
MOONFORT_EXECUTOR_CONFIG=DEMO/config.json browse-retention list --json < DEMO/receipt-binding.json
MOONFORT_EXECUTOR_CONFIG=DEMO/config.json browse-retention edit-text notes.txt --recipe DEMO/edits.json < DEMO/receipt-binding.json > NEW-candidate.txt 2> NEW-context.json
```

Preparation produces a 24-hour synthetic store and pinned recipe; its fake binding
is solely local test data. The example replaces status, deletes a line and appends
a review note, while retaining the original.

Bounds: source/candidate at most 256 KiB and 2000 lines, recipe at most 64 KiB,
1..100 operations, canonical integer coordinates, strict bounded JSON and valid
UTF-8. Binary controls refuse. Context respects the existing protocol budget.
SHA-256 binds bytes; it does not authenticate the author or grant authority.
