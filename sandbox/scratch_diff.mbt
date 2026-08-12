///|
pub(all) enum ScratchChangeKind {
  Added
  Modified
  Removed
} derive(Debug, Eq, ToJson, FromJson)

///|
/// `before` and `after` retain entry kinds, so symlink additions, changes, and
/// removals remain explicit rather than being mistaken for target files.
pub(all) struct ScratchDiffEntry {
  relative_path : String
  change : ScratchChangeKind
  before : ScratchEntry?
  after : ScratchEntry?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ScratchDiff {
  entries : Array[ScratchDiffEntry]
  before_bytes : Int64
  after_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
fn compare_relative_paths(left : String, right : String) -> Int {
  let shared = left.length().min(right.length())
  for index in 0..<shared {
    if left[index] < right[index] {
      return -1
    }
    if left[index] > right[index] {
      return 1
    }
  }
  left.length().compare(right.length())
}

///|
pub fn diff_scratch(
  before : ScratchInventory,
  after : ScratchInventory,
) -> ScratchDiff {
  let before_by_path : Map[String, ScratchEntry] = Map([])
  let after_by_path : Map[String, ScratchEntry] = Map([])
  for entry in before.entries {
    before_by_path[entry.relative_path] = entry
  }
  for entry in after.entries {
    after_by_path[entry.relative_path] = entry
  }
  let changes : Array[ScratchDiffEntry] = []
  for path, old_entry in before_by_path {
    match after_by_path.get(path) {
      None =>
        changes.push({
          relative_path: path,
          change: Removed,
          before: Some(old_entry),
          after: None,
        })
      Some(new_entry) if new_entry != old_entry =>
        changes.push({
          relative_path: path,
          change: Modified,
          before: Some(old_entry),
          after: Some(new_entry),
        })
      Some(_) => ()
    }
  }
  for path, new_entry in after_by_path {
    if !before_by_path.contains(path) {
      changes.push({
        relative_path: path,
        change: Added,
        before: None,
        after: Some(new_entry),
      })
    }
  }
  // MoonBit's general String::compare is length-first. Receipts use ordinary
  // code-unit lexical order so change lists are stable and unsurprising across
  // filesystems and backends.
  changes.sort_by((left, right) => {
    compare_relative_paths(left.relative_path, right.relative_path)
  })
  {
    entries: changes,
    before_bytes: before.total_bytes,
    after_bytes: after.total_bytes,
  }
}
