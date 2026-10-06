///|
test "typed export parser preserves signed Int64 and error boundaries" {
  for
    (text, expected) in [
      ("0", 0L),
      ("+1", 1L),
      ("-1", -1L),
      ("0x10", 16L),
      ("9223372036854775807", 9223372036854775807L),
      ("-9223372036854775808", -9223372036854775808L),
    ] {
    assert_eq(
      required_int64_string({ "size": text.to_json() }, "size"),
      expected,
    )
  }
  for
    text in [
      "9223372036854775808", "-9223372036854775809", "18446744073709551615", "1.0",
      " 1", "one",
    ] {
    try required_int64_string({ "size": text.to_json() }, "size") catch {
      ProtocolFailure(message) =>
        assert_eq(message, "guest export has an invalid size")
      _ => fail("Parser changed protocol error type")
    } noraise {
      _ => fail("Invalid Int64 was accepted")
    }
  }
  try required_int64_string({ "size": "" }, "size") catch {
    ProtocolFailure(message) =>
      assert_eq(message, "AgentENV response is missing size")
    _ => fail("Empty field changed error type")
  } noraise {
    _ => fail("Empty field was accepted")
  }
}
