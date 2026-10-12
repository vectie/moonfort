# Compare retained run outputs

Compare two generated output inventories before deciding which artifacts to
inspect. This is a read-only exploration command, not execution or promotion.
It uses the same executor configuration and exact receipt/workspace bindings as
`browse-retention`.

1. Create a JSON object with `baseline` and `candidate`. Each is the complete
   five-field receipt binding documented in `RETAINED_ARTIFACT_BROWSER.md`.
2. Run `compare-retention < comparison.json` with
   `MOONFORT_EXECUTOR_CONFIG` pointing to the existing executor configuration.
3. Inspect added, removed and changed paths, byte deltas, and before/after SHA256.
4. Use `browse-retention preview PATH` or `export PATH` with the relevant
   original binding to verify selected bytes. Review and promotion remain the
   existing separate workflow.

Options: `--prefix PATH`, `--include-unchanged`, `--limit 1..200`, `--after PATH`,
and `--json`. Output is lexically sorted by relative path. Use `next_after` with
the same prefix/unchanged options to resume JSON pages. The totals and byte delta
cover the full prefix-filtered union, including unchanged entries. `matched`
counts rows eligible for pagination. The byte budget may shorten a page.

A same-size content change is still `changed` because SHA256 differs. Renames
appear as removed and added paths; there is no rename inference or text diff.
Unchanged means the saved manifest size and fingerprint agree. This does not
rehash scratch bytes, establish equivalent authority, approve a run, or assess
the meaning of a changed report. Both records must remain available under their
original binding/lifetime; comparison cannot resume expired or promoted records.

The native tests construct two real synthetic retained iterations (unchanged,
same-size changed CSV, removed binary, new Markdown), invoke the compiled CLI,
then export and reopen the selected candidate CSV. No grant is consumed and no
workspace destination is written. The example output is metadata, not a new
containment or deployment qualification.
