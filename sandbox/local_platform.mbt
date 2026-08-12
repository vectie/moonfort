///|
priv enum LocalOsPlatform {
  MacOs
  Linux
  Unsupported
}

///|
extern "c" fn local_os_platform_code() -> Int = "moonfort_local_os_platform"

///|
fn local_os_platform() -> LocalOsPlatform {
  match local_os_platform_code() {
    1 => MacOs
    2 => Linux
    _ => Unsupported
  }
}

///|
fn local_os_platform_label(platform : LocalOsPlatform) -> String {
  match platform {
    MacOs => "macos"
    Linux => "linux"
    Unsupported => "unsupported"
  }
}
