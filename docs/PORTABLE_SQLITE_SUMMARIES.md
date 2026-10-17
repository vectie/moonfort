# Find the important groups in a retained SQLite result

Before opening individual samples, find which owners, suites or statuses account
for most results and how their numeric measurements differ. `summarize` reads a
complete bounded selection from an existing retained review ZIP, groups exact
typed values and reports counts, sums, means and extrema. `group-rows` opens a
chosen group's original records with resumable pages. Both reuse an editable
recipe pinned to the inspected database. This extends MOONFORT-W04/B09 and W06
artifact inspection; it does not edit, execute, accept or promote output.

## Discover, summarize, drill into a group

The existing [SQLite reader prerequisites](PORTABLE_SQLITE_REVIEW.md) apply:
Python 3.11+, SQLite 3.37+ and deserialize support, using only the standard
library. Begin with a downloaded [retained review ZIP](RETAINED_REVIEW_BUNDLE.md).
From the repository root, inspect its actual table and column names:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite schema > new-schema.json 2> new-schema.context.json
```

Copy `source.source_file.fingerprint` from the schema output into a local recipe.
For a table `samples` with `owner`, `status` and numeric `score` columns, save:

```json
{
  "database_sha256": "REPLACE_WITH_THE_INSPECTED_DATABASE_SHA256",
  "table": "samples",
  "group_by": ["owner", "status"],
  "measures": ["score"],
  "where": []
}
```

The editable starting recipes are in `examples/sqlite-summary/`. They contain a
deliberately invalid digest placeholder; replace it only after inspecting your
own ZIP. Choose exact stored column names from its schema. Then run:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite summarize --selection owner-status.json > new-groups.json 2> new-groups.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite summarize --selection owner-status.json --format csv > new-groups.csv 2> new-groups-csv.context.json
```

Groups are ordered by descending row count, then exact typed key. The result
includes all groups, not a top-N sample. Inspect `row_count`, the selected numeric
measures and their storage counts. Copy one group's `key` array unchanged into
`selected-group.json`, for example:

```json
[
  {"type": "text", "value": "Zoë"},
  {"type": "text", "value": "failed"}
]
```

Open that group's full stored rows, including columns not needed for aggregation:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite group-rows --selection owner-status.json --group selected-group.json --limit 20 > new-members.json 2> new-members.context.json
```

If `has_more` is true, use its `next_offset` with `--offset` and the same ZIP,
recipe, key and page size. `--format csv` exports the page using the existing
typed-row CSV format. `total_group_rows` reports the complete matching count;
`row_count` reports this page. An absent key or past-end page returns zero rows.
Every row retains its original locator, and the summary contains all member
locators. These locators can also anchor existing [outgoing](PORTABLE_SQLITE_RELATIONS.md)
or [incoming](PORTABLE_SQLITE_REFERENCING.md) foreign-key exploration.

To refine the question, edit `group_by`, `measures` or `where` and summarize again.
For example, add `{"column":"status","value":{"type":"text","value":"failed"}}`
to `where` to investigate only failures. The same filters also apply to drillback.
Change `group_by` to `[]` to obtain overall totals. Set `measures` to `[]` for a
frequency distribution or just the overall row count. An empty selection has
zero groups, even with no grouping columns.

Check exit status before using output and use fresh output filenames: shell
redirection can truncate an existing file before the reader runs. Retain the
ZIP, edited recipe, selected key, output and stderr context together.

## Exact grouping and numeric evidence

The recipe requires exactly `database_sha256`, `table`, `group_by`, `measures`
and optional `where`. Grouping and measure lists each accept 0–8 distinct stored
columns; the same column may appear in both lists. Filters retain the existing
reader's maximum of eight ANDed exact typed BINARY comparisons. No arbitrary SQL,
expressions, inferred keys, computed columns or writes are accepted.

Group identity includes storage class and its exact typed serialized value.
Integer `1`, real `1.0`, text `"1"` and BLOB `b"1"` are different groups. NULL,
empty text and empty BLOB are different, valid keys. Text remains case-sensitive
even on a NOCASE column; no trimming or Unicode normalization occurs. Copy the
canonical key directly: an alternate real spelling such as `"1e0"` is refused.

Each measure reports:

- `storage_counts` for null, integer, real, text and BLOB values, and `numeric_count`.
- `sum` and `mean` as reduced rational objects with decimal-string `numerator`
  and `denominator`. Integers retain every bit; finite SQLite reals contribute
  their exact stored binary floating-point value. No intermediate floating-point
  sum, fixed-width overflow, text coercion or rounded mean is used.
- `decimal_approximation`, rounded to 17 significant decimal digits for reading.
  This is explicitly a display approximation, never the exact value. For example,
  the exact mean of a total `215/8` over seven rows is `215/56`.
- `minimum` and `maximum` with the original typed cell and exact source locator.
  Numeric comparisons include both integer and real values. Equal extrema select
  the first source locator; original storage class is preserved.

NULL, text and BLOB cells do not contribute numerically, and their counts remain
visible. A column with no numeric observations has null sum, mean and extrema,
not a fabricated zero. These are unweighted per-row statistics. Duplicate
observations remain present; the reader cannot establish independent samples,
correct units, valid experiment design or the completeness of a producer snapshot.

JSON embeds all typed group keys, numeric evidence and member locators. Summary
CSV columns are `key_json`, `row_count`, `measures_json` and `locators_json`;
parse the `_json` cells to recover the same complete objects. This preserves
full-width integers, BLOBs, NULL and newlines. Import spreadsheet fields as text
with formula interpretation disabled. Drillback CSV uses `locator_json` plus
the existing `column:<name>` typed JSON cells.

## Provenance, bounds and refusal

Outputs retain the original receipt binding and historical expiry, exact ZIP,
manifest and database fingerprints, exact recipe hash/size and normalized
selection. Drillback also hashes the selected-key file. Stderr context binds the
exact output bytes with `candidate_sha256` and size. Relocating unchanged inputs
does not change the result; changed database bytes require a deliberately
updated recipe after fresh inspection.

Both commands scan the complete filtered selection before writing output, with
at most 10,000 rows, 16 MiB of compact projected cells/locators, and 16 MiB final
output. Drillback reads all stored columns, so a wide table may fit summary
projection but refuse drillback. Exceeding a bound refuses with no candidate
bytes, never a successful partial summary. Pages are only a presentation of a
fully scanned selection. There is no unbounded streaming or wall-clock claim.

The existing 20 MiB ZIP, 1 MiB database/manifest, 100 schema-object, 128-column,
64 KiB recipe/key and approximate five-million SQLite VM-instruction bounds
remain. Every ZIP artifact is checked, including unselected artifacts. SQLite
bytes are deserialized into a query-only in-memory connection; no retained path,
sidecar, extension, view or expression is opened or evaluated. WAL-mode databases,
unsupported locators, invalid UTF-8/nonfinite values and unavailable collations
can refuse. SQLite runtime safety and execution backend qualification remain
separate release requirements.

Success exits 0, validation/read refusal exits 1, and argument errors exit 2.
Output I/O failure can leave a partial file. A downloaded copy is not authenticity,
current retrieval authority or live execution state. Nothing is redacted, and
sharing, named acceptance and promotion still need their own authorization.

## Focused verification

Run the MoonBit functional journey with absolute paths and a fresh evidence directory:

```sh
moon --target-dir /absolute/external/test-target run --target native --strip -j 1 scripts/test-sqlite-summary.mbtx /absolute/moonfort /absolute/new-evidence
```

It reuses the existing SQLite reader/comparison fixture suites unchanged, then
exercises the actual Python CLI: grouped totals, exact rational means and sums
beyond signed 64-bit, mixed storage classes, NULL and BLOB distinctions, extrema
locators, repeat/relocation, filtered and unfiltered member pages, JSON/CSV,
empty selections, composite quoted locators, stale/invalid recipes and the
10,000/10,001 complete-scan boundary. Inputs and stdout/stderr are retained.
These tests qualify the bounded inspection journey, not native ZIP production,
browser UI, a live executor, local/AEN containment or full product release.
