///|
test "TAP preserves status, diagnostics and physical report lines" {
  let text = "TAP version 13\n# setup\n1..5\nok 1 - Unicode 月,\"cart\"\nnot ok 2 - total\n  ---\n  message: 'wrong total'\n  got: 3\n  ...\n# expected four\nok 3 - optional # skip no database\nnot ok 4 - rounding # ToDo implement\nok 5 - fixed # TODO verify\n"
  let report = @tap.parse(text)
  assert_eq(report.plan, Some(5))
  assert_eq(report.points.map(p => p.status), [
    "passed", "failed", "skipped", "todo", "unexpected-pass",
  ])
  assert_eq(report.points.map(p => p.report_line), [4, 5, 11, 12, 13])
  assert_eq(report.points[0].description, "Unicode 月,\"cart\"")
  assert_eq(
    report.points[1].diagnostics.join("\n"),
    "  ---\n  message: 'wrong total'\n  got: 3\n  ...\n# expected four",
  )
  assert_eq(report.points[2].reason, "no database")
  assert_eq(report.points[3].directive, "TODO")
  assert_eq(@tap.parse(text.replace_all(old="\n", new="\r\n")), report)
}

///|
test "TAP handles inferred numbering, trailing plans, skipped runs and bailouts" {
  let report = @tap.parse("ok - first\nnot ok\nok 3 - third\n1..3\n")
  assert_eq(report.points.map(p => p.number), [1, 2, 3])
  assert_eq(report.plan, Some(3))
  assert_eq(@tap.parse("ok\n").plan, None)
  assert_eq(
    @tap.parse("ok\t1\t- tabs # sKiP\twhy\n1..1\n").points[0].reason,
    "why",
  )
  let skipped = @tap.parse("TAP version 13\n1..0 # Skipped: no fixtures\n")
  assert_eq(skipped.points.length(), 0)
  assert_eq(skipped.skip_reason, "no fixtures")
  let bailed = @tap.parse("1..9\nnot ok 1 - setup\nBail out! no fixtures\n")
  assert_eq(bailed.points.length(), 1)
  assert_eq(bailed.bailout, Some("no fixtures"))
  assert_eq(bailed.bailout_line, Some(3))
  assert_eq(@tap.parse("Bail out!\n").bailout, Some(""))
}

///|
test "TAP rejects ambiguous and incomplete flat reports" {
  for
    bad in [
      "", "# only a comment\n", "TAP version 14\n1..0\n", "\nTAP version 13\n1..0\n",
      "1..2\nok 1\n", "1..1\nok 2\n", "ok 1\nok 1\n", "ok 1\n1..1\nok 2\n", "1..0\n1..0\n",
      "ok 1x\n", "1..10001\n", "1..-1\n", "1..1 # SKIP no\nok\n", "ok # unknown detail\n",
      "not ok 1\n  ---\n  message: broken\n", "  ---\n  ...\n", "ok 1\n  ---\nnot ok 2\n",
      "# Subtest: nested\n    ok 1\nok 1\n", "    ok 1\n", "Bail out! stop\nok 1\n",
      "ok 1\nTAP version 13\n", "okay 1\n", "1..0\nok 1\nBail out! stop\n",
    ] {
    try @tap.parse(bad) catch {
      _ => ()
    } noraise {
      _ => fail("expected invalid TAP to raise: " + bad)
    }
  }
  try @tap.parse("#".repeat(1048577)) catch {
    _ => ()
  } noraise {
    _ => fail("expected oversized TAP to raise")
  }
}
