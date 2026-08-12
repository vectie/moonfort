///|
async test "native promotion rejects same-size source mutation" {
  let source = @fs.realpath(@fs.tmpdir(prefix="moonfort-secure-source-"))
  let destination = @fs.realpath(@fs.tmpdir(prefix="moonfort-secure-dest-"))
  @fs.write_file("\{source}/artifact", "one", create_mode=CreateNew)
  let inventory = inventory_scratch(source, 1024L).unwrap()
  let expected = inventory.entries[0]
  @fs.write_file("\{source}/artifact", "two", create_mode=CreateOrTruncate)
  let status = secure_promote_regular(
    source,
    "artifact",
    destination,
    "result",
    expected.size_bytes,
    expected.fingerprint,
    0,
    0L,
    "",
  )
  assert_eq(status, 2)
  assert_false(@fs.exists("\{destination}/result"))
  ignore(@fs.rmdir(source, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
}

///|
async test "native promotion never creates destination parents" {
  let source = @fs.realpath(@fs.tmpdir(prefix="moonfort-secure-parent-source-"))
  let destination = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-secure-parent-dest-"),
  )
  @fs.write_file("\{source}/artifact", "one", create_mode=CreateNew)
  let expected = inventory_scratch(source, 1024L).unwrap().entries[0]
  let status = secure_promote_regular(
    source,
    "artifact",
    destination,
    "missing/result",
    expected.size_bytes,
    expected.fingerprint,
    0,
    0L,
    "",
  )
  assert_eq(status, 3)
  assert_false(@fs.exists("\{destination}/missing"))
  assert_true(
    secure_destination_state(destination, "missing/result")
    is SecureDestinationError(3),
  )
  ignore(@fs.rmdir(source, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
}

///|
async test "read-only destination inspection refuses symlink traversal" {
  let destination = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-inspect-destination-"),
  )
  let outside = @fs.realpath(@fs.tmpdir(prefix="moonfort-inspect-outside-"))
  assert_eq(
    inspect_sandbox_destination(destination, "result"),
    DestinationAbsent,
  )
  @fs.write_file(
    "\{destination}/result",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_true(
    inspect_sandbox_destination(destination, "result")
    is DestinationRegular(size_bytes=8L, fingerprint=_),
  )
  @fs.remove("\{destination}/result")
  @fs.symlink("\{destination}/result", target="\{outside}/missing")
  assert_eq(
    inspect_sandbox_destination(destination, "result"),
    DestinationUnavailable,
  )
  @fs.remove("\{destination}/result")
  @fs.symlink("\{destination}/parent", target=outside)
  assert_eq(
    inspect_sandbox_destination(destination, "parent/result"),
    DestinationUnavailable,
  )
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(outside, recursive=true) catch { _ => () })
}

///|
test "native I/O status requires recovery" {
  let item : SandboxPromotionItem = {
    source_relative_path: "artifact",
    destination_relative_path: "result",
    expected_source_fingerprint: "digest",
    size_bytes: 1L,
    expected_destination_state: ReviewedDestinationAbsent,
  }
  let outcome = promotion_outcome_from_native_status(item, 4)
  assert_eq(
    outcome,
    RecoveryRequired(destination_path="result", native_status=4),
  )
}

///|
test "native pre-mutation statuses never claim durable apply" {
  let item : SandboxPromotionItem = {
    source_relative_path: "artifact",
    destination_relative_path: "result",
    expected_source_fingerprint: "digest",
    size_bytes: 1L,
    expected_destination_state: ReviewedDestinationAbsent,
  }
  for status in [1, 2, 3, 5] {
    assert_true(
      promotion_outcome_from_native_status(item, status) is NotApplied(_),
    )
  }
}

///|
test "unknown native promotion status requires recovery" {
  let item : SandboxPromotionItem = {
    source_relative_path: "artifact",
    destination_relative_path: "result",
    expected_source_fingerprint: "digest",
    size_bytes: 1L,
    expected_destination_state: ReviewedDestinationAbsent,
  }
  assert_eq(
    promotion_outcome_from_native_status(item, 99),
    RecoveryRequired(destination_path="result", native_status=99),
  )
}

///|
async test "apply refuses a forged multi-item plan before side effects" {
  let item : SandboxPromotionItem = {
    source_relative_path: "artifact",
    destination_relative_path: "result",
    expected_source_fingerprint: "digest",
    size_bytes: 1L,
    expected_destination_state: ReviewedDestinationAbsent,
  }
  let outcome = apply_sandbox_promotion("/not-inspected", {
    destination_root: "/not-inspected",
    items: [item, item],
  })
  assert_eq(outcome, NotApplied(MultiplePromotionItems(2)))
}
