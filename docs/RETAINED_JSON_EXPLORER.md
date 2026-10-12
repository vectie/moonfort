# Explore and reuse retained JSON

A saved execution may contain a nested report rather than a CSV table. Use the
existing artifact reader to inspect its keys and array entries, then extract the
part you need as a reusable JSON value. This reads existing retained output;
it does not run a command, consume a grant, change scratch, or promote an artifact.

## Open a report and follow its pointers

Use the existing executor configuration and exact five-field receipt binding
from [the retained artifact browser](RETAINED_ARTIFACT_BROWSER.md). The binding
must refer to a current retained artifact, not a loose file or an invented grant.

```sh
browse-retention json reports/details.json < receipt-binding.json
browse-retention json reports/details.json --pointer /checks --limit 1 < receipt-binding.json
browse-retention json reports/details.json --pointer /checks --after-child 1 --json < receipt-binding.json
browse-retention json reports/details.json --pointer /checks/0 --value < receipt-binding.json > selected.json 2> selected-context.json
```

The last command writes a typed JSON value to stdout and a one-line context JSON
to stderr. Keep both files. Context retains the original receipt binding, relative
artifact path, size, SHA-256 and selected pointer; `derived_selection` is true.
It identifies the original source bytes, not a newly retained or approved artifact.
Errors also use stderr: check exit status before treating it as a context record.
The shell creates redirection files before the process runs; use fresh paths.

`--json` exports the child-list page with the same source context. Without it,
the human view prints types, pointers and short scalar previews. Strings use JSON
quoting. A preview is limited to 120 Unicode characters and explicitly marked
when shortened; it is not reusable JSON when shortened. Objects and arrays show
their direct-child counts. `--value` exports the full selected value, not a preview.

## Pointer and page rules

- An omitted pointer or empty string selects the whole document.
- `/checks/0` selects array element zero under the object key `checks`.
- Encode `/` inside a key as `~1` and `~` as `~0`. For example `/a~1b/~0tag`
  selects `~tag` inside `a/b`. `/` selects the empty-string root key.
- Object keys match exactly, including Unicode. Object `01` is an ordinary key;
  array indices must be canonical decimal (`0`, `1`, ...), never `01`, `-` or `+1`.
- URI fragments and percent decoding are unsupported. Missing keys, out-of-range
  indices and attempts to traverse a scalar produce a diagnostic and nonzero exit.
- Children of an object use lexical key order; arrays retain numeric index order.
  `--after-child N` means N direct children have already been consumed. Copy the
  returned `next_after_child`, keeping the same pointer and source binding.
- `--limit` is 1–100, default 20. The configured response budget can shorten a page.
  The next cursor advances only over returned entries, so no child is skipped.
- Empty objects, empty arrays and scalar values have no child rows. The selected
  type remains visible, distinguishing `null`, `false`, an empty string and an
  empty collection. Cursor zero is valid even when there are no children.
- `--value` cannot be combined with paging or `--json`. Raw whole-file `export`
  remains available when the desired selection is too large for the protocol.

## Exact values and honest limits

The input must be a retained, strictly decoded UTF-8 JSON file of at most 1 MiB,
with at most 64 nested containers and 20,000 JSON values including containers and
scalars. A BOM is not accepted. Object keys are not additional values. Duplicate
object keys anywhere in the document are rejected, including escaped-equivalent
spellings such as `x` and `\u0078`, rather than silently selecting one value.
Unicode normalization is not performed: different Unicode sequences remain
separate keys. The standard MoonBit parser governs syntax and rejects unpaired
surrogate escapes.

Pointer input is at most 4096 UTF-8 bytes. Extremely long keys or paths can exceed
that navigation limit or the page response budget; use whole-file export for
those artifacts. The configured `max_protocol_bytes` bounds the complete public
page or selection response, including source metadata. If a single child or
selection cannot fit, the command refuses without a partial stdout report.

Extraction retains exact numeric spellings, including large integers, exponent
notation, trailing zeros and negative zero. It performs no numeric arithmetic.
Very large exponent tokens remain JSON number tokens; this is not a claim that a
consumer's numeric type can represent them. Use a parser that preserves numeric
precision when consuming the output. Whitespace, string escape spelling and
object serialization order are not promised to match the original file. For
byte-for-byte retention, use the unchanged whole-file export command.

The existing binding, expiry and fingerprint checks still apply. Child listings
and extraction neither sanitize confidential content nor establish approval,
semantic truth or containment. Treat output and its receipt context as private
artifact-review data. No new server, graphical interface or provider is involved.
