# ExecutionSandbox completion audit

This file is the exit checklist for the MoonSuite execution boundary. A green
package test is evidence for a row only when the named adversarial behavior is
covered. `Complete` means the current implementation and verification prove
the requirement; `In progress` and `External proof required` are not release
claims.

| Requirement | Current evidence | Status |
|---|---|---|
| Separate executor authority | `executor/` accepts protocol-v3 approval IDs only, consumes a private single-use grant, and resolves workspaces, tools, credentials, limits, and scratch from executor-owned configuration. | Complete |
| Immutable approval manifest | Approval and command digests cover the command/arguments, relative working directory, backend/config binding, workspace/profile, tool bindings, network policy, and limits. Substitution and replay tests live in `executor/executor_wbtest.mbt` and MoonClaw's execution-sandbox tests. | Complete |
| Canonical workspace is never the execution cwd | Local execution materializes a private snapshot into executor-owned scratch. The real local E2E asserts canonical writes fail and only scratch changes are retained. AEN must independently bind the provisioned workspace content digest. | In progress |
| Path-race-safe reset and promotion | `sandbox/secure_fs.c` walks pinned dirfds with `openat`/`fstatat`/`unlinkat`/`renameat`, rejects link/inode swaps, hashes the fd-pinned source during promotion, and has adversarial swap tests. | Complete on native targets |
| Default-deny network | Local profiles deny network and refuse any unsupported policy. AEN now requires exact top-level internet, private-traffic, and IPv4 rule readback plus digest-pinned in-guest proof that IPv6 is absent or disabled. The real canary pairs a fixed unrestricted positive control with exact policy-denial evidence; arbitrary connection failures are rejected. | Implemented; live AEN proof pending |
| CPU, memory, wall, output, disk, and process limits | The local native supervisor applies rlimits, a monotonic deadline, bounded merged output, process-group counting, and aggregate scratch monitoring. Receipts explicitly list limits the shared-kernel backend cannot verify. AEN must enforce and attest every requested limit. | In progress |
| Descendant cleanup | Local execution kills the process group and bounds post-kill drain; escaped sessions make cleanup unverified and the run refused. AEN terminal receipts export reviewable regular bytes before requiring verified VM deletion and workspace-lease release; combined cleanup handles retain every known unresolved VM/lease obligation. | Complete for implemented backends; deployment E2E required |
| No silent fallback | Backend probes are behavioral. Missing, degraded-without-opt-in, malformed, or unverifiable enforcement returns a refusal. MoonClaw and MoonDesk boundary guards reject new raw production process authority. | Complete |
| Lifecycle | `start`, `exec`, `stop`, `reset`, and `snapshot` are represented by the sandbox lifecycle; AEN also supports pause/resume/fork. Receipts bind terminal state and cleanup. | Complete at contract level; AEN deployment proof required |
| Bounded artifacts and diff | Scratch inventory never follows links, produces structured relative changes, and enforces byte/path limits. AEN added/modified regular files are exported before VM cleanup through a fixed digest-bound, path/size/SHA-256-bound protocol capped at 8 MiB per file and one profile-derived post-run deadline; the host rehashes the exact regular-file subset. Symlinks, specials, directories, and removals cannot become artifacts. Retention is opaque and TTL-bound. | Implemented; live AEN proof pending |
| Explicit reviewed promotion | `cmd/promote-retention` requires the retention ID plus approval/command digests and exactly one explicit file mapping. It restricts the source to the retained review manifest, requires destination parents to pre-exist, and revalidates fingerprints, reviewed destination state, and ancestry before atomic promotion. Native outcomes distinguish durable apply, proven non-apply, and recovery-required uncertainty; cancellation is protected and uncertain `.promoting` claims stay locked rather than being swept or replayed. Fake-transport adversarial tests prove one selected Enforced microVM export is promotable once while forged bytes and artifact substitution are refused. A real authenticated MoonDesk-shaped local request through MoonClaw promoted one selected file, consumed retention, refused replay/digest substitution, and returned no host paths. Automated operator reconciliation of a recovery-required claim remains open. | Truthful single-file outcome complete; recovery inspection tooling pending |
| MoonClaw enforcement point | `internal/execution_sandbox` owns grant publication, invocation, receipt validation, and audit persistence. Fixed diagnostics and approved command execution use it; the repository guard permits raw process authority only in closed trusted-host and executor adapters. | In progress while remaining typed agent routes are wired |
| MoonDesk control surface | Source diagnostics use an authenticated private-control-plane route and require an enforced, cleanup-verified receipt. The Phase-4 UI renders bounded backend/profile/limit/diff evidence, allows explicit per-file review, and calls the authenticated MoonClaw promotion broker without host paths. MoonFlow/updater operations refuse rather than execute on the host. | Complete for implemented sandbox operations |
| Local macOS proof | The strict real-host E2E passed the positive `sandbox-exec` branch: canonical mutation was denied, scratch diff/retention and output limiting succeeded, digests matched, cleanup was verified, and replay was refused. The command output and strict CI contract are recorded in `LOCAL_BACKEND_EVIDENCE.md`. | Complete for the supported local backend |
| Local Linux proof | The strict Ubuntu 22.04 CI job passed the positive bubblewrap branch on revision `83eae7f`: private mount/network namespaces, scratch-only mutation, bounded output, structured diff/retention, cleanup, and replay refusal. Receipts disclose `nested-user-namespaces` as unverified on baseline bubblewrap. Ubuntu 24.04 AppArmor incompatibility refuses closed. | Complete for the supported local backend |
| Strong microVM proof | A real AEN deployment must provision the exact current MoonBook, independently attest immutable image/workspace/tool/profile identity and limits, execute a hostile fixture, return a bounded diff, and verify VM cleanup. Fake transport metadata is insufficient. | External proof required after implementation |

## Mandatory release exercises

1. Run the local E2E on supported macOS and Linux hosts and observe the
   positive execution branch, not only fail-closed refusal.
2. Against a real AEN deployment, attempt canonical mutation, network egress,
   output flooding, process explosion, disk flooding, timeout with descendants,
   secret/environment reads, and symlink traversal. Every result must have a
   digest-bound receipt and verified cleanup.
3. Substitute each approval field independently (command, argument, working
   directory, backend, backend config, tool binding, workspace, network, and
   each limit) and prove refusal before filesystem or network activity.
4. Review and promote a selected changed file through the public promotion
   controller; prove unselected files and a concurrently replaced destination
   remain unchanged.
5. Run both static execution-boundary guards after adding a synthetic new
   package with a raw process import and confirm the guards fail.

The project is not production-complete until every non-complete row is closed
and the mandatory exercises have authoritative command output or deployment
receipts attached to the release evidence.
