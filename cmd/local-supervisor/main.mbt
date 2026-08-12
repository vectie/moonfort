///|
fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println(
      Json::object({
        "kind": Json::string("request_refused"),
        "message": Json::string("expected one JSON request argument"),
      }).stringify(),
    )
    return
  }
  try {
    let request : @local_supervisor.Request = @json.from_json(
      @json.parse(args[1]),
    )
    println(@json.to_json(@local_supervisor.run(request)).stringify())
  } catch {
    error =>
      println(
        Json::object({
          "kind": Json::string("request_refused"),
          "message": Json::string("\{error}"),
        }).stringify(),
      )
  } noraise {
    _ => ()
  }
}
