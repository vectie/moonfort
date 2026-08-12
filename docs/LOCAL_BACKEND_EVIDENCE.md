# Local backend enforcement evidence

The local executor E2E has two modes:

- ordinary development runs accept a structured fail-closed refusal when the
  host enforcement primitive is unavailable;
- release and CI runs set `MOONFORT_REQUIRE_LOCAL_E2E=1`, which turns any such
  refusal into a test failure. A green strict run therefore proves the positive
  execution branch rather than only proving fallback denial.

## macOS

On 2026-08-12, the strict native test was run on the project host outside any
outer application sandbox:

```text
MOONFORT_REQUIRE_LOCAL_E2E=1 moon test --target native executor/local_executor_e2e_wbtest.mbt -v
moonfort local E2E: sandbox-exec execution verified
Total tests: 3, passed: 3, failed: 0.
```

That invocation published and consumed a real protocol-v3 grant, denied a
write to the canonical workspace, retained only scratch mutations, produced
structured added/modified entries with digest-bound evidence, enforced a
256-byte output ceiling, verified cleanup, and rejected replay. Running the
same strict test inside an incompatible outer sandbox fails during the
behavioral probe instead of silently passing.

## Continuous proof

`.github/workflows/local-sandbox.yml` runs the same strict test on clean macOS
and Linux GitHub-hosted runners. Linux installs the fixed `/usr/bin/bwrap`
backend; absence of usable user/mount/network namespaces is a hard test failure.
The job never changes policy to make a failing kernel probe appear successful.

The Linux proof uses Ubuntu 22.04. GitHub's Ubuntu 24.04 runner currently
applies an AppArmor unprivileged-user-namespace restriction that lets bwrap
begin namespace setup but denies the route-netlink operation used to initialize
its isolated loopback device (`RTM_NEWADDR`). MoonFort recognizes that as
enforcement unavailable and refuses the run. Operators on 24.04 must provide a
narrow policy for the fixed system `/usr/bin/bwrap` path, or select the AEN
backend; disabling AppArmor globally is not part of the supported setup.

The local backends intentionally remain `Degraded`, not `Enforced`: they share
the host kernel and disclose every limit that cannot be authoritatively
verified in `unverified_limits`. Production-grade untrusted execution still
requires the AEN microVM backend and its separate deployment evidence.
