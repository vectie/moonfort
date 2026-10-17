# Compare retained SQLite schemas and inspect the changed table

The named artifact reviewer can compare two retained databases, pick a changed
table, read its before/after column and foreign-key declarations, then inspect
actual rows in either source using the existing `rows`, `related` and
`referencing` commands. No database migration, payload execution, acceptance or
promotion takes place. This is an inspection aid for the review steps in
MOONFORT-W04/W06/B09; it does not close those authored acceptance requirements.

Requires Python 3.11+, SQLite 3.37+, and SQLite deserialize support. Use the
existing version-1 unencrypted stored review ZIPs with standalone rollback-mode
SQLite artifacts. No installation, native build, server or extractor is needed.

## Discover and pin both inputs

From this repository root, inspect each supplied copy:

```sh
python3 tools/sqlite_review.py before.zip --database results/review.sqlite schema > before-schema.json 2> before-schema.context.json
python3 tools/sqlite_review.py after.zip --database changed/review.sqlite schema > after-schema.json 2> after-schema.context.json
```

Check both exit statuses. Use `source.source_file.fingerprint` from each result
to make a local comparison selection. For example:

```python
import json
before = json.load(open('before-schema.json'))
after = json.load(open('after-schema.json'))
selection = {
    'before_database_sha256': before['source']['source_file']['fingerprint'],
    'after_database_sha256': after['source']['source_file']['fingerprint']
}
with open('schema-comparison.json', 'w') as stream:
    json.dump(selection, stream)
```

```sh
python3 tools/sqlite_review.py before.zip --database results/review.sqlite compare-schema after.zip --after-database changed/review.sqlite --selection schema-comparison.json > comparison.json 2> comparison.context.json
```

`--after-database` defaults to `--database` if omitted. The tool validates all
bundled artifacts, including unrelated files, and checks both selected database
fingerprints before producing any candidate output. Historical expiry values
are carried through; these supplied copies are not reauthorized or authenticated.

## Pick a table, inspect both schemas

`objects` is a name-sorted change index. Each entry is `added`, `removed`,
`changed` or `unchanged`, with `changed_fields`. Counts cover the complete bounded
metadata inventory, including unchanged objects. Edit the same selection to add
an exact object name, such as `"table": "results"`, and repeat the command.

`selected.before` and `selected.after` contain the complete listed metadata for
that object. A missing side is JSON null. `column_changes` identifies exact-name
added, removed, or changed columns with their zero-based positions and metadata
on each side. Column metadata includes declared type, not-null, primary-key
position, unevaluated default SQL text, generated flag and generated kind.

The selected metadata also shows outgoing and incoming foreign-key declarations,
including source/target column lists and ON UPDATE/DELETE actions. IDs are local
to a side. When following a relationship, use that side's ID and row locator.
Incoming declarations are context, and do not count as changes to the parent
table's own schema. No declaration certifies integrity or unique ownership.

## Inspect actual rows with the existing CLI

Each `selected.row_navigation` side either has a reason it is unavailable, or
contains a valid existing `rows` selection and `argv_after_bundle`. Save the
selection as compact UTF-8 JSON. Replace `<saved-selection.json>` in the argument
array with that file and prepend the tool and the corresponding retained ZIP.
Use an argument array, not shell interpolation of untrusted object names.

For example, this executes the returned before-side navigation directly:

```python
import json, subprocess, sys
result = json.load(open('comparison.json'))
navigation = result['selected']['row_navigation']['before']
assert navigation['available'], navigation.get('reason')
with open('before-rows-selection.json', 'w', encoding='utf-8') as stream:
    json.dump(navigation['selection'], stream, ensure_ascii=False, separators=(',', ':'))
arguments = navigation['argv_after_bundle'].copy()
arguments[arguments.index('--selection') + 1] = 'before-rows-selection.json'
with open('before-rows.json', 'wb') as out, open('before-rows.context.json', 'wb') as err:
    subprocess.run([sys.executable, 'tools/sqlite_review.py', 'before.zip', *arguments],
                   stdout=out, stderr=err, check=True)
```

Repeat for `after` using `after.zip` and fresh filenames. Navigation carries
`--expected-database-sha256`; a different database refuses before reading rows.
The pin is database bytes, not an assertion that a particular receipt is genuine.
The output also retains the bundle and manifest fingerprints and original
receipt binding. Keep those for the review record.

Use `has_more`/`next_offset` to continue with the same bundle, selection and pin.
The default page is 100 rows; generated columns are excluded. Edit the returned
selection to choose stored columns, typed filters and ordering supported by the
[row reader](PORTABLE_SQLITE_REVIEW.md). Returned locators support the existing
[outgoing](PORTABLE_SQLITE_RELATIONS.md) and
[incoming](PORTABLE_SQLITE_REFERENCING.md) relationship flows on the same copy.
Row locators never establish record identity across revisions. To compare row
values, separately use [explicit typed keys](PORTABLE_SQLITE_COMPARISON.md).

Added or removed objects can be browsed only on their present side. Views,
virtual/shadow objects, tables with every rowid alias shadowed, and oversized
default selections report unavailable navigation. An empty ordinary table is
still navigable and returns an empty page. WITHOUT ROWID tables use their
primary-key locator. Schema detail remains available when row browsing refuses.

## Exact comparison scope and limits

Comparison covers object kind, WITHOUT ROWID/strict flags, ordered column metadata
and ordered foreign-key declarations including local IDs. Names match exactly
and case-sensitively; a rename is an addition/removal. Declaration reordering can
be a change. Default SQL text is compared literally and never evaluated.

This is not full SQL/schema equivalence. Indexes, triggers, CHECK expressions,
collations, generated expression text, CREATE SQL, and definitions of views,
virtual or shadow objects are not compared. A view definition or generated
expression can change while listed metadata remains unchanged. `unchanged`
means equal compared metadata, never equivalent schema or unchanged row values.
No causal regression, backend qualification or release readiness is established.

Inherited hard bounds remain: 20 MiB per ZIP; 1–200 artifacts and 16 MiB combined
artifact bytes; 1 MiB per selected database and manifest; 64 KiB selection file;
100 noninternal schema objects and 128 columns per object; 128 foreign keys per
table and 128 columns per foreign key; 16 MiB final stdout. Each database
connection shares approximately five million SQLite VM instructions across its
schema work. Navigation uses existing row bounds: 1–1,000 rows per page,
0–1,000,000 offset, at most eight filters and eight ordering columns.

Both databases are deserialized in memory under query-only/trusted-schema-off
policy. No artifact path, external sidecar, view, trigger or virtual table is
executed. No extraction or source writes occur. Malformed or WAL-mode snapshots,
stale pins, unknown selections and resource violations refuse with exit 1 and no
candidate stdout. Argument errors use exit 2. Success uses exit 0, JSON stdout,
and JSON stderr context with the output hash/size. Check exit status and use fresh
output paths; shell redirection and I/O errors can still leave empty/partial files.

## Functional verification

```sh
PYTHONDONTWRITEBYTECODE=1 MOONFORT_SCHEMA_EVIDENCE=/path/to/fresh-evidence python3 scripts/test-sqlite-schema-comparison.py -v
```

The nine test methods retain synthetic ZIP inputs, editable selections, CLI
commands, stdout and stderr. They exercise the comparison index, changed-table
details, real before/after row navigation and paging, foreign-key drillback in
both directions, quoted composite locators, unsupported/missing objects, stale
pins, whole-bundle tampering, WAL/size/object limits, and existing reader, typed
filter, CSV, keyed-comparison, summary and member-drillback compatibility.
These are source-level Python checks, not independent product acceptance.
