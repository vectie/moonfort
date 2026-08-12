///|
/// Bind a receipt to the complete immutable profile using canonical struct
/// JSON and SHA-256. Derived struct JSON preserves declaration order.
pub fn profile_digest(profile : SandboxProfile) -> String {
  let read_only_roots = profile.read_only_roots.copy()
  let allowed_egress = profile.allowed_egress.copy()
  let allowed_commands = profile.allowed_commands.copy()
  read_only_roots.sort()
  allowed_egress.sort()
  allowed_commands.sort()
  let canonical = {
    ..profile,
    read_only_roots,
    allowed_egress,
    allowed_commands,
  }
  let bytes = @utf8.encode(canonical.to_json().stringify())
  @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
}
