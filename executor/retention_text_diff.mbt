///|
pub(all) struct RetentionTextDiff {
  baseline : RetentionArtifactBinding
  candidate : RetentionArtifactBinding
  path : String
  before : @sandbox.ScratchEntry?
  after : @sandbox.ScratchEntry?
  added_lines : Int
  removed_lines : Int
  patch : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Read and verify one selected artifact on each side, then export a unified
/// text diff. An absent path is an empty side, provided it exists on the other.
/// No execution, grant consumption, promotion or retained-record mutation.
pub async fn diff_retained_artifact(
  baseline : RetentionArtifactBinding,
  candidate : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  context? : Int = 3,
) -> RetentionTextDiff {
  guard @sandbox.scratch_relative_path_is_safe(path) &&
    path.iter().all(c => c >= ' ' && !(c >= '\u{7f}' && c <= '\u{9f}')) &&
    context >= 0 &&
    context <= 20 else {
    fail("invalid text diff path or context")
  }
  let left = bound_artifact_record(baseline, config)
  let right = bound_artifact_record(candidate, config)
  let before = left.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
  let after = right.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
  guard before is Some(_) || after is Some(_) else {
    fail("artifact is absent from both retained manifests")
  }
  for entry in [before, after] {
    if entry is Some(file) {
      guard file.size_bytes <= 262_144L else {
        fail("text diff supports at most 256 KiB per file")
      }
    }
  }
  let old_text = if before is Some(_) {
    @utf8.decode(export_retained_artifact(baseline, path, config))
  } else {
    ""
  }
  let new_text = if after is Some(_) {
    @utf8.decode(export_retained_artifact(candidate, path, config))
  } else {
    ""
  }
  let diff = @text_diff.unified(
    old_text,
    new_text,
    if before is None {
      "/dev/null"
    } else {
      "a/" + path
    },
    if after is None {
      "/dev/null"
    } else {
      "b/" + path
    },
    context~,
  )
  guard bound_artifact_record(baseline, config) == left &&
    bound_artifact_record(candidate, config) == right else {
    fail("retention changed during text comparison")
  }
  {
    baseline,
    candidate,
    path,
    before,
    after,
    added_lines: diff.added_lines,
    removed_lines: diff.removed_lines,
    patch: diff.patch,
  }
}
