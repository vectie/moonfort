///|
test "completed output protocol requires one exact signed receipt reference" {
  let request : Json = {
    "protocol_version": 1,
    "reference": {
      "artifact_id": "artifact-test",
      "run_id": "run-test",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "size_bytes": "12",
      "media_type": "text/plain; charset=utf-8",
      "expires_at_ms": ToJson::to_json(1000000000000L),
      "key_id": "fixture-key",
      "signature": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    "run_id": "run-test",
    "approval_digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "command_digest": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "offset": "4",
    "max_bytes": 8,
  }
  let decoded = @executor.decode_command_output_read_request(request)
  assert_eq(decoded.reference.artifact_id, "artifact-test")
  assert_eq(decoded.run_id, "run-test")
  assert_eq(decoded.offset, 4L)
  assert_eq(decoded.max_bytes, 8)
  assert_true(
    try {
      ignore(
        @executor.decode_command_output_read_request({ "path": "/tmp/output" }),
      )
      false
    } catch {
      _ => true
    },
  )
  guard request is Object(fields) else { fail("expected request object") }
  guard fields["reference"] is Object(reference) else {
    fail("expected reference object")
  }
  reference["host_path"] = "/tmp/output".to_json()
  fields["reference"] = Json::object(reference)
  assert_true(
    try {
      ignore(@executor.decode_command_output_read_request(Json::object(fields)))
      false
    } catch {
      _ => true
    },
  )
}
