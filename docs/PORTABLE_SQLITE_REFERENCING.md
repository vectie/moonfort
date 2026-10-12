# Find the retained records that reference a reviewed row

When a retained database shows a particular run or configuration, a reviewer
needs to see its samples or runs before deciding which output to inspect.
`referencing` starts from that exact parent row, follows one declared incoming
foreign key, and exports the child records as typed JSON or CSV. You can filter
failed children and continue through pages without inventing SQL or manually
copying key values. This is the reverse direction of the existing `related`
child-to-parent workflow, not a recursive dependency or impact analysis.

This extends MOONFORT-W04/B09 retained-artifact inspection and prepares W06
review. Input is an existing MoonFort retained-review ZIP; it does not rerun the
original command, contact the executor, change retained data, or promote output.

## Discover a relationship and inspect a parent row

Use the same standalone database copies, Python 3.11+ and SQLite 3.37+ with
`deserialize` support as [ordinary SQLite review](PORTABLE_SQLITE_REVIEW.md).
No dependency installation is required. From the repository root:

```sh
python3 tools/sqlite_review.py review.zip --database results/review.sqlite schema > new-schema.json 2> new-schema.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite rows --selection chosen-run.json > new-runs.json 2> new-runs.context.json
```

For example, `chosen-run.json` can select a run with an exact stored name:

```json
{"table":"runs","where":[{"column":"name","value":{"type":"text","value":"Nightly"}}]}
```

Every schema object now has `incoming_foreign_keys`. Each entry contains the
existing foreign-key declaration plus `child_table`: the exact table declaring
it. `id` is the declaration ID within that child table, `columns` are child
reference columns, and `referenced_table`/`referenced_columns` name the parent.
Names in declarations resolve using SQLite's ASCII case-insensitive rules.
Discovery does not certify that the declaration is usable or enforced. Missing
parents have no schema object to list their incoming declaration; they remain
visible on the child's outgoing `foreign_keys`.

Inspect `new-runs.json`, choose a specific row, and select a specific incoming
relationship from the schema. This example requires exactly one run and exactly
one incoming declaration from `samples`, instead of silently choosing a row or
relationship. It creates a recipe pinned to the inspected database bytes:

```sh
python3 - <<'PY'
import json
from pathlib import Path
schema = json.loads(Path('new-schema.json').read_text())
page = json.loads(Path('new-runs.json').read_text())
assert schema['source'] == page['source'], 'Use the same retained database copy'
assert len(page['rows']) == 1 and not page['has_more'], 'Inspect and select exactly one run'
parent = next(item for item in schema['objects'] if item['name'] == 'runs')
keys = [key for key in parent['incoming_foreign_keys'] if key['child_table'] == 'samples']
assert len(keys) == 1, 'Choose a specific incoming declaration'
recipe = {'database_sha256': page['source']['source_file']['fingerprint'],
          'table': 'runs', 'locator': page['rows'][0]['locator'],
          'child_table': keys[0]['child_table'], 'foreign_key': keys[0]['id'],
          'where': [{'column': 'status', 'value': {'type': 'text', 'value': 'failed'}}]}
with open('new-failed-children.json', 'x', encoding='utf-8') as output:
    json.dump(recipe, output, ensure_ascii=False, indent=2)
PY
python3 tools/sqlite_review.py review.zip --database results/review.sqlite referencing --selection new-failed-children.json --limit 100 > new-failures.json 2> new-failures.context.json
python3 tools/sqlite_review.py review.zip --database results/review.sqlite referencing --selection new-failed-children.json --limit 100 --format csv > new-failures.csv 2> new-failures-csv.context.json
```

Check exit status before using a result. Use new output filenames: shell
redirection can truncate a file before the command refuses. CSV and JSON export
one page, not the entire matching set. When `has_more` is true, repeat the same
bundle and recipe with `--offset` set to the returned `next_offset`. Default
page size is 100, maximum 1,000. `row_count` is this page's count, not a total.
A page beyond the end can be empty while `reference_status` still reports
matching children.

## Selection and exact identity

The required recipe fields are `database_sha256`, `table`, `locator`,
`child_table`, and `foreign_key`. `table` names the inspected parent; the child
must declare the selected foreign key pointing to that parent. The locator
copies a prior `rows`, `related`, or `referencing` result's typed values in its
`locator.columns` order. It is an unshadowed rowid alias, or an ordered primary
key for a WITHOUT ROWID table. Its exact SQLite storage classes and BINARY
values must identify one row. The recipe refuses changed database bytes,
missing rows, wrong locator types, or a relationship to a different table.
Moving an unchanged ZIP or recipe does not change its identity.

Optional `columns`, `where`, and `order_by` all apply to the **child** table,
using the ordinary row-selection rules. Omit `columns` to see all stored child
columns. `where` has up to eight AND-combined exact typed filters; it does not
inherit the parent's affinity or collation. `order_by` has up to eight fields,
with BINARY ordering followed by an ascending unique child locator for ties.
Returned child locators can be used in a fresh `related` recipe to inspect the
parent again, or in a new `referencing` recipe to inspect another explicit hop.
Self-references and cycles stay one hop per invocation.

## Matching meaning and provenance

Parent-key affinity and collation determine relationship matching. A parent
INTEGER key 7 can match a child TEXT value `"007"`; a parent TEXT key `"007"`
does not match child INTEGER 7. The child's declared affinity must not override
the parent's comparison. A NOCASE parent can match differently cased child text.
Actual original values remain visible. A composite relationship must match every
component. NULL child-key components never match a parent. A parent reference
key containing NULL returns `null-parent-key` and no child rows.

`reference_status` is `matching-child-rows`, `no-matching-child-rows`, or
`null-parent-key`. The first two describe the set **after** any child `where`
filters and are independent of page offset. Empty filtered output is not proof
that no other children reference the parent. Duplicate parent keys do not
multiply child rows. If an unenforced declaration targets duplicate parent keys,
each such parent can yield the same children; this is not unique ownership.

Each result and stderr context retain:

- Original receipt binding, archive/manifest/database hashes, and source expiry
- Parent `source_row`: exact locator, resolved parent key columns and typed values
- The selected declaration, resolved child and parent columns, and match status
- Original `relation_selection`, recipe byte hash/size, normalized child selection
- Child locators, selected typed values, page continuation, and ordering
- Exact exported candidate byte hash and size in the stderr context

CSV preserves `locator_json` and JSON-encoded typed cells, including BLOB base64,
NULL, Unicode, multiline text, and integers beyond JSON's safe numeric range.
Parse each cell as JSON for lossless readback, or import all cells as text with
spreadsheet formula interpretation disabled. Keep the context sidecar.

## Bounds and limits

The existing 20 MiB ZIP, 1 MiB database, 64 KiB recipe, 16 MiB output, 100 schema
object, 128 columns per object, 128 foreign keys per table, and 128 components per
foreign key bounds still apply. Page offsets are 0–1,000,000. The existing shared
approximate five-million SQLite VM-instruction budget includes incoming lookup;
large unindexed child scans can refuse. There is no wall-clock guarantee,
streaming export, arbitrary SQL, inferred relationship, cross-database query,
recursive traversal, or mutation. Generated relationship columns, unsupported
table kinds, or unavailable custom collations refuse on use. Implicit parent
references require a matching stored primary key.

The reader verifies every supplied artifact against the review ZIP manifest,
then deserializes only the selected database into memory. It does not extract
files or discover WAL sidecars. Validation establishes copy consistency, not
authenticity, current retrieval rights, live executor state, complete source
snapshots, foreign-key integrity, or causal impact. Historical expiry does not
erase a downloaded copy. Nothing redacts private data or authorizes sharing.
Acceptance, named review, and promotion remain separate.

## Focused verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-referencing.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-relations.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-coverage-review.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-junit-review.py
```

The new CLI journeys cover schema discovery, configuration → runs → filtered
samples → parent readback, paging, sorting, composite keys, parent affinity versus
child affinity, NOCASE, null and unused keys, duplicate parent keys, explicit
multiple/self relationships, quoted identifiers, typed CSV reopen, unchanged
source hashes, relocation, and stale selection refusal. An independent SQLite
foreign-key constraint fixture checks the conflicting-affinity expectation.
Inputs, recipes and outputs are retained in the printed evidence directory;
`MOONFORT_REFERENCING_EVIDENCE` can specify a new directory.

These local tests do not qualify the native ZIP producer, original workload,
executor, browser, host/AEN containment, providers, hardware, or full product.
No Moon command or dependency installation is required. R50 remains the last
fully verified cumulative checkpoint; R51–55 are separate.
