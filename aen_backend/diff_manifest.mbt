///|
async fn[T : AenTransport] AenBackend::begin_diff_manifest(
  self : AenBackend[T],
  sandbox_id : String,
) -> String {
  let response = self.transport.request(
    envd_filesystem_request(
      self.api_key,
      sandbox_id,
      "CreateWatcher",
      encode_watcher_path(self.guest_scratch),
      response_bytes=65_536,
    ),
  )
  expect_status(response, 200)
  decode_single_string_field(response.body, 1)
}

///|
fn[T] AenBackend::canonical_changed_path(
  self : AenBackend[T],
  path : String,
) -> String raise AenBackendError {
  guard path != "" && !path.contains("\u{0}") else {
    raise ProtocolFailure("envd watcher returned an empty or NUL path")
  }
  guard !path.contains("\\") else {
    raise ProtocolFailure("envd watcher path contains a backslash")
  }
  if path.has_prefix("/") {
    guard path.has_prefix(self.guest_scratch + "/") else {
      raise ProtocolFailure("envd watcher path escaped guest scratch")
    }
    guard !path
      .split("/")
      .any(component => component == "." || component == "..") else {
      raise ProtocolFailure("envd watcher path contains traversal")
    }
    let relative = path[self.guest_scratch.length() + 1:].to_owned()
    guard relative != "" else {
      raise ProtocolFailure("envd watcher returned the scratch root")
    }
    relative
  } else {
    guard !path
      .split("/")
      .any(component => component == "" || component == "." || component == "..") else {
      raise ProtocolFailure("envd watcher relative path contains traversal")
    }
    path
  }
}

///|
async fn[T : AenTransport] AenBackend::finish_diff_manifest(
  self : AenBackend[T],
  sandbox_id : String,
  watcher_id : String,
) -> Array[String] {
  let events_response = self.transport.request(
    envd_filesystem_request(
      self.api_key,
      sandbox_id,
      "GetWatcherEvents",
      encode_watcher_id(watcher_id),
    ),
  )
  expect_status(events_response, 200)
  let changed = decode_watcher_events(events_response.body).map(path => {
    self.canonical_changed_path(path)
  })
  let remove_response = self.transport.request(
    envd_filesystem_request(
      self.api_key,
      sandbox_id,
      "RemoveWatcher",
      encode_watcher_id(watcher_id),
      response_bytes=65_536,
    ),
  )
  expect_status(remove_response, 200)
  changed.sort()
  changed.dedup()
  changed
}
