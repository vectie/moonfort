# Retained SQLite typed filters

The existing `tools/sqlite_review.py` CLI accepts the same `where` filters in
`rows`, `summarize`, and `group-rows` selections. Filters are ANDed (maximum 8).
There is no SQL expression, implicit numeric conversion, regular expression,
wildcard syntax, OR expression, or locale-sensitive matching.

Every filter has `column` and a typed `value` (`type` and `value`). Existing
filters without `op` remain exact equality. Explicit `eq` is equivalent.
Supported operators:

- `gt`, `gte`, `lt`, `lte`: integer or finite real thresholds.
- `between`: numeric `value` lower bound and typed `upper` upper bound. Both
  endpoints must have the same storage class. `lower_inclusive` and
  `upper_inclusive` default to true; either may be false. Reversed bounds refuse.
  Equal endpoints with an open end produce an empty selection.
- `contains`, `starts_with`: literal, case-sensitive text. `%`, `_`, backslashes,
  quotes, Unicode, and NUL are ordinary text, never LIKE patterns. No Unicode
  normalization or case folding is performed. Empty text matches every text
  cell, including an empty cell, but not NULL or BLOB.

Storage classes must match exactly: an integer threshold excludes real and text
cells even if numerically equal. Signed 64-bit integers are decimal strings and
stay integers during filtering. Real bounds use finite IEEE binary reals.
Numeric comparisons remove column affinity; text matching ignores declared
NOCASE collation. NULL and BLOB equality remain supported; numeric ranges on
them refuse. Unsupported operators and additional fields refuse before output.

Example: `examples/sqlite-filters/range.json` selects integer amounts in (-5, 5].
`literal-text.json` searches for the literal substring `%_`.

Reuse exactly that `where` array in a summary selection with `database_sha256`,
`table`, `group_by`, and `measures`. Save a typed group key from summary output
and use the same summary selection with `group-rows --group group.json`.
Changing filters changes group membership; paged rows do not define a summary.
The shared filter compiler is used by paged selection and full summary scans.
Summary scan and output bounds, database pinning, archive verification, stable
locators, read-only in-memory database handling, and review-only meaning remain
in force. This does not establish authenticity, live state, acceptance,
execution containment, or artifact promotion.
