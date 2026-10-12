# Follow retained database references before review

A failed result often names a run, configuration, or input in another table.
The existing retained SQLite `rows` workflow can show the failed result but
cannot explain those references. `related` follows one declared outgoing foreign
key from an exact inspected row, returning the parent records as typed JSON or
CSV. This extends MOONFORT-W04/B09 retained-artifact inspection and prepares W06
review. It does not execute work, validate a constraint, or promote output.

## Discover, choose a row, and follow its reference

Use the same already-exported MoonFort review ZIP and supported standalone
SQLite artifact as [ordinary database review](PORTABLE_SQLITE_REVIEW.md).
Python 3.11+, SQLite 3.37+, and deserialize support are required. No dependency
installation, server, extraction, or executor connection is needed.

From the repository root, discover the schema and inspect the desired rows:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite schema > new-schema.json 2> new-schema.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite rows --selection failed-samples.json > new-failed.json 2> new-failed.context.json
```

For example, `failed-samples.json` selects `samples` whose `status` is failed:

```json
{"table":"samples","where":[{"column":"status","value":{"type":"text","value":"failed"}}]}
```

`schema` now includes `foreign_keys` for each ordinary table. Each declaration
has an integer `id`, ordered child `columns`, `referenced_table`, ordered
`referenced_columns`, and declared update/delete/match policies. A null target
column means an implicit parent primary-key reference. IDs identify declarations
in this exact database, not stable relationships across revisions. Views and
unsupported table kinds have no inspected declarations.

After inspecting the first failed row, this example prepares its sole declared
reference to `runs`. Change the table and relationship names to match the schema;
review the selected row rather than assuming it represents all failures.

```sh
python3 - <<'PY'
import json
from pathlib import Path
schema = json.loads(Path('new-schema.json').read_text())
page = json.loads(Path('new-failed.json').read_text())
assert schema['source'] == page['source'], 'Use the same retained database copy'
table = next(item for item in schema['objects'] if item['name'] == 'samples')
keys = [key for key in table['foreign_keys'] if key['referenced_table'] == 'runs']
assert len(keys) == 1 and page['rows'], 'Inspect the schema and choose a specific row/reference'
selection = {'database_sha256': page['source']['source_file']['fingerprint'],
             'table': 'samples', 'locator': page['rows'][0]['locator'],
             'foreign_key': keys[0]['id']}
with open('new-reference.json', 'x', encoding='utf-8') as output:
    json.dump(selection, output, ensure_ascii=False, indent=2)
PY
python3 tools/sqlite_review.py review.zip --database results/review.sqlite related --selection new-reference.json > new-run.json 2> new-run.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite related --selection new-reference.json --format csv > new-run.csv 2> new-run-csv.context.json
```

Check every command's exit status. Use new destination names: shell redirection
can truncate an old file before a refusal. The recipe pins the database artifact
SHA-256. A changed database refuses even when it still contains the same row
number. The input ZIP name is not identity, so moving unchanged copies works.

`locator` copies the typed value array from a prior `rows` or `related` result.
Its order is given by that output's `locator.columns`: one unshadowed rowid alias
for rowid tables, or the ordered composite primary key for WITHOUT ROWID tables.
The exact storage classes and BINARY values must identify one source row. Null,
missing, wrong-type, or nonunique anchors refuse. Source recipe table names are
exact. Declarations are resolved with SQLite's ASCII case-insensitive identifier
rules, and resolved names are included in output.

Optional `columns` and `order_by` select and sort **parent** stored columns using
the ordinary row recipe rules. There is no extra `where` in a reference recipe.
Omit `columns` to show all stored parent fields. `--limit` (default 100) and
`--offset` work as before. Keep the same recipe/ZIP and use `next_offset` to
continue; `row_count` is the page size, not a total. Ordering uses BINARY selected
columns followed by a unique ascending locator, so duplicate matches are stable.
To follow another hop, inspect the target table's declarations and use the target
row's returned locator, table, and the same database digest in a fresh recipe.
Traversal is explicit, one hop per invocation; cycles never trigger recursion.

## Reference meaning and drillback

Each result and stderr context includes:

- `source_row`: the child table, exact locator metadata/typed values, ordered
  reference columns, and the actual typed reference values read from the ZIP
- `relationship`: the selected declaration plus resolved parent table/columns
- `reference_status`: `null-reference`, `no-matching-parent`, or
  `matching-parent-rows`
- `relation_selection`: the exact recipe object and its original bytes' SHA-256
  and size; `selection` describes the resulting parent projection
- Parent rows and locators, pagination, original receipt binding, source expiry,
  and archive/manifest/database fingerprints
- The exact candidate byte hash/size in the stderr sidecar

Parent matching uses each parent column's declared SQLite affinity and collation,
unlike `rows`' exact typed filters. Thus text `"007"` can reference integer `7`,
and a NOCASE parent can match differently cased child text. Both actual values
remain visible. Any null child-key component returns `null-reference` with no
rows. A non-null reference without a matching parent returns `no-matching-parent`.
An offset beyond the last parent row can return an empty page while retaining
`matching-parent-rows`; it does not relabel an existing reference as missing.

A declaration is **not** evidence that SQLite enforced it or that its target key
is unique. If multiple parent rows match a nonunique declared key, all remain
available through pagination; the tool never picks one as authoritative. It does
not run `foreign_key_check`, certify referential integrity, or infer ownership or
causal correctness. Only explicit stored-column declarations are followed. A
missing/unsupported target, generated child/parent reference column, or implicit
reference without a matching parent primary key refuses. Unknown custom
collations can also refuse. No arbitrary SQL, inferred links, cross-database traversal, joins chosen by the
caller, or data mutation is provided. To inspect the reverse direction, use the
[explicit incoming-reference workflow](PORTABLE_SQLITE_REFERENCING.md).

CSV uses the same `locator_json` and JSON-encoded typed cells as ordinary SQLite
review. Keep its context sidecar. Parse the cells as JSON for lossless NULL/text/
BLOB/integer readback, or import as text with spreadsheet formula interpretation
disabled. Large integers, empty data, Unicode, and multiline text are preserved.

## Bounds and authority

All prior bundle/database/selection/output bounds apply: 20 MiB ZIP, 1 MiB
SQLite artifact, 64 KiB recipe, 16 MiB output, 100 schema objects, 128 columns per
object, page size 1–1,000 and offset 0–1,000,000. Schema discovery permits at most
128 outgoing declarations per table and 128 components per declaration. The
existing shared approximate five-million SQLite VM-instruction budget covers
schema, anchor, existence, and page queries. This is bounded in-memory review,
not a wall-clock guarantee or streaming export.

The shared reader verifies **all** supplied artifact bytes against the product
ZIP manifest before querying. No data is extracted or written to the database.
A historical source expiry does not delete a previously downloaded copy. These
checks establish copy consistency, not authenticity, live executor state, current
retrieval rights, source snapshot completeness, or stronger containment. Nothing
redacts private data or authorizes sharing. Retain the ZIP, recipe, output, and
context together; acceptance and promotion still require their own review.

## Focused verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-relations.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-coverage-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-junit-review.py
```

The relationship cases exercise real native-format ZIP fixtures and the production
CLI: failed sample → run → configuration, source/target readback, affinity and
NOCASE lookup, implicit composite keys, null/missing references, duplicate parent
pagination, multiple foreign keys, quoted names, typed CSV, relocation, changed
fingerprint refusal, and unsupported targets. Inputs, recipes, and CLI outputs
remain in the printed evidence directory; `MOONFORT_RELATIONS_EVIDENCE` can choose
a new one. No native producer, original workload, real executor, browser,
local/AEN containment, provider, hardware, or full product was requalified.
No Moon command or dependency install is needed. R50 remains the last fully
verified cumulative checkpoint; R51–55 are separate.
