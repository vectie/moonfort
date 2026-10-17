///|
pub(all) struct RetentionComparisonEntry {
  path : String
  change : String
  before : @sandbox.ScratchEntry?
  after : @sandbox.ScratchEntry?
  byte_delta : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionComparison {
  baseline : RetentionArtifactBinding
  candidate : RetentionArtifactBinding
  added : Int
  removed : Int
  changed : Int
  unchanged : Int
  byte_delta : Int64
  matched : Int
  entries : Array[RetentionComparisonEntry]
  next_after : String
  has_more : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Compare saved manifests, not live scratch bytes. This neither approves nor
/// promotes any output. Use preview/export to verify bytes of selected files.
pub async fn compare_retained_artifacts(
  baseline : RetentionArtifactBinding,
  candidate : RetentionArtifactBinding,
  config : ExecutorConfig,
  prefix? : String = "",
  after? : String = "",
  include_unchanged? : Bool = false,
  limit? : Int = 50,
) -> RetentionComparison {
  guard limit > 0 &&
    limit <= 200 &&
    prefix.length() <= 4096 &&
    after.length() <= 4096 else {
    fail("invalid comparison filters")
  }
  let left = bound_artifact_record(baseline, config)
  let right = bound_artifact_record(candidate, config)
  let old : Map[String, @sandbox.ScratchEntry] = Map([])
  let new : Map[String, @sandbox.ScratchEntry] = Map([])
  let paths : Map[String, Bool] = Map([])
  for file in left.reviewable_files {
    old[file.relative_path] = file
    paths[file.relative_path] = true
  }
  for file in right.reviewable_files {
    new[file.relative_path] = file
    paths[file.relative_path] = true
  }
  let names = paths.keys().filter(path => path.has_prefix(prefix)).collect()
  names.sort_by((a, b) => a[:].lexical_compare(b[:]))
  let rows : Array[RetentionComparisonEntry] = []
  let mut added = 0
  let mut removed = 0
  let mut changed = 0
  let mut unchanged = 0
  let mut byte_delta = 0L
  for path in names {
    let before = old.get(path)
    let next = new.get(path)
    let delta = next.map(file => file.size_bytes).unwrap_or(0L) -
      before.map(file => file.size_bytes).unwrap_or(0L)
    byte_delta += delta
    let change = match (before, next) {
      (None, Some(_)) => {
        added += 1
        "added"
      }
      (Some(_), None) => {
        removed += 1
        "removed"
      }
      (Some(a), Some(b)) =>
        if a.fingerprint == b.fingerprint && a.size_bytes == b.size_bytes {
          unchanged += 1
          "unchanged"
        } else {
          changed += 1
          "changed"
        }
      _ => fail("missing comparison entry")
    }
    if include_unchanged || change != "unchanged" {
      rows.push({ path, change, before, after: next, byte_delta: delta, })
    }
  }
  let pending = rows.filter(row => row.path[:].lexical_compare(after[:]) > 0)
  let entries : Array[RetentionComparisonEntry] = []
  let response = fn() -> RetentionComparison {
    {
      baseline,
      candidate,
      added,
      removed,
      changed,
      unchanged,
      byte_delta,
      matched: rows.length(),
      entries: entries.copy(),
      next_after: entries.last().map(row => row.path).unwrap_or(after),
      has_more: entries.length() < pending.length(),
    }
  }
  for row in pending {
    if entries.length() == limit {
      break
    }
    entries.push(row)
    if @utf8.encode(response().to_json().stringify()).length() >
      config.limits.max_protocol_bytes {
      ignore(entries.pop())
      guard !entries.is_empty() else {
        fail("comparison row exceeds response budget")
      }
      break
    }
  }
  let result = response()
  guard @utf8.encode(result.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("comparison exceeds response budget")
  }
  guard bound_artifact_record(baseline, config) == left &&
    bound_artifact_record(candidate, config) == right else {
    fail("retention changed during comparison")
  }
  result
}

///|
pub extend RetentionComparisonEntry with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
pub extend RetentionComparisonEntry with Eq::{not_equal, equal}

///|
pub extend RetentionComparisonEntry with ToJson::{to_json}

///|
pub extend RetentionComparisonEntry with @moonbitlang/core/json.FromJson::{
  from_json,
}

///|
pub extend RetentionComparison with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionComparison with Eq::{not_equal, equal}

///|
pub extend RetentionComparison with ToJson::{to_json}

///|
pub extend RetentionComparison with @moonbitlang/core/json.FromJson::{from_json}
