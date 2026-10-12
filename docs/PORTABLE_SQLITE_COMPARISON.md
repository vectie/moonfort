# Compare retained database results by a stable key

A rerun can reorder a SQLite result table or allocate different rowids while
changing only one result. The existing `rows`, `related`, and `referencing`
commands inspect a single retained database. `compare` now matches two complete,
bounded table projections by explicit typed key columns, identifies added,
removed, and changed records, and retains each side's exact row locator for
further inspection. This serves MOONFORT-W04/B09 retained-output inspection and
the inspection stage of W06. It does not run, accept, edit, or promote output.

## Inspect both schemas and select the actual record identity

Use two already downloaded MoonFort [retained review ZIPs](RETAINED_REVIEW_BUNDLE.md)
containing standalone SQLite artifacts. Requirements are unchanged: Python 3.11+
with standard-library sqlite3, SQLite 3.37+, and deserialize support. No package
install, executor connection, archive extraction, or database server is needed.
From this repository root:

```sh
python3 tools/sqlite_review.py before.zip --database results/review.sqlite schema > new-before-schema.json 2> new-before-schema.context.json
python3 tools/sqlite_review.py after.zip --database results/review.sqlite schema > new-after-schema.json 2> new-after-schema.context.json
```

Review the two schemas and, if necessary, inspect example records with the
[existing row selector](PORTABLE_SQLITE_REVIEW.md). Choose columns that identify
the same real record across these particular runs. The tool cannot infer that
identity from a rowid, primary-key declaration, similar values, or receipt name.
For example, a result may be identified by `code` and `platform` together.

Create a local recipe that pins both inspected artifact digests. This example
assumes both tables are called `results` and that you have reviewed the key:

```sh
python3 - <<'PY'
import json
from pathlib import Path
before = json.loads(Path('new-before-schema.json').read_text())
after = json.loads(Path('new-after-schema.json').read_text())
recipe = {
    'before_database_sha256': before['source']['source_file']['fingerprint'],
    'after_database_sha256': after['source']['source_file']['fingerprint'],
    'table': 'results',
    'key_columns': ['code', 'platform']
}
with open('new-comparison.json', 'x', encoding='utf-8') as output:
    json.dump(recipe, output, ensure_ascii=False, indent=2)
PY
python3 tools/sqlite_review.py before.zip --database results/review.sqlite compare after.zip --selection new-comparison.json > new-changes.json 2> new-changes.context.json
python3 tools/sqlite_review.py before.zip --database results/review.sqlite compare after.zip --selection new-comparison.json --format csv > new-changes.csv 2> new-changes-csv.context.json
```

If the second artifact has a different retained path, add
`--after-database output/final.sqlite` after `compare`. The table name must be
the same exact name on both sides. Moving either unchanged ZIP or the recipe to
a different directory leaves result identity unchanged. Changing a selected
database's bytes refuses until the recipe is deliberately regenerated after
inspection. A missing artifact is a refusal, never a fabricated empty table.

Always check exit status before using output. Use fresh output filenames: shell
redirection may truncate an existing file before the tool starts. Keep both ZIPs,
the recipe, report, and stderr context together.

## Exact comparison semantics

The recipe requires `before_database_sha256`, `after_database_sha256`, `table`,
and `key_columns`; its only optional field is `columns`.

- `key_columns` lists 1–8 distinct stored column names in explicit tuple order.
  Every component must be non-NULL, and each typed tuple must be unique within
  each side. A NULL or duplicate key refuses the entire comparison with the
  affected side and row locators. The tool never selects a first or last match.
  Empty text, empty BLOB, whitespace, and zero are valid keys; deciding whether
  they are useful domain identities remains the reviewer's responsibility.
- Identity includes the SQLite storage class and its typed serialized value.
  Integer `1`, real `1.0`, text `"1"`, and BLOB `b"1"` are distinct. Text is exact
  and case-sensitive even on NOCASE columns. There is no numeric coercion,
  declared affinity, collation matching, Unicode normalization, tolerance,
  trimming, or fuzzy correspondence. Finite reals use Python's representation
  of the stored floating-point value, including a retained signed zero.
- Omit `columns` to compare all stored columns in schema order. Their ordered
  names must match exactly on both sides. If schemas differ, inspect them and
  explicitly choose a nonempty shared `columns` projection. It must include
  every key column. Projection order controls output values; omitted columns
  are outside the comparison. Generated columns cannot be chosen or used as
  keys. The tool compares stored values, not schema definitions or constraints.
- A key present only after is `added`; one present only before is `removed`.
  A shared key with any differing projected typed cell is `changed`. Otherwise
  it counts as `unchanged` and is omitted from the change entries. A key edit
  produces removal plus addition, not an inferred rename.
- Row order and rowid changes alone do not create a change. Locators are exact
  drillback coordinates within each pinned database, not cross-run identities.
  Rowid tables use an unshadowed rowid alias; WITHOUT ROWID tables use ordered
  primary-key columns. If no supported locator exists, comparison refuses.
- The complete selected table is scanned on both sides. There are no filters,
  page limits, offsets, silent truncation, arbitrary SQL, inferred joins, table
  remapping, or cross-database writes. Entries sort lexically by their compact
  JSON typed-key representation, not numerically or by database collation.

## Read the result and follow a changed record

JSON has `counts` with complete before/after row counts plus added, removed,
changed, and unchanged counts. `complete: true` means the bounded selected
projections were fully compared, not that the ZIP contains every execution
artifact or that the database was a complete producer snapshot.

Every change contains `change`, a typed `key` array, `changed_columns`, and a
`before` and/or `after` row. Each present row has `locator` and ordered `values`
arrays. Missing sides are omitted, distinct from a present row containing a
SQL NULL typed cell. Added/removed entries list all compared columns as changed;
other entries list only differing columns by name.

Both side contexts include the original receipt binding, historical source
expiry, archive/manifest/database hashes, normalized projection, locator kind
and columns, and complete row count. The shared context also includes the exact
recipe object and its byte hash/size, SQLite version, matching semantics, and
output ordering. The stderr context fingerprints the exact output bytes.

To inspect a changed row's declared parent, copy that side's `locator` into an
[existing `related` recipe](PORTABLE_SQLITE_RELATIONS.md), with that side's
pinned database digest, exact table name, and chosen foreign-key ID from that
side's schema. Use the same side's ZIP and artifact path. Similarly, an exact
changed parent can anchor [incoming-record review](PORTABLE_SQLITE_REFERENCING.md).
A declaration is not proof of integrity, ownership, or causation.

CSV exports one record per changed logical row, with these fields:
`change`, `key_json`, `changed_columns_json`, `before_locator_json`,
`after_locator_json`, `before_values_json`, and `after_values_json`.
Every field ending in `_json` is JSON. Parse it to recover the exact arrays;
an absent side is JSON `null`. Present SQL NULL cells remain typed objects
inside a present values array. Text/newlines, BLOB base64, and full signed
64-bit integer strings are preserved. Import fields as text in a spreadsheet
with formula interpretation disabled and keep its context sidecar.
A no-change result is successful with an empty JSON change list or header-only
CSV, plus full unchanged counts.

## Bounds and authority

Each side retains the existing bounds: 20 MiB ZIP, 1–200 artifacts and 16 MiB
combined artifacts, 1 MiB database and manifest, 100 schema objects, 128 columns
per object, and an approximate five-million SQLite VM-instruction budget for
schema/row queries. A comparison recipe is at most 64 KiB. Each side permits
at most 10,000 selected rows and 16 MiB of compact serialized projected rows
plus keys. The final JSON or CSV output is at most 16 MiB. Exceeding a bound
refuses with no candidate output; there is no successful partial comparison.
This is bounded in-memory review, not streaming or a wall-clock guarantee.

The existing reader validates every artifact in both ZIPs, including unrelated
files, against manifest hashes. Selected database bytes are deserialized into
separate query-only in-memory connections; no retained path, sidecar, extension,
view, or user-defined expression is executed. Only ordinary standalone
rollback-journal SQLite databases are supported. WAL-mode files, unsupported
locators, invalid text/nonfinite reals, generated selected fields, virtual
or view queries, unavailable custom collations, or malformed databases can
refuse. The database inspection runtime is not a sandbox qualification.

Copy consistency is not authenticity, live execution state, current retrieval
rights, complete source snapshots, schema equivalence, foreign-key integrity,
or evidence that a change was caused by a particular code revision. Historical
expiry does not erase a downloaded copy. No data is redacted; sharing requires
its own authorization. Named acceptance and artifact promotion stay separate.

Success exits 0 with output on stdout and JSON context on stderr. Validation or
read failures exit 1 with a diagnostic and no candidate bytes; argument errors
exit 2. Output I/O failure can leave a partial file.

## Focused verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-comparison.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-referencing.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-relations.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-coverage-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-junit-review.py
```

Twelve new production-CLI journeys cover reordered rowids and exact database
readback, outgoing-reference drillback, typed and composite keys, lossless CSV,
storage-class changes, schema projection, empty/unchanged results, key edits,
missing/ambiguous keys, relocation and stale recipes, independent artifact paths,
whole-ZIP validation, and complete scans through the 10,000-row boundary.
Inputs and stdout/stderr remain in the printed evidence directory;
`MOONFORT_COMPARISON_EVIDENCE` can choose a fresh directory.

No native ZIP producer, original workload, execution backend, browser,
local/AEN containment, provider, hardware, or full product is requalified by
these tests. No Moon invocation or dependency installation is required.
R50 remains the last fully verified cumulative checkpoint; R51–55 are separate.
