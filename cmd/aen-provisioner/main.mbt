///|
async fn main {
  guard @env.get_env_var("MOONFORT_AEN_PROVISIONER_CONFIG") is Some(path) else {
    @stdio.stderr.write("AEN provisioner configuration is unavailable\n")
    return
  }
  let config = @provisioner.load_config(path) catch {
    _ => {
      @stdio.stderr.write("AEN provisioner configuration was refused\n")
      return
    }
  }
  @provisioner.serve(config) catch {
    _ =>
      @stdio.stderr.write("AEN provisioner stopped after a service failure\n")
  }
}
