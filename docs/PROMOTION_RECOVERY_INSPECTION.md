# Promotion recovery inspection

`cmd/inspect-promotion-recovery` is the bounded, read-only operator interface
for a promotion left locked as `<retention-id>.promoting` plus
`<retention-id>.claim`. It never promotes, restores, removes, rewrites, or
unlocks anything. A separate, explicitly reviewed recovery procedure must act
on its evidence.

Run it with the same protected `MOONFORT_EXECUTOR_CONFIG` used by the executor.
Its complete stdin request is:

```json
{"protocol_version":4,"retention_id":"opaque-retention-id"}
```

Input is limited by the deployment's `max_protocol_bytes` and the hard 1 MiB
configuration ceiling. The retention ID must be a safe opaque identifier; the
request cannot supply a workspace, destination, host path, expected content,
or filesystem policy.

## Evidence checks

Before inspecting a destination, MoonFort requires all of the following:

- the `.claim` and `.promoting` names are protected regular files, the unlocked
  `.json` name is absent, and both files remain stable during bounded reads;
- the complete retained record in `.promoting` exactly equals the record inside
  `.claim`;
- the claim's one reviewed source/destination item matches the retained
  reviewable manifest and bound profile, approval, command, and workspace IDs;
- the current trusted workspace registry still maps that workspace ID to the
  same canonical path and the same no-follow opened directory identity; and
- the destination can be inspected fd-relative without following any parent or
  final symlink.

New claims store a SHA-256 root binding over a domain label, workspace ID,
canonical registered root, and the opened directory's device/inode identity.
The path and native identity are never returned. Claims created before this
binding existed are deliberately reported as `manual-recovery`; MoonFort will
not guess that a current registry entry names the historical destination.

## Outcomes

- `desired-applied`: the observed regular-file content state equals the
  reviewed source content state.
- `reviewed-prestate`: the observed state equals the reviewed destination state
  from before promotion.
- `diverged`: the destination was safely observed as absent or regular, but
  matches neither bound state.
- `unavailable`: the claim pair or destination could not be safely inspected.
- `manual-recovery`: the historical workspace-root mapping cannot be proven,
  including legacy claims without a root binding.

These are content-state classifications, not proof of which historical rename
step executed. If desired content already equaled reviewed destination content,
the two historical possibilities are inherently indistinguishable.

The response contains only the opaque retention/workspace IDs, bound execution
digests, one safe relative destination path, domain-separated state digests,
the outcome, and a fixed error code/message when applicable. It never contains
canonical host paths, device/inode values, native status codes, provider
diagnostics, or file contents.

Do not automatically unlock or roll back based on this command. Preserve both
locked files and the destination until an operator reviews the claim, this
inspection evidence, application-level invariants, and the intended recovery
action.
