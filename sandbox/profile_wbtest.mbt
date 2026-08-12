///|
test "local profile is read-only and default-deny" {
  let profile = local_profile(
    "run-1", "/suite/books/demo", "/suite/scratch/run-1",
  )
  assert_true(profile_is_valid(profile))
  assert_true(profile.read_only_workspace)
  assert_true(profile.network is Deny)
  assert_true(profile.allowed_egress.is_empty())
}

///|
test "profile rejects scratch paths inside the canonical workspace" {
  let profile = local_profile(
    "run-1", "/suite/books/demo", "/suite/books/demo/.tmp/run-1",
  )
  assert_false(profile_is_valid(profile))
  assert_eq(
    profile_rejection(profile),
    "scratch_root must be disjoint from workspace_root",
  )
}

///|
test "allow-list profiles may declare egress" {
  let profile = {
    ..local_profile("run-1", "/suite/books/demo", "/suite/scratch/run-1"),
    network: AllowList,
    allowed_egress: ["api.example.com"],
  }
  assert_true(profile_is_valid(profile))
}

///|
test "degraded local execution requires explicit opt-in" {
  let strict = local_profile(
    "run-1", "/suite/books/demo", "/suite/scratch/run-1",
  )
  assert_true(strict.enforcement_requirement is RequireEnforced)
  let opted_in = strict.allow_degraded()
  assert_true(opted_in.enforcement_requirement is AllowDegraded)
}

///|
test "profile digest is stable and covers policy changes" {
  let profile = local_profile(
    "run-1", "/suite/books/demo", "/suite/scratch/run-1",
  )
  let digest = profile_digest(profile)
  assert_eq(digest.length(), 64)
  assert_eq(profile_digest(profile), digest)
  assert_not_eq(profile_digest(profile.allow_degraded()), digest)
  let reordered = { ..profile, allowed_commands: ["git", "moon"] }
  assert_eq(profile_digest(reordered), digest)
}

///|
test "profile rejects traversal-shaped roots before backend resolution" {
  let profile = local_profile(
    "run-1", "/suite/books/../secret", "/suite/scratch/run-1",
  )
  assert_eq(
    profile_rejection(profile),
    "workspace_root must be a canonical absolute path",
  )
}

///|
test "profile rejects nonpositive process ceilings" {
  let profile = local_profile(
    "run-1", "/suite/books/demo", "/suite/scratch/run-1",
  )
  assert_eq(
    profile_rejection({ ..profile, limits: { ..profile.limits, processes: 0 } }),
    "processes must be positive",
  )
}

///|
test "contract names the non-bypassable ownership boundary" {
  let contract = contract_json().stringify()
  assert_true(contract.contains("moonfort-execution-sandbox.v2"))
  assert_true(contract.contains("explicit-diff-review"))
  assert_true(contract.contains("read-only"))
}

///|
test "unavailable enforcement produces a refused receipt" {
  let receipt = refused_receipt(
    "run-1",
    Unavailable,
    "profile-digest",
    "local enforcement unavailable",
  )
  assert_true(receipt.enforcement is Refused)
  assert_true(receipt.status is Failed)
  assert_true(receipt.denial_reason is Some("local enforcement unavailable"))
}
