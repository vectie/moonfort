# Cross-repository promotion evidence

On 2026-08-12, the protocol-v4 promotion contract was rehearsed through the
current MoonFort, MoonClaw, and MoonDesk validators. The isolated bundle and
exact sanitized JSON are recorded in
`/private/tmp/promotion-v4-rehearsal/README.md` for the local qualification run.

## Real filesystem evidence

The MoonFort fixture used the production retention and promotion code against
private temporary roots:

- `allocate_scratch` and `retain_scratch` retained one reviewed regular file
  with its exact size and SHA-256 fingerprint.
- Substituting a valid-shaped command digest returned protocol-v4
  `not-applied`; the canonical destination remained absent and the retention
  remained available for a safe retry.
- Retrying the exact request applied one file durably. Its canonical bytes
  matched the retained artifact, and the scratch directory, retention record,
  `.promoting` record, and `.claim` were all consumed.
- Replaying the consumed request returned `not-applied` and did not alter the
  promoted bytes.
- A second real retention was moved into a durable `.promoting` plus `.claim`
  recovery lock. Expiration sweeping preserved the lock, read-only inspection
  reported `reviewed-prestate`, and a promotion retry was refused while the
  lock remained.

The applied, digest-refusal, and replay responses were emitted directly by
MoonFort's `promote_retention` implementation.

## Consumer validation and sanitization

MoonClaw consumed the exact MoonFort responses with its private protocol-v4
parser and state-matrix validator, then emitted its sanitized public evidence.
MoonDesk consumed that exact output through both its server-side broker
validator and its shared MoonCode result validator. Both consumers enforced the
exact workspace, retention, approval-digest, command-digest, and destination
bindings. A substituted applied digest was rejected.

The sanitized evidence contains no host path, workspace/scratch/retention root,
provider or native diagnostic, native status, or raw MoonFort error message.

## Recovery qualification boundary

The durable recovery lock is real filesystem evidence. The subsequent
`recovery-required` response used to exercise MoonClaw and MoonDesk is
synthetic because the native promotion helper currently has no fault-injection
hook. It was constructed only after proving the genuine locked state and is not
claimed as an observed post-rename native failure.

The focused qualification passed:

- MoonFort rehearsal 1/1 and promotion slice 3/3;
- MoonClaw rehearsal 1/1 and promotion contract 6/6;
- MoonDesk rehearsal 1/1, broker 3/3, shared core 2/2, and UI 5/5.

This supersedes the earlier protocol-v3 two-file rehearsal. Protocol v4 accepts
exactly one reviewed item per request and requires its canonical destination
parent to exist before promotion.
