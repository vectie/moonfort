///|
test "terminal preview keeps text readable while escaping control sequences" {
  assert_eq(
    preview_text("line\n\tvalue\r\u{1b}[31m\u{0}"),
    "line\n\tvalue[U+d][U+1b][31m[U+0]",
  )
  assert_eq(preview_text("Review 🌙"), "Review 🌙")
}
