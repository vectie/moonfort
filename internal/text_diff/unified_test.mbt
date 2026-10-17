///|
test "unified changes preserve line counts and contextual text" {
  let diff = @text_diff.unified(
    "one\ntwo\nthree\n", "one\nnew\nthree\n", "a/x", "b/x",
  )
  assert_eq(diff.added_lines, 1)
  assert_eq(diff.removed_lines, 1)
  assert_eq(
    diff.patch,
    "--- a/x\t\n+++ b/x\t\n@@ -1,3 +1,3 @@\n one\n-two\n+new\n three\n",
  )
  assert_eq(@text_diff.unified("same\n", "same\n", "a/x", "b/x").patch, "")
}

///|
test "unified creation deletion newline and Unicode" {
  assert_eq(
    @text_diff.unified("", "月🌙\n", "/dev/null", "b/x").patch,
    "--- /dev/null\t\n+++ b/x\t\n@@ -0,0 +1 @@\n+月🌙\n",
  )
  assert_eq(
    @text_diff.unified("last", "", "a/x", "/dev/null").patch,
    "--- a/x\t\n+++ /dev/null\t\n@@ -1 +0,0 @@\n-last\n\\ No newline at end of file\n",
  )
  assert_eq(
    @text_diff.unified("line\n", "line", "a/x", "b/x").patch,
    "--- a/x\t\n+++ b/x\t\n@@ -1 +1 @@\n-line\n+line\n\\ No newline at end of file\n",
  )
  assert_true(
    @text_diff.unified("a\r\n", "b\r\n", "a/x", "b/x").patch.contains(
      "-a\r\n+b\r\n",
    ),
  )
}

///|
test "unified separates distant hunks and joins touching contexts" {
  let before = "a\n1\n2\n3\n4\n5\nz\n"
  let after = "b\n1\n2\n3\n4\n5\ny\n"
  assert_eq(
    @text_diff.unified(before, after, "a/x", "b/x", context=1).patch,
    "--- a/x\t\n+++ b/x\t\n@@ -1,2 +1,2 @@\n-a\n+b\n 1\n@@ -6,2 +6,2 @@\n 5\n-z\n+y\n",
  )
  assert_eq(
    @text_diff.unified("a\n1\n2\nz\n", "b\n1\n2\ny\n", "a/x", "b/x", context=1).patch,
    "--- a/x\t\n+++ b/x\t\n@@ -1,4 +1,4 @@\n-a\n+b\n 1\n 2\n-z\n+y\n",
  )
  assert_eq(
    @text_diff.unified("a\nb\n", "a\nx\nb\n", "a/x", "b/x", context=0).patch,
    "--- a/x\t\n+++ b/x\t\n@@ -1,0 +2 @@\n+x\n",
  )
}

///|
test "unified explicit size line and text limits" {
  for
    (before, after, context) in [
      ("a".repeat(262_145), "", 3),
      ("", "line\n".repeat(2001), 3),
      ("\u{0}", "", 3),
      ("\u{1b}[31m", "", 3),
      ("", "", -1),
      ("", "", 21),
    ] {
    try @text_diff.unified(before, after, "a/x", "b/x", context~) catch {
      _ => ()
    } noraise {
      _ => fail("expected unsupported text diff input to raise")
    }
  }
  assert_eq(
    @text_diff.unified("a".repeat(262_144), "a".repeat(262_144), "a/x", "b/x").patch,
    "",
  )
  assert_eq(
    @text_diff.unified("a\n".repeat(2000), "a\n".repeat(2000), "a/x", "b/x").patch,
    "",
  )
}
