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
  )
  assert_eq(status, 2)
  assert_false(@fs.exists("\{destination}/result"))
  ignore(@fs.rmdir(source, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
}
