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
| Default-deny network | Local profiles deny network and refuse any unsupported policy. AEN must read back AEN network state and obtain independent guest/provisioner attestation for the complete namespace policy. | In progress |
| CPU, memory, wall, output, disk, and process limits | The local native supervisor applies rlimits, a monotonic deadline, bounded merged output, process-group counting, and aggregate scratch monitoring. Receipts explicitly list limits the shared-kernel backend cannot verify. AEN must enforce and attest every requested limit. | In progress |
| Descendant cleanup | Local execution kills the process group and bounds post-kill drain; escaped sessions make cleanup unverified and the run refused. AEN terminal receipts require verified VM deletion or a handed-off snapshot followed by deletion. | Complete for implemented backends; deployment E2E required |
| No silent fallback | Backend probes are behavioral. Missing, degraded-without-opt-in, malformed, or unverifiable enforcement returns a refusal. MoonClaw and MoonDesk boundary guards reject new raw production process authority. | Complete |
| Lifecycle | `start`, `exec`, `stop`, `reset`, and `snapshot` are represented by the sandbox lifecycle; AEN also supports pause/resume/fork. Receipts bind terminal state and cleanup. | Complete at contract level; AEN deployment proof required |
| Bounded artifacts and diff | Scratch inventory never follows links, produces structured relative changes, and enforces byte/path limits. Retention is opaque and TTL-bound. | Complete |
| Explicit reviewed promotion | `cmd/promote-retention` requires the retention ID plus approval/command digests and explicit per-file mappings, then revalidates fingerprints and destination ancestry before atomic promotion. | Complete at controller level; MoonDesk review UI pending |
| MoonClaw enforcement point | `internal/execution_sandbox` owns grant publication, invocation, receipt validation, and audit persistence. Fixed diagnostics and approved command execution use it; the repository guard permits raw process authority only in closed trusted-host and executor adapters. | In progress while remaining typed agent routes are wired |
| MoonDesk control surface | Source diagnostics use an authenticated private-control-plane route and require an enforced, cleanup-verified receipt. MoonFlow/updater operations refuse rather than execute on the host. | In progress: display backend/profile/limits/diff and promotion controls |
| Local macOS proof | The strict real-host E2E passed the positive `sandbox-exec` branch: canonical mutation was denied, scratch diff/retention and output limiting succeeded, digests matched, cleanup was verified, and replay was refused. The command output and strict CI contract are recorded in `LOCAL_BACKEND_EVIDENCE.md`. | Complete for the supported local backend |
| Local Linux proof | The bubblewrap backend constructs private mount/network namespaces, exposes only scratch as persistent writable storage, and uses the native supervisor for limits and cleanup. The strict Linux CI job must pass on the release revision; namespace unavailability is a failure, not a skip. | CI proof pending |
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
