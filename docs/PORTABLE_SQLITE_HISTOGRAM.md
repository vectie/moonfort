# Explore numeric bands in retained SQLite results

MoonFort retains execution artifacts for inspection. This extends its existing
MOONFORT-W04/W06 artifact exploration: find latency, duration or score ranges
that dominate a retained result, then inspect their original row identities.

First run the ordinary SQLite `schema` command against a retained review ZIP.
Copy the database fingerprint and choose a stored table and numeric column.
Save a recipe such as:

```json
{"database_sha256":"REPLACE_WITH_INSPECTED_SHA256","table":"samples","column":"latency","boundaries":[{"type":"integer","value":"0"},{"type":"integer","value":"10"}],"where":[]}
```

Run from the repository root:

```
python3 -B tools/sqlite_review.py review.zip --database results/samples.sqlite histogram --selection bands.json > new-bands.json 2> new-context.json
```

This produces bands below 0, from 0 inclusive to 10 exclusive, and at least 10.
Every band includes its count, exact typed values and original row locators,
including empty bands. NULL, text and BLOB values have separate excluded groups
with their own counts and locators; numeric-looking text is never coerced.
Each member also includes the complete stored record in `values`, aligned with
the output's `columns` list. This lets you inspect a band's records directly,
including tables whose hidden rowid cannot be used in the ordinary row filters.

Supply 1–32 strictly increasing typed integer or real boundaries. Comparison is
exact for stored signed 64-bit integers and IEEE binary reals, including integers
beyond JavaScript's safe range. Real strings are parsed as binary floating-point,
not exact decimal fractions. Optional `where` uses existing typed SQLite filters.
The full bounded selection is scanned, not just a page: at most 10,000 rows and
16 MiB projection/output. Exceeding a bound fails without partial stdout. Retain
the original ZIP, recipe and output together. The input ZIP is never modified.

Python standard library and existing SQLite reader requirements apply. This is
local retained-copy analysis, not live database access, execution approval,
authenticity verification or release qualification. Native source is unchanged.
