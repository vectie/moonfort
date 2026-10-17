# Inspect one retained SQLite review copy interactively

The optional Python standard-library workbench removes handwritten selection JSON
and locator copying from a local review journey. It reads and validates one existing
MoonFort review ZIP at startup, pins the verified database bytes in memory, and
serves only on IPv4 loopback. It does not run an executor or promote a result.

From this source root, with Python 3.11+, SQLite 3.37+ and deserialize support:

    PYTHONDONTWRITEBYTECODE=1 python3 tools/sqlite_workbench.py review.zip --database results/review.sqlite

Open the printed 127.0.0.1 URL in your local browser. Its fragment contains a
random per-process token; the page removes that fragment from the address bar
and retains the token only in page memory. Do not share the launch URL. Reloading
the sanitized URL requires reopening the original printed URL. Ctrl-C ends the
session. The server does not open a browser automatically or install anything.
Do not expose this server through a proxy, tunnel, or port forwarding.

## Review journey

1. Expand origin receipt and pinned fingerprints to inspect retained provenance.
2. Choose a table and page size. Add typed filters using exact text, signed Int64
   decimal strings, finite real strings, canonical base64 BLOBs or NULL. Choose an
   order column and direction, then Inspect table. Between uses inclusive bounds.
3. Use Next/Previous to page. Click a row's outgoing “To” or incoming “From” FK
   button to follow one declared relationship. Each step uses the exact typed row
   locator and pinned digest. Back restores the previous successful result and
   recipe, including page position; it does not alter the table/filter editor.
4. Enter one read-only SQL statement with positional ? placeholders. Add typed
   parameters in placeholder order and select the complete-result row bound.
   Exceeding that bound refuses the whole query. SQL ordering is only the supplied
   ORDER BY. Query-derived rows intentionally have no inferred FK links.
5. For a category comparison, choose distinct Row axis and Column axis fields,
   then Explore crosstab. This uses the selected table and current typed filters,
   independently of page size and ordering. The matrix shows all intersections,
   row/column totals and the complete matching-row count. Click any count,
   including zero, to inspect its exact original member records. Back restores
   the matrix without rereading or changing its filters; another Back restores
   the preceding successful view. Editing controls does not change an existing
   matrix until Explore crosstab is pressed again.
6. For a numeric distribution, choose a stored Numeric column and enter 1–32
   typed integer or real boundaries in increasing order, then Explore numeric
   bands. The default boundary is integer 0. Add/remove boundaries as needed;
   mixed-storage columns are allowed. This uses the table and typed filters,
   independently of page size and ordering. Each band shows its count, with
   separate excluded NULL/text/BLOB counts and a complete matching-row total.
   Click any band or excluded count, including zero, for its original records.
   Back restores the same distribution and its filters without another query.
   Editing controls or a refused request does not change the displayed result.

The crosstab uses the existing exact typed category reader. Integer 7 and text
“7”, NULL and text “NULL” stay separate. No grouping is inferred from display
labels. It scans at most 10,000 rows, allows at most 64 categories per axis and
refuses exceeded bounds instead of presenting partial totals. Cell members are
the original records already bound to that successful matrix, with no second
query, sampling or inferred relationship links. Empty selections show a zero
total. This is retained-output exploration only.

Numeric bands reuse the existing [histogram reader](PORTABLE_SQLITE_HISTOGRAM.md).
Lower boundaries are inclusive, upper boundaries exclusive, and the tails are
unbounded. Signed Int64 boundary strings and original integer cells never pass
through JavaScript Number. Real strings use IEEE binary floating-point, and the
reader compares stored integers/reals exactly as rational values. Numeric-looking
text is excluded rather than coerced. Full original records and their locators
remain bound to the distribution; member inspection performs no new query.
The same 10,000-row scan and 16 MiB projection/output limits refuse an oversized
result without partial totals. Empty selections retain all zero-count bands and
excluded groups. Numeric bands are an inspection aid, not a statistical model.

Cells show the storage class and exact value. Integers are never converted through
JavaScript Number, BLOBs are canonical base64, and NULL is visibly distinct from
text “NULL” or empty text. Table names, column names, errors, and values are placed
with textContent, not HTML. Foreign keys are declarations, not integrity proofs.

## Download the records you are inspecting

Use **Download displayed rows CSV** to take the actual visible table page,
relationship page, complete query result, or selected matrix/band member records
into another local tool. The export uses the last successful view without another
SQL request. Changing editor controls, a pending request or a refused request does
not change those records. Back restores both the view and its download.

Table and relationship exports include only the displayed page, with its offset
shown beside the buttons. They are not an export of every filtered record. Query
exports include the complete bounded SQL result, including any intentional SQL
LIMIT. Matrix/distribution overview downloads are disabled: click a count first
to export only that intersection or band's original records. Empty record views
produce CSV headers or an empty JSON rows array.

CSV is UTF-8, uses quoted fields and CRLF record separators, and retains column
order, duplicate labels, exact integer strings and original cell text. NULL is
an empty CSV field; BLOB values are base64. Storage classes and the distinction
between NULL and empty text are available in **typed JSON**, along with original
row locators where applicable, database/source context and page or member scope.
Query-derived rows have no inferred original locator. Member exports omit other
matrix cells and bands. No session token is included in either format.

CSV does not neutralize formula-like text or stop spreadsheet type inference.
Import it as text in spreadsheet software; use typed JSON when exact storage
types matter. Downloads use fixed filenames and the browser's ordinary download
handling. Keep downloaded data private unless sharing is separately authorized.
No source is modified, command executed, or artifact promoted.

The production-JavaScript DOM harness captures the actual Blob download bytes
and checks CSV quoting, Unicode, duplicate headings, exact Int64/BLOB/NULL JSON,
page bounds, empty selections, query and member records, Back, pending/refused
requests and object-URL release. It is not graphical-browser download testing.

## Save and reopen an editable SQL worksheet

Use **Save SQL worksheet** to download `moonfort-sql-worksheet.json`. It saves the
SQL editor's current text, typed parameter editors in positional order, and the
row-bound editor text. It saves the draft you are editing, independently of any
last successful query. Integer and real strings are not converted to JavaScript
numbers. Empty text, BLOB base64, and even text temporarily hidden by a NULL
parameter's disabled input are preserved. An unfinished SQL or parameter draft
can be saved; only **Run read-only query** asks the reader to validate and run it.

In the same session, or after restarting the workbench with the original retained
ZIP and database artifact, choose the file under **Reopen SQL worksheet**. The
local file is read in the browser and must match the exact database SHA-256,
bundle SHA-256, manifest SHA-256 and artifact path. The manifest hash binds its
origin receipt; a different receipt/bundle refuses even if database bytes match.
Repacking a ZIP changes its bundle identity, so use the original retained ZIP.
No pathname from the worksheet is opened by the server.

Reopening replaces the actual SQL/parameter editors, clears old results and Back
history, and cancels older in-flight results. Review or change the restored draft,
then explicitly press **Run read-only query**. Reopening sends no API request and
never runs SQL. The fresh session's current token and session identity are used
only when you later Run; they are never read from the worksheet. The existing
SQLite read-only authorizer, request limits and query bounds still apply.

The worksheet contains no results, session identifier or token, but its SQL and
parameter text can contain private data. Keep it local unless sharing is separately
authorized. Downloading or reopening it does not authenticate the source, grant
execution authority, accept output or promote an artifact. This is not encrypted
storage, autosave, cross-database migration or a complete workbench-session file.

The versioned JSON envelope rejects unknown fields and malformed shapes before
changing any editor. Files are limited to 256 KiB and must be valid UTF-8 JSON;
SQL and the parameter-editor JSON are each limited to 64 KiB, with at most 128
parameters. SQL uses the textarea's LF line endings; individual parameter inputs
are single-line strings. The numeric row-bound input is saved as its exact string
(or empty for an unfinished draft), limited to 32 characters. These checks guard
the editor representation; they do not approve a query or its typed values.

Cancelling, unreadable files, foreign identities or malformed/oversized files
leave the previous editor and displayed result untouched. If you edit while a
file is loading, it refuses instead of overwriting your newer work. A second file
selection, cancellation, or explicit navigation/Run supersedes an older file read.
Selecting a previously refused file again is supported.

The worksheet regression uses actual downloaded Blob bytes and fresh loopback
Workbench instances, including a same-database/different-origin bundle and a
changed database. Production JavaScript restores controls and actual reader
results are checked only after explicit Run. It covers typed precision, editing,
repeat save/reopen, malformed/cancelled input and interrupted/overlapping reads.
The minimal DOM does not qualify a graphical browser's file picker, download
dialog, input rendering, accessibility, or installed-host lifecycle.

## Fixed-copy and local access boundary

All supplied artifact bytes are verified against the existing bundle manifest
before serving. Replacing the archive at its original path does not alter this
session. Start a new process to inspect a new revision. Every exploration request
must supply the process session and database digest; stale values refuse. Late UI
responses cannot overwrite a newer navigation or Back action.

The server accepts exact Host and Origin values and a per-process random header
token. The bootstrap call also needs that token. There is no CORS allowance,
cookie-based session, arbitrary host-file endpoint, archive-switch endpoint,
external dependency, or outbound network request. CSP denies inline scripts,
framing and third-party resources. HTTP connections time out after five seconds.
These checks reduce browser cross-origin and rebinding risk; they are not a
sandbox against an already-compromised local account or a production web service.
The single-threaded server can be stalled by local connections until timeout.

Existing SQLite authorizer, allowed functions, in-memory database setup, progress
budget and output limits remain in the shared reader. No SQL write, ATTACH,
load_extension or unsupported function gains permission. The small optional
byte-input adapter to query_output avoids temporary query/parameter files and
applies the same 64 KiB individual input bounds as the CLI. HTTP request bodies
are capped at 192 KiB and responses at 16 MiB. Existing limits include 20 MiB ZIP,
1 MiB database, 64 KiB row recipe, page sizes 1–1000, offset up to 1,000,000, query
result bound 1–10,000, and approximately five million SQLite VM instructions per
operation. These are bounds, not a wall-clock guarantee. Source/private data is
not redacted; review does not authorize sharing.

## Verification and limits

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-sqlite-workbench.py

The test uses real retained-format ZIP fixtures, the real loopback server and
production JavaScript through a minimal DOM harness in Node. It covers typed
filters/order, pages, forward/reverse references, Back, SQL parameters, Int64/BLOB/
NULL, literal hostile names, stale in-flight results, fixed-copy binding, write/
ATTACH/unsafe-function refusals, request bounds, and Host/Origin/token checks.
It also exercises crosstab controls, exact NULL/text/integer categories, typed
filters, totals, exact original members, empty intersections and Back over the
real HTTP server. Existing `scripts/test-sqlite-crosstab.py` covers the underlying
reader and CLI including real/BLOB categories and the category bound.
Numeric-band tests cover explicit mixed integer/real boundaries, inclusive and
exclusive edges, adjacent integers above JavaScript's safe range, filtered totals,
excluded storage classes, original records, empty selections, invalid boundaries,
Back, and stale replies after member/Back navigation. Existing
`scripts/test-sqlite-histogram.py` also exercises the reader and retained-ZIP CLI.
It is not a graphical browser, accessibility, real executor, provider, native
producer, containment, hardware or full-product qualification.

This is a narrow W04/B09 inspection increment and prepares only the “open retained
artifact and origin receipt” part of W06. It does not satisfy selective promotion,
approval, destination conflict or recovery requirements. The existing command-line
[relations](PORTABLE_SQLITE_RELATIONS.md), [incoming references](PORTABLE_SQLITE_REFERENCING.md)
and [SQL review](PORTABLE_SQLITE_QUERY.md) remain available unchanged.
