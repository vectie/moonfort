# Explore retained browser request timings

When a task retains a browser HTTP Archive, use `har-csv` to find the slow or
failed requests, inspect their reported timing phases, and reopen a selected
original entry. This closes a gap between the retained file inventory and useful
network-request inspection. The existing generic JSON projection cannot compute
phase totals or distinguish HAR's unavailable timings from measured zero.

```text
browse-retention har-csv logs/session.har < receipt-binding.json > new-requests.csv 2> new-requests.context.json
browse-retention har-csv logs/session.har --status 503 --minimum-ms 100 < receipt-binding.json > new-slow-errors.csv 2> new-slow-errors.context.json
browse-retention har-csv logs/session.har --method GET < receipt-binding.json > new-get-requests.csv 2> new-get-requests.context.json
browse-retention json logs/session.har --pointer /log/entries/1/response/status --value < receipt-binding.json
```

Use the existing trusted `MOONFORT_EXECUTOR_CONFIG` and receipt binding described
in [the retained browser guide](RETAINED_ARTIFACT_BROWSER.md). The new command is
part of the existing `cmd/browse-retention` native executable. Use a fresh output
filename: shell redirection can truncate a destination even when a command
refuses. Check exit status before opening redirected CSV.

## Selection and inspection

- Filters combine with AND. Method is an exact, case-sensitive string; omitted
  or empty means all methods. Status is an exact integer in 0..999, including a
  recorded zero. No HTTP success/failure meaning is invented for zero.
- `--minimum-ms` is an inclusive, finite nonnegative JSON number matching the
  recorded request `time`. It may include a decimal or exponent.
- Every entry is checked before any output is emitted, even if filters exclude
  it. A late malformed entry refuses the complete candidate with empty stdout.
- Output follows original `log.entries` array order and keeps duplicates. Each
  row carries a zero-based JSON Pointer into the exact retained source. Start
  timestamps are verbatim labels: no timezone conversion, chronology, sorting,
  or waterfall positioning is inferred.
- Edit the command's filters and rerun to inspect another selection. A selection
  with no matches succeeds with its header and `row_count: 0` in context.

The 21 CSV columns include entry pointer, page reference, start label, method,
URL, status, MIME type, declared duration, seven timing phases, known-phase sum,
duration difference, unavailable phase count and request/response/content bytes.
Open the CSV with a CSV-aware tool, then use a row's pointer with `json --value`
to retrieve the exact scalar or subtree you need. The CSV is a local candidate;
it does not become a new retained execution record automatically.

## Timing and size meaning

The field meanings follow the [HAR 1.2 format](https://github.com/ahmadnassri/har-spec/blob/master/versions/1.2.md).
Primary historical references are [Jan Odvarko's format description](https://www.softwareishard.com/blog/har-12-spec/)
and the [Web Performance working draft](https://webperfwg.org/specs/HAR/Overview.html).
The latter is explicitly abandoned and never became a W3C recommendation; this
reader claims only its declared projection subset, not standards conformance.
Timing values are milliseconds. Missing optional blocked/DNS/connect/SSL values
and permitted -1 values become blank cells, while measured zero stays zero.
Send, wait and receive must be present and nonnegative. SSL remains visible but
is excluded from the phase sum because it is already included in connect.

`known_phase_sum_ms` sums only supplied blocked/DNS/connect/send/wait/receive
values. `unavailable_phase_count` counts missing members of these six phases.
`total_minus_known_phases_ms` subtracts that sum from the supplied request total.
This descriptive difference can be negative or reflect unreported time or
rounding. It is not an acceptance threshold, diagnosis, recomputed total, page
load time or proof that the capture is internally correct. Binary64 arithmetic
can round small differences; non-finite inputs or an overflowing sum refuse.

Request and response body sizes of -1 become blank. Content size is retained
separately, without inferring compression or actual network traffic. Other size
values must be exact nonnegative integers no greater than 9,007,199,254,740,991.
Integer checks use the original decimal coefficient and exponent independently
of binary64 rounding: `1.00` and `1e3` are exact integers; fractions such
as `1.00000000000000001` are refused. The -1 unavailable sentinel must also be
exact. Mathematically negative nonzero inputs are refused even if binary64
underflows them to negative zero. Source number spellings are preserved in
direct scalar columns.

## Input limits and privacy

This is a HAR 1.2 request projection, not a whole-schema validator. It requires
`log.version: "1.2"`, `log.entries`, each entry's start/time/request/response/
timings, request method/URL/bodySize, response status/bodySize/content and content
size/mimeType. Optional pageref is copied without resolving pages. Unselected
metadata is not interpreted. The original remains available for deeper review.

The file must be verified retained UTF-8, at most 1 MiB; an initial BOM is accepted.
The existing JSON reader rejects duplicate keys anywhere, nesting above 64 and
more than 20,000 values. There are at most 5,000 entries, 16,384 UTF-16 units per
selected text cell and 1 MiB of CSV. Whichever limit is reached first applies.
Context must fit the configured protocol budget. No partial truncation or
streaming is claimed. Wrong receipt bindings, expired/claimed retention, changed
bytes and missing files refuse through the existing reader.

Headers, cookies, posted data, response bodies, page metadata and extension
fields are omitted from the candidate. URLs remain verbatim, including private
query strings, paths or embedded credentials. Neither the output nor the
unchanged original is sanitized for sharing. CSV text is preserved rather than
rewritten for spreadsheet formula handling; import text columns appropriately.
No URL, body, script, browser, network request, backend execution or promotion
is launched by this reader.

## Portable example and verified journey

`examples/har-requests/session.har` is synthetic. It contains a GET with 85 ms
total (including 10 ms SSL within 20 ms connect), a 503 POST with 170 ms declared
total and 160 ms known phases, and a cached 304 with explicit zero duration.
The deliberately unequal total is preserved for inspection. Private-field
markers demonstrate omission; they are not credentials.

Create a fresh disposable store with the included `.mbtx` example, an absolute
external Moon target, and a new absolute destination directory:

```text
moon --target-dir /ABSOLUTE/EXTERNAL/script-target run examples/har-requests/prepare-demo.mbtx /ABSOLUTE/SOURCE/examples/har-requests /ABSOLUTE/NEW/har-demo
MOONFORT_EXECUTOR_CONFIG=/ABSOLUTE/NEW/har-demo/config.json browse-retention har-csv session.har --status 503 < /ABSOLUTE/NEW/har-demo/receipt-binding.json > new-slow-errors.csv 2> new-context.json
```

The preparation script uses pinned async 0.20.2 and x 0.4.49 independently of
the unchanged product graph. It creates a synthetic 24-hour retention and no
execution grant. Never use this fixture configuration as a deployed executor.

The round's native tests retain this exact source, discover it through `list`,
select the slow 503, save/reopen its CSV, follow `/log/entries/1/response/status`
through the existing JSON CLI, revise selection to GET and check repeated output.
Source, grants and canonical workspace remain unchanged. These tests establish
offline retained-file inspection only. They do not qualify browser capture,
live host integration, sandbox containment, artifact promotion or release.
