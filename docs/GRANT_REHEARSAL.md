# Check, correct, review, then publish a grant

The existing trusted `grant-publisher` now has a nonpublishing `--check` mode.
Use the same protected `MOONFORT_EXECUTOR_CONFIG` and v3 publication-request JSON
as the existing operator integration. To prepare that ordinary request, use the
[offline request-authoring form](GRANT_REQUEST_AUTHORING.md); its preview and
download convey no approval or grant authority.

1. `grant-publisher --check < candidate.json`
2. If `ready_for_review` is false, correct the reported `correction.field` within
   existing policy and repeat. Checks are fail-first and reuse the publication
   validator, so a later check may expose the next correction.
3. If ready, review the returned exact `candidate`, including workspace identity,
   command and arguments, network/egress, backend, degraded-enforcement choice,
   resource ceilings and expiry. The named approver must also review the trusted
   workspace mapping and executable/backend configuration in the host.
4. After explicit approval, invoke
   `grant-publisher --publish-reviewed REVIEW_DIGEST < candidate.json`.
5. An unchanged permitted candidate publishes through the existing atomic
   single-use grant store. A changed candidate, workspace policy, executable or
   backend binding, missing digest, or expired grant refuses with `review-stale`.
   Recheck and obtain fresh approval; do not blindly retry publication.

The digest detects stale review. It is **not** an approval signature, a token,
proof of identity, or a new permission boundary. These modes are only for the
already-trusted publisher caller. The no-argument v3 publisher remains compatible
with existing trusted hosts; its previous approval requirements still apply.

`--check` never publishes/consumes a grant, creates scratch, runs a process or
probes a backend. It checks candidate policy, not grant-store availability;
publication may still refuse a duplicate ID, unavailable store or changed state.
A passing rehearsal never certifies enforcement. Actual backend availability,
containment, cleanup, task receipt delivery and reviewed artifact promotion
retain their existing separate gates. Unknown flags and malformed input fail
closed. The result carries no trusted host paths or credentials.

## Bounded qualification

`tests/grant-rehearsal-cli.mjs COMPILED-PUBLISHER` drives the real native CLI with
owner-private disposable synthetic configuration, copies of tool binaries that
are never executed, and synthetic grants. It checks correction/recheck, repeated
read-only checks, changed command and trusted binding, expiry, missing review,
invalid arguments/input, exact publication, duplicate refusal and old-client
compatibility. Native tests in `executor/grant_rehearsal_wbtest.mbt` additionally
cover changed limits, working directory and read-root policy. No real grants,
credentials, backend executions, OS permission settings or account access change.

The round's `run-focused.sh` verifies every compiled source and native-binary
SHA-256 before reusing the exact built artifacts, then checks two emitted native
test results and twelve CLI assertions. It accepts an alternate source root for
replay verification. The retained build recipe uses the exact toolchain,
`moonbitlang/async@0.20.4` and `moonbitlang/x@0.4.49`, an external target,
private HOME/XDG and a serialized stripped native build. Full native/security,
Firecracker/AEN, hostile-host and physical-runtime release gates remain unrun.
