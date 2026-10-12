# Compare the contents of retained output

`compare-retention` identifies files whose saved fingerprints changed.
`diff-retention` answers the next question: what text actually changed? It reads
and verifies the selected file on both sides and writes a contextual unified
diff. This is useful for generated source, configuration, CSV, Markdown and
plain-text reports from successive runs.

## Operator workflow

1. Save the two original receipt bindings as `comparison.json`, with `baseline`
   and `candidate` fields. This is the same input used by `compare-retention`.
   Each binding contains `protocol_version: 1`, `retention_id`, `workspace_id`,
   `approval_digest` and `command_digest`. Copy these from the original execution
   receipt and originating approved task. Do not invent an execution grant.
2. Use the existing operator-owned `MOONFORT_EXECUTOR_CONFIG`. Build the native
   command with `moon build cmd/diff-retention --target native`.
3. Select a path from `compare-retention` or `browse-retention list`:

   ```text
   diff-retention reports/checks.csv < comparison.json > checks.diff
   diff-retention reports/checks.csv --context 0 --json < comparison.json > checks-review.json
   ```

   In the standard build, the executable is under
   `_build/native/debug/build/cmd/diff-retention/diff-retention.exe`; an external
   target directory changes that prefix. The examples assume it is on PATH.
4. Open the exported patch in a text editor or diff viewer. The synthetic sample
   changes the `ui` CSV row from `18,2` to `20,0`, with unchanged rows as context.
   `--context 0..20` selects surrounding lines; the default is 3.
5. `--json` includes both original bindings, optional before/after manifest
   entries (including SHA-256 and byte length), added/removed line counts, and
   the same patch. Keep this JSON when the exported text needs its source
   identities and the distinction between absent and empty files.

Both identical and changed files exit 0. An identical file produces an empty
patch. Exit 1 means no usable result: check configuration, bindings, retention
expiry, path, text limits or options. Check the exit status before using an
export; ordinary redirection can leave an empty file even when the command
fails. Missing/expired/changed sources are not silently treated as deleted.

## What is represented

- A path present in only one saved manifest is an addition/deletion, represented
  with `/dev/null` on its missing side. A path absent from both is an error.
- Minimal line-based edits, merged nearby hunks, and standard unified ranges.
- UTF-8 characters, tabs, CRLF/LF differences and final-newline changes are
  preserved. Missing final newlines use the standard marker. File headers end
  in a tab delimiter, so ordinary names with spaces or Unicode remain usable.
- Empty-file creation/deletion has no text hunk and produces an empty patch;
  use the JSON before/after entries or inventory comparison to see that change.

The implementation and compiled command are tested against GNU `patch`, including
44 cases across four context sizes. Applying a patch is not part of MoonFort's
command. Tests apply only to disposable synthetic copies and compare their
resulting bytes with the expected candidate.

## Bounds and ownership

Each side must be valid UTF-8, at most 256 KiB and 2,000 lines. Binary control
characters other than tab, CR and LF are rejected. Paths containing control
characters are not supported. Binary or larger artifacts can still use verified
`browse-retention export` or `bundle` and an external comparison tool. The
bounded line algorithm uses quadratic time/memory (at most 4,004,001 integer
cells); it does not require an external diff executable.

The input obeys the configured protocol byte ceiling. Patch/JSON exports use
the separate fixed text limits above, like existing direct artifact exports;
they are not paginated or truncated to the protocol/model-output ceiling.
Nothing is written to stdout before all selected bytes are verified and the
diff is constructed. The result is a read-only copy of the bytes actually read,
not an atomic snapshot of two runs or a signed attestation. Retention may expire
after export; downloaded copies remain readable.

This feature consumes no grant, launches no payload, changes no retained result,
and promotes no artifact. Applying an exported patch does not confer promotion
authority. Backend enforcement labels and MoonBook acceptance remain unchanged.
