# Edit a retained JSON result into a reusable candidate

Use `browse-retention edit-json` when a generated JSON document needs a few
corrections, an additional row, or removal of draft-only fields before reuse.
It reads the original retained artifact through the same binding, expiry and
fingerprint checks as the JSON explorer, applies a local edit recipe in memory,
and emits a new candidate. It never overwrites retained evidence or promotes
anything into a workspace.

## Workflow

1. Inspect the original with `browse-retention json report.json --pointer /rows`.
2. Create a local UTF-8 recipe file using the pointers you inspected.
3. Run the compiled CLI with the existing executor configuration and actual
   receipt binding. Choose new output paths and check the process exit status.
4. Open the candidate, keep its context and recipe, and review it separately.

```json
{
  "version": 1,
  "operations": [
    {"op": "set", "pointer": "/rows/0/status", "value": "ready for review"},
    {"op": "remove", "pointer": "/rows/0/scratch_note"},
    {"op": "set", "pointer": "/rows/-", "value": {"id": 3, "note": "added locally"}},
    {"op": "set", "pointer": "/editor_note", "value": "Candidate only"}
  ]
}
```

```sh
export MOONFORT_EXECUTOR_CONFIG=/absolute/path/to/existing-executor-config.json
browse-retention edit-json report.json --recipe local-edits.json \
  < receipt-binding.json > new-candidate.json 2> new-candidate.context.json
```

Stdout is one ordinary JSON document followed by LF. On success, stderr is one
JSON context record: original binding and file fingerprint, exact recipe-byte
SHA-256, candidate-byte SHA-256, candidate byte size and operation count. The
candidate digest includes its final LF. On failure stderr is a diagnostic and
stdout contains no candidate for recipe/validation failures. I/O failures can
still leave partial redirected files: use only outputs from a successful run.
Shell redirection may create or truncate files before the command starts, so
never redirect to an original input or existing valuable file.

The retained source fingerprint describes the original execution output. It
does not describe the edited candidate. Context is local derivation metadata,
not a new execution receipt, reviewer approval, or evidence that the edits are
correct. Keep the exact recipe bytes with it; their digest changes if the recipe
is reformatted. A candidate does not become a retained artifact and cannot be
promoted under its source's old fingerprint. Any later durable acceptance needs
the destination owner's separate supported review/authorization workflow.

## Version-1 recipe semantics

The root has exactly `version` and `operations`. Version must be the literal
JSON integer `1`. There must be 1–100 operations. Each has exactly `op` and `pointer`; `set`
also requires `value` (including an explicit null), while `remove` forbids it.
Unknown operations or extra keys refuse. This is a small MoonFort recipe format,
not JSON Patch or JSON Merge Patch.

- Operations run in order against the result of the preceding operation.
- Pointers use `/`-separated keys; `~1` denotes `/` and `~0` denotes `~`.
  Empty pointer selects the entire document. `/` selects an empty object key.
- `set` replaces any existing value, or creates a final object key. All parent
  containers must already exist. It does not infer containers from key names.
- For arrays, `set` replaces an existing canonical zero-based decimal index.
  `set` at a final `/-` appends one value, even to an empty array. Index equal to
  length is not an append; use `/-`. Leading-zero, negative and fractional array
  indexes refuse. Object keys such as `01` and `-` remain literal keys.
- `remove` requires an existing object key or array element. Removing an array
  element shifts later indexes, so later operations see the new positions.
  Removing the entire root is unsupported. Set it to null/empty collection if
  that is the intended candidate.
- Traversing a scalar, a missing parent, or an out-of-range array index refuses
  the entire derivation. No partial candidate is emitted by validation failures.
- Original and recipe number tokens remain exact, including large integers,
  exponent spelling and negative zero. No numerical arithmetic is performed.
  Whitespace and string escaping may change; use `export` for original bytes.
- Duplicate decoded object keys refuse in both source and recipe. Unicode keys
  and values work. URI-fragment pointers, filters, wildcard operations and
  implicit array insertion are not supported.

## Limits and API

Source: at most 1 MiB, valid UTF-8 JSON, at most 64 nested containers and 20,000
values. Recipe: regular local file, at most 64 KiB with the same JSON parser
limits. Pointer: at most 4096 UTF-8 bytes. Candidate: at most 1 MiB including the
final LF; aggregate nesting and value limits are rechecked after every operation.
Context including its LF must fit the configured protocol budget. Edits are
read-only with respect to existing files; there is no network or workload run.

Native callers can use:

```text
draft_retained_json(binding, retained_relative_path, config, recipe_bytes)
  -> RetentionJsonDraft
draft.context() -> Json
draft.value.stringify() + "\n" -> candidate bytes before UTF-8 encoding
```

The result includes `binding`, `file`, `recipe_fingerprint`,
`candidate_fingerprint`, `candidate_size_bytes`, `operation_count` and `value`.
The API takes bytes so the recorded recipe fingerprint is exact. The existing
JSON explorer remains useful for discovering pointers; editing is a separate
command and cannot be combined with explorer paging or formatting switches.

## Focused native verification

Build `cmd/browse-retention`, set `MOONFORT_ARTIFACT_READER_CLI` to that executable,
then run `executor/retention_json_draft_wbtest.mbt`. All Moon commands should use
an explicit external `--target-dir` and the supported native toolchain. Tests
cover ordinary object/array edits, exact scalar forms, pointers, sequential
operations, input/output limits, malformed recipes, original evidence unchanged,
compiled CLI output re-opening and source/recipe/candidate digests. Set
`MOONFORT_JSON_DRAFT_EVIDENCE` to an existing private directory to save the actual
synthetic CLI examples. This does not qualify process containment or promotion.
