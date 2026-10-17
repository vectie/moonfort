///|
test "typed provisioner parsers preserve signed widths and request errors" {
  for value in [0L, -1L, 9223372036854775807L, -9223372036854775808L] {
    assert_eq(
      request_from_json(@json.parse(request_body(max_bytes=value))).max_bytes,
      value,
    )
  }
  for text in ["9223372036854775808", "18446744073709551615", "1.5", "bad", ""] {
    guard @json.parse(request_body()) is Object(fields) else {
      fail("Expected request")
    }
    fields["maxBytes"] = ToJson::to_json(text)
    try request_from_json(ToJson::to_json(fields)) catch {
      InvalidRequest(message) => assert_eq(message, "maxBytes is invalid")
      _ => fail("Parser changed request error type")
    } noraise {
      _ => fail("Invalid maxBytes accepted")
    }
  }
  for
    (text, expected) in [
      ("+1", 1),
      ("-1", -1),
      ("0x10", 16),
      ("2147483647", 2147483647),
      ("-2147483648", -2147483648),
    ] {
    assert_eq(@string.parse_int(text), expected)
  }
  for text in ["2147483648", "-2147483649", "4294967295", "1.0", " 1", ""] {
    try @string.parse_int(text) catch {
      _ => ()
    } noraise {
      _ => fail("Invalid Int accepted")
    }
  }
  assert_true(valid_bind_address("127.0.0.1:1"))
  assert_true(valid_bind_address("127.0.0.1:65535"))
  assert_false(valid_bind_address("127.0.0.1:0"))
  assert_false(valid_bind_address("127.0.0.1:-1"))
  assert_false(valid_bind_address("127.0.0.1:65536"))
  assert_false(valid_bind_address("127.0.0.1:4294967295"))
}
