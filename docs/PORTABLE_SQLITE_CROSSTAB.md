# Cross two categories in retained SQLite results

MoonFort retains execution artifacts for inspection. Compare owners against
statuses, suites against outcomes, or machines against error classes with a
two-axis count matrix and directly inspect each intersection's original records.
This extends PRD W04/W06 artifact exploration, using the existing retained ZIP
reader. It does not edit a database, run a command or promote an artifact.

Run the existing `schema` command first. Save the inspected database fingerprint
and two distinct stored column names in a local recipe:

```json
{"database_sha256":"REPLACE_WITH_INSPECTED_SHA256","table":"samples","row_column":"owner","column_column":"status","where":[]}
```

From the repository root:

```
python3 -B tools/sqlite_review.py review.zip --database results/samples.sqlite crosstab --selection axes.json > matrix.json 2> matrix-context.json
```

`row_keys` and `column_keys` label the `counts` matrix. Every intersection is
present, including zeros. `row_totals`, `column_totals` and `selected_row_count`
make comparisons easy. Each occupied entry in `cells` has zero-based matrix
indices and original row locators plus all stored values, in the order named
by `columns`, so the underlying records can be inspected immediately.

Categories preserve exact SQLite storage classes: integer 1, real 1.0, text "1",
BLOB bytes and NULL stay separate. Axes sort lexically by compact typed JSON,
not numerically. Existing typed `where` filters are optional. Empty selections
produce empty axes and zero total. The complete bounded selection is scanned:
at most 10000 rows, 64 categories per axis and 16 MiB projection/output.
Exceeding a bound produces no partial stdout; narrow the recipe and rerun.

Python 3.11+, SQLite 3.37+ with deserialize support, and standard library only.
Run `python3 -B scripts/test-sqlite-crosstab.py -v`. Retain the original ZIP and
recipe with the result. Production sandbox, host UI and release gates remain
separate and are not qualified by this local retained-copy analysis.
