# Cross-repository promotion evidence

On 2026-08-12, the compiled MoonFort promotion controller and rebuilt
MoonClaw daemon were exercised through the authenticated loopback HTTP route
using the exact MoonDesk request shape.

The executor-owned fixture contained two retained scratch files. The request
selected only `selected.txt` for `reviewed/selected.txt`. The endpoint returned
HTTP 200 with protocol-v3 evidence echoing the exact workspace, retention,
approval digest, command digest, and promoted path. The canonical selected file
contained `selected-v1`; no destination for `unselected.txt` existed; and the
retention record and scratch were consumed after verified promotion.

Replaying the same request and substituting the command digest both returned
HTTP 503 with the sanitized `promotion_refused` error. The success and refusal
responses contained no `/Users`, `/private`, workspace root, scratch root, or
other host path.

This exercise exposed and fixed a real integration defect: MoonClaw had encoded
promotion items with the internal plan field names `source_relative_path` and
`destination_relative_path`, while MoonFort's public request contract is
`artifact_path` and `destination_path`. MoonClaw commit `62f5a8c5` pins the
correct wire shape and has focused serializer/response-binding tests.
