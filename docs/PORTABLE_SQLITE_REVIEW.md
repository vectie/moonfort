# Inspect retained SQLite result databases

A generated result can be a database rather than a text report. Open an existing
MoonFort [retained review ZIP](RETAINED_REVIEW_BUNDLE.md), discover its table
columns, select the relevant records, and export a reusable JSON or CSV page.
The database stays bound to its original receipt and fingerprint. This adds a
binary database inspection workflow to MOONFORT-W04/W06/B09; it does not execute
the original task, alter its output, approve it, or promote it.

## Discover, select, and export

Requires Python 3.11+ with the standard-library sqlite3 module, SQLite 3.37+ and
its deserialize support. No package installation or server is involved. Start
with a previously downloaded product review ZIP containing a standalone SQLite
artifact. The exact path must have been selected into that ZIP. The tool never
contacts the executor or retrieves missing database sidecars.

From this repository root:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite schema > new-schema.json 2> new-schema.context.json
```

The schema lists tables, column names and declared types, primary-key positions,
not-null flags, WITHOUT ROWID/strict flags, generated columns, and declared outgoing
foreign keys. Foreign-key declarations do not certify referential integrity. Views, virtual
tables and shadow tables are listed with row selection unsupported. Their data
is not queried. SQLite internal `sqlite_*` objects are omitted. Declared column
types describe schema affinity; output cells report actual storage classes.

Create a local selection file, for example `failed-samples.json`:

```json
{
  "table": "samples",
  "columns": ["id", "owner", "score", "raw", "note"],
  "where": [
    {"column": "status", "value": {"type": "text", "value": "failed"}}
  ],
  "order_by": [{"column": "score", "direction": "desc"}]
}
```

Then inspect a page or export a spreadsheet review copy:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite rows --selection failed-samples.json --limit 100 > new-rows.json 2> new-rows.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite rows --selection failed-samples.json --limit 100 --format csv > new-rows.csv 2> new-csv.context.json
```

Keep the ZIP, selection file, output and stderr context together. Output contains
`has_more` and `next_offset`; pass that exact offset with the same ZIP, selection
and limit to continue. Each call emits one page, never silently labels the first
page a complete export. `row_count` counts this page, not the whole table. An
empty table, unmatched filter or past-end offset gives no rows, `has_more: false`
and `next_offset: null`. An empty CSV still has its header.

The selection requires an exact, case-sensitive ordinary table name. `columns`
is an ordered, nonempty array of distinct stored column names; omitting it selects
all stored columns. Generated columns are disclosed by schema inspection but
cannot be selected, filtered or sorted. Omit `where` for all rows. Filters are
ANDed exact comparisons with BINARY collation and require the same storage class:
integer 1, real 1.0 and text "1" remain distinct. `null` matches only SQL NULL.
No coercion, substring filter, arbitrary joins, expressions, arbitrary SQL or
user-defined functions are exposed by `rows`. For declared outgoing foreign-key
lookup, use the separate [related-row workflow](PORTABLE_SQLITE_RELATIONS.md).

`order_by` takes distinct stored columns with `asc` or `desc`. SQLite storage-class
ordering and BINARY text collation apply, including its normal NULL ordering.
A unique locator is appended to break ties: an unshadowed rowid alias on ordinary
rowid tables, or the exact composite primary key on WITHOUT ROWID tables. Without
explicit ordering, locator order is used. Locator values accompany every output
row for drillback to this exact database fingerprint. They are not portable
record identities across database revisions. If every rowid alias is shadowed,
row browsing refuses; schema inspection remains available.

For two database revisions, use [typed-key snapshot comparison](PORTABLE_SQLITE_COMPARISON.md)
to compare complete bounded table projections and retain both sides’ locators.

## Typed cells and CSV readback

JSON rows contain ordered `locator` and `values` arrays. Column names and locator
columns live in the context. Every cell is `{ "type": ..., "value": ... }`:

- `null`: JSON null
- `text`: exact text, including newlines and empty strings
- `integer`: signed decimal string, preserving all 64 bits
- `real`: finite Python/SQLite floating-point value represented as a string;
  original source spelling before insertion into SQLite cannot be recovered
- `blob`: canonical base64 string, including the empty string for empty bytes

Use the same typed objects as filter values. Integer and real filters use strings,
not JSON numeric literals. Blob filters require standard padded base64. Nonfinite
reals and invalid UTF-8 text refuse rather than produce misleading values.

CSV headings are `locator_json` followed by `column:<exact name>`. Every data cell
contains JSON: the locator array or one typed cell object. Parse those cells as
JSON to reconstruct the same values as JSON output. This preserves NULL versus
empty text versus empty BLOB, and large integer precision. For spreadsheet review,
import columns as text with formula interpretation disabled; this is a typed
review export, not a claim that arbitrary retained content is spreadsheet-safe.

## Source and candidate evidence

The shared portable-review reader verifies the entire selected ZIP inventory,
including unrelated artifacts, against its manifest sizes and SHA-256 hashes.
It supports the native version-1 unencrypted stored product bundle with integer
or decimal-string manifest sizes. No ZIP member is extracted. The selected SQLite
bytes are deserialized into an in-memory connection with read-only query policy,
trusted-schema features disabled, extension loading disabled, and only generated
schema/read statements permitted. No path named inside a database is opened.

Both JSON output and the stderr context retain the original receipt binding,
historical source expiry, archive/manifest/database fingerprints, SQLite version,
selection contents and exact selection-file hash/size, pagination and locator
metadata. The stderr sidecar additionally fingerprints the exact candidate output
bytes. Schema inspection has no selection-file fields. Moving the ZIP/recipe to
a different local directory preserves the result; local input filenames are not
used as identity. The source archive is never written.

These checks establish consistency of a supplied copy, not authenticity,
signature verification, current execution state, current retention rights or
complete inclusion of all scratch artifacts. Historical copies remain reviewable
after their recorded retrieval expiry. Nothing redacts potentially private data
or grants permission to share it. SQLite parsing is not an arbitrary-code sandbox
qualification; use a maintained Python/SQLite runtime.

## Supported files and limits

Only standalone SQLite 3 databases in rollback-journal mode are supported. A
WAL-mode database is refused even when it appears checkpointed: omitted WAL pages
cannot be treated as complete evidence. The producer must retain a self-contained
snapshot before bundle export. Header checks cannot prove the producer closed the
database cleanly or omitted no rollback journal. Encrypted databases, separate journal/WAL/SHM
reconstruction, virtual tables, view evaluation and extension-dependent features
are unsupported. Malformed databases, custom collations needed for a read, or
unsupported schema features can refuse without candidate output.

Bounds: existing product ZIP limit 20 MiB, 1–200 artifacts, 16 MiB combined
artifacts; database/manifest at most 1 MiB each; selection at most 64 KiB; up to
100 noninternal schema objects and 128 columns per object; at most 8 filters and
8 order columns; page size 1–1,000, offset 0–1,000,000; final output at most 16 MiB.
A shared SQLite progress budget interrupts after approximately five million VM
instructions across schema and row reads. This is bounded in-memory inspection,
not streaming, a wall-clock deadline, or complete database integrity certification.

Success exits 0 with output on stdout and JSON context on stderr. Read/validation
failures exit 1 with a stderr diagnostic and no candidate bytes; argparse errors
exit 2. Use fresh output names and check exit status. Shell redirection can
truncate files before the tool starts; output I/O failure can leave partial files.

## Focused verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-coverage-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-junit-review.py
```

The SQLite tests create real standalone SQLite bytes inside native-format review
ZIP fixtures, invoke the production CLI, discover schema, filter/sort/page, drill
back by locators, reopen typed JSON/CSV, and verify input and output fingerprints.
They cover empty selections, Unicode/quoted names, composite keys, generated
column disclosure, relocation, and explicit unsupported input. Evidence is kept
in the printed directory; `MOONFORT_SQLITE_EVIDENCE` selects a fresh one.

The native ZIP producer, original workload, real executor, local/AEN containment,
browser, provider, hardware and full product are not executed or requalified.
No Moon command or dependency install is needed. R50 remains the last fully
verified cumulative checkpoint; R51–55 are separate.
