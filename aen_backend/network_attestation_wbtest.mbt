///|
fn deny_network_detail(
  allow_internet_access : Json,
  allow_public_traffic : Json,
  deny_out? : Array[String] = ["0.0.0.0/0"],
) -> Map[String, Json] {
  {
    "allowInternetAccess": allow_internet_access,
    "network": {
      "allowPublicTraffic": allow_public_traffic,
      "allowOut": [],
      "denyOut": deny_out,
    },
  }
}

///|
test "network readback requires both top-level deny and private traffic" {
  verify_network_attestation(test_profile(), deny_network_detail(false, false))
}

///|
test "network readback rejects missing top-level internet policy" {
  let detail = deny_network_detail(false, false)
  detail.remove("allowInternetAccess")
  try verify_network_attestation(test_profile(), detail) catch {
    ProtocolFailure(message) =>
      assert_true(message.contains("allowInternetAccess"))
    error => fail("unexpected network readback error: \{Repr(error)}")
  } noraise {
    _ => fail("missing top-level internet policy unexpectedly verified")
  }
}

///|
test "network readback rejects enabled top-level internet policy" {
  try
    verify_network_attestation(test_profile(), deny_network_detail(true, false))
  catch {
    ProtocolFailure(message) => assert_true(message.contains("top-level"))
    error => fail("unexpected network readback error: \{Repr(error)}")
  } noraise {
    _ => fail("enabled top-level internet policy unexpectedly verified")
  }
}

///|
test "network readback rejects public sandbox traffic" {
  try
    verify_network_attestation(test_profile(), deny_network_detail(false, true))
  catch {
    ProtocolFailure(message) => assert_true(message.contains("private"))
    error => fail("unexpected network readback error: \{Repr(error)}")
  } noraise {
    _ => fail("public sandbox traffic unexpectedly verified")
  }
}

///|
test "network readback rejects substituted deny CIDR" {
  try
    verify_network_attestation(
      test_profile(),
      deny_network_detail(false, false, deny_out=[]),
    )
  catch {
    ProtocolFailure(message) =>
      assert_true(message.contains("network attestation"))
    error => fail("unexpected network readback error: \{Repr(error)}")
  } noraise {
    _ => fail("missing IPv4 default deny unexpectedly verified")
  }
}

///|
struct NetworkEvidenceTransport {
  chunks : Array[Bytes]
  requests : Array[AenRequest]
}

///|
impl AenTransport for NetworkEvidenceTransport with fn request(_self, _request) {
  raise TransportFailure("network evidence fixture does not use request")
}

///|
impl AenTransport for NetworkEvidenceTransport with fn stream(
  self,
  request,
  consume~,
) {
  self.requests.push(request)
  for chunk in self.chunks {
    if consume(chunk) is StopStream {
      return
    }
  }
}

///|
fn network_evidence_backend(
  transport : NetworkEvidenceTransport,
) -> AenBackend[NetworkEvidenceTransport] raise {
  AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile=test_profile(),
  )
}

///|
async test "denied network requires independent guest IPv6-disable proof" {
  let transport : NetworkEvidenceTransport = {
    chunks: exec_stream(b"{\"ipv6Disabled\":true}", 0),
    requests: [],
  }
  let backend = network_evidence_backend(transport)
  backend.verify_guest_ipv6_disabled("sbx-ipv6")
  assert_eq(transport.requests.length(), 1)
}

///|
async test "denied network rejects a guest with IPv6 enabled" {
  let transport : NetworkEvidenceTransport = {
    chunks: exec_stream(b"{\"ipv6Disabled\":false}", 0),
    requests: [],
  }
  let backend = network_evidence_backend(transport)
  try backend.verify_guest_ipv6_disabled("sbx-ipv6") catch {
    ProtocolFailure(message) => assert_true(message.contains("IPv6"))
    error => fail("unexpected guest IPv6 error: \{Repr(error)}")
  } noraise {
    _ => fail("enabled guest IPv6 unexpectedly verified")
  }
}
