# Retained HAR source API migration

The compiler reserves `method` as a source identifier. `RetentionHarTable` now
exposes `http_method`, and `tabulate_retained_har` accepts `http_method=...`.
Update record constructors, field access and strict source callers accordingly.
The optional argument retains a `method=` label alias for ordinary older callers;
the compiler still reports reserved-word warning 35 for that old spelling, so
callers using `--deny-warn` must use `http_method=`.

The serialized table keeps the JSON key `method` in both directions. HAR request
JSON, CSV columns, context selection keys and CLI `har-csv --method` are
unchanged. This migration does not change retained bytes, filter behavior,
artifact identity, authority, execution or network policy.
