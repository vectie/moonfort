///|
async test "grant rehearsal corrects candidate then publishes exactly reviewed scope" {
  let (config, roots) = test_executor_config()
  let grant = test_grant("rehearsal-correct")
  let invalid = { ..grant, limits: { ..grant.limits, memory_mib: 9999, }, }
  let rejected = rehearse_grant(
    { protocol_version: 3, grant: invalid, },
    config,
  )
  assert_false(rejected.ready_for_review)
  assert_eq(rejected.review_digest, "")
  assert_true(rejected.candidate is None)
  assert_true(rejected.correction is Some(c) && c.field == "limits.memory_mib")
  let request = GrantPublicationRequest::{ protocol_version: 3, grant, }
  let checked = rehearse_grant(request, config)
  assert_true(checked.ready_for_review)
  assert_eq(checked.candidate, Some(grant))
  assert_eq(@fs.readdir(config.approval_root + "/pending"), [])
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.scratch_root), [])
  let result = publish_reviewed_grant(request, checked.review_digest, config)
  assert_true(result.published)
  assert_eq(result.approval_digest, grant_digest(grant))
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  let duplicate = publish_reviewed_grant(request, checked.review_digest, config)
  assert_false(duplicate.published)
  assert_true(duplicate.error is Some(e) && e.code == "grant-conflict")
  cleanup_test_roots(roots)
}

///|
async test "grant rehearsal rejects stale candidate expired grant changed binding and missing review" {
  let (config, roots) = test_executor_config()
  let grant = test_grant("rehearsal-stale")
  let request = GrantPublicationRequest::{ protocol_version: 3, grant, }
  let checked = rehearse_grant(request, config)
  for
    changed in [
      { ..grant, command: Exec(tool="true", args=["new"]), },
      { ..grant, limits: { ..grant.limits, memory_mib: 129, }, },
      { ..grant, expires_at_ms: 1L, },
      { ..grant, working_directory: "new", },
    ] {
    let result = publish_reviewed_grant(
      { protocol_version: 3, grant: changed, },
      checked.review_digest,
      config,
    )
    assert_false(result.published)
    assert_true(result.error is Some(e) && e.code == "review-stale")
  }
  let changed_config = { ..config, local_tools: { "true": "/bin/true" }, }
  assert_false(
    publish_reviewed_grant(request, checked.review_digest, changed_config).published,
  )
  let policy = config.workspaces["book"]
  let changed_scope = {
    ..config,
    workspaces: {
      "book": { ..policy, read_only_roots: [policy.root, "/new"], },
    },
  }
  assert_false(
    publish_reviewed_grant(request, checked.review_digest, changed_scope).published,
  )
  assert_false(publish_reviewed_grant(request, "", config).published)
  assert_eq(@fs.readdir(config.approval_root + "/pending"), [])
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  cleanup_test_roots(roots)
}
