///|
/// Findings from retained SARIF, expanded to one row per primary location.
pub(all) struct RetentionSarifTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  run_count : Int
  result_count : Int
  row_count : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn sarif_object(value : Json) -> Map[String, Json] raise {
  guard value is Object(fields) else { fail("SARIF expected an object") }
  fields
}

///|
fn sarif_child(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json] raise {
  match fields.get(key) {
    None => {}
    Some(value) => sarif_object(value)
  }
}

///|
fn sarif_array(fields : Map[String, Json], key : String) -> Array[Json] raise {
  match fields.get(key) {
    None => []
    Some(Array(values)) => values
    _ => fail("SARIF \{key} must be an array")
  }
}

///|
fn sarif_string(fields : Map[String, Json], key : String) -> String raise {
  match fields.get(key) {
    None => ""
    Some(String(text)) => text
    _ => fail("SARIF \{key} must be a string")
  }
}

///|
fn sarif_index(
  fields : Map[String, Json],
  key : String,
  length : Int,
) -> Int? raise {
  match fields.get(key) {
    None => None
    Some(Number(number, ..)) => {
      if number == -1.0 {
        return None
      }
      guard number >= 0.0 && number < length.to_double() else {
        fail("SARIF \{key} is outside its referenced array")
      }
      let index = number.to_int()
      guard index.to_double() == number else {
        fail("SARIF \{key} must be integral")
      }
      Some(index)
    }
    _ => fail("SARIF \{key} must be an index")
  }
}

///|
fn sarif_position(fields : Map[String, Json], key : String) -> String raise {
  match fields.get(key) {
    None => ""
    Some(Number(number, ..) as value) => {
      guard number >= 1.0 &&
        number <= 2147483647.0 &&
        number.to_int().to_double() == number else {
        fail("SARIF \{key} must be a positive 32-bit integer")
      }
      value.stringify()
    }
    _ => fail("SARIF \{key} must be a position")
  }
}

///|
// Driver rule indexes are run-local. Do not interpret extension/tool-component
// descriptors as driver indexes, or fabricate effective severity from defaults.
fn sarif_rule(
  result : Map[String, Json],
  rules : Array[Json],
) -> (String, String, String) raise {
  guard !result.contains("rule") else {
    fail(
      "SARIF result.rule references are unsupported; use driver ruleId/ruleIndex",
    )
  }
  let id = sarif_string(result, "ruleId")
  let index = sarif_index(result, "ruleIndex", rules.length())
  let mut descriptor : Map[String, Json] = Map([])
  if index is Some(i) {
    descriptor = sarif_object(rules[i])
    let indexed_id = sarif_string(descriptor, "id")
    guard !indexed_id.is_empty() && (id.is_empty() || id == indexed_id) else {
      fail("SARIF ruleId conflicts with indexed driver rule")
    }
  } else if !id.is_empty() {
    let matches = rules.filter(rule => {
      sarif_string(sarif_object(rule), "id") == id
    })
    guard matches.length() <= 1 else {
      fail("SARIF driver ruleId is ambiguous")
    }
    if matches.get(0) is Some(rule) {
      descriptor = sarif_object(rule)
    }
  }
  (
    if id.is_empty() {
      sarif_string(descriptor, "id")
    } else {
      id
    },
    sarif_string(descriptor, "name"),
    sarif_string(sarif_child(descriptor, "defaultConfiguration"), "level"),
  )
}

///|
// Keep URI/base ID verbatim. They are evidence, not file paths to open or URLs
// to fetch. Indexed metadata is resolved only within this same retained run.
fn sarif_location(
  location : Json,
  artifacts : Array[Json],
) -> Array[String] raise {
  let physical = sarif_child(sarif_object(location), "physicalLocation")
  let artifact = sarif_child(physical, "artifactLocation")
  let mut uri = sarif_string(artifact, "uri")
  let mut base = sarif_string(artifact, "uriBaseId")
  if sarif_index(artifact, "index", artifacts.length()) is Some(index) {
    let referenced = sarif_child(sarif_object(artifacts[index]), "location")
    let indexed_uri = sarif_string(referenced, "uri")
    let indexed_base = sarif_string(referenced, "uriBaseId")
    guard !indexed_uri.is_empty() else {
      fail("SARIF indexed artifact has no URI")
    }
    guard (uri.is_empty() || uri == indexed_uri) &&
      (base.is_empty() || base == indexed_base) else {
      fail("SARIF inline artifact location conflicts with indexed location")
    }
    uri = indexed_uri
    base = indexed_base
  }
  if physical.contains("artifactLocation") {
    guard !uri.is_empty() else { fail("SARIF artifact location has no URI") }
  }
  let region = sarif_child(physical, "region")
  [
    uri,
    base,
    sarif_position(region, "startLine"),
    sarif_position(region, "startColumn"),
    sarif_position(region, "endLine"),
    sarif_position(region, "endColumn"),
  ]
}

///|
fn retained_sarif_csv(document : Json) -> (String, Int, Int, Int) raise {
  let root = sarif_object(document)
  guard sarif_string(root, "version") == "2.1.0" && root.contains("runs") else {
    fail("SARIF requires version 2.1.0 and inline runs")
  }
  let runs = sarif_array(root, "runs")
  let output = StringBuilder()
  let mut bytes = 0
  let mut result_count = 0
  let mut row_count = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    for cell in cells {
      guard cell.length() <= 16384 && !cell.contains("\u{0}") else {
        fail("SARIF CSV cell exceeds 16384 UTF-16 units or contains NUL")
      }
    }
    let row = enriched_csv_record(cells)
    bytes += @utf8.encode(row).length()
    guard bytes <= 1048576 else { fail("SARIF CSV candidate exceeds 1 MiB") }
    output.write_string(row)
  }
  write([
    "__result_pointer", "__location_pointer", "tool", "rule_id", "rule_name", "level_declared",
    "rule_default_level", "kind_declared", "baseline_state", "message_text", "message_markdown",
    "suppressions_json", "uri", "uri_base_id", "start_line", "start_column", "end_line",
    "end_column",
  ])
  for run_index, run in runs {
    let fields = sarif_object(run)
    guard !fields.contains("externalPropertyFileReferences") &&
      fields.contains("results") else {
      fail(
        "SARIF requires inline results for each run; external properties are unsupported",
      )
    }
    let driver = sarif_child(sarif_child(fields, "tool"), "driver")
    let tool = sarif_string(driver, "name")
    guard !tool.is_empty() else { fail("SARIF run requires tool.driver.name") }
    let rules = sarif_array(driver, "rules")
    let artifacts = sarif_array(fields, "artifacts")
    for result_index, result in sarif_array(fields, "results") {
      result_count += 1
      guard result_count <= 10000 else { fail("SARIF exceeds 10000 results") }
      let pointer = "/runs/\{run_index}/results/\{result_index}"
      let result = sarif_object(result)
      let (rule_id, rule_name, default_level) = sarif_rule(result, rules)
      let message = sarif_child(result, "message")
      guard message.contains("text") || message.contains("markdown") else {
        fail(
          "SARIF \{pointer} requires inline message.text or message.markdown",
        )
      }
      let suppressions = sarif_array(result, "suppressions")
      let cells = [
        tool,
        rule_id,
        rule_name,
        sarif_string(result, "level"),
        default_level,
        sarif_string(result, "kind"),
        sarif_string(result, "baselineState"),
        sarif_string(message, "text"),
        sarif_string(message, "markdown"),
        Json::array(suppressions).stringify(),
      ]
      let locations = sarif_array(result, "locations")
      if locations.is_empty() {
        row_count += 1
        guard row_count <= 10000 else {
          fail("SARIF exceeds 10000 location rows")
        }
        write([pointer, ""] + cells + ["", "", "", "", "", ""])
      } else {
        for location_index, location in locations {
          row_count += 1
          guard row_count <= 10000 else {
            fail("SARIF exceeds 10000 location rows")
          }
          write(
            [pointer, pointer + "/locations/\{location_index}"] +
            cells +
            sarif_location(location, artifacts),
          )
        }
      }
    }
  }
  (output.to_string(), runs.length(), result_count, row_count)
}

///|
/// Project inline SARIF 2.1.0 diagnostics without evaluating severity defaults,
/// fetching URIs, running analysis, editing originals or promoting any output.
pub async fn tabulate_retained_sarif(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
) -> RetentionSarifTable {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1048576L else {
    fail("SARIF requires a retained file of at most 1 MiB")
  }
  let document = parse_retained_json(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let (csv, run_count, result_count, row_count) = retained_sarif_csv(document)
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during SARIF projection")
  }
  let bytes = @utf8.encode(csv)
  let table : RetentionSarifTable = {
    binding,
    file,
    run_count,
    result_count,
    row_count,
    csv,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
  }
  guard @utf8.encode(table.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("SARIF context exceeds protocol budget")
  }
  table
}

///|
/// Source/candidate binding plus interpretation limits, without the CSV bytes.
pub fn RetentionSarifTable::context(self : RetentionSarifTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-sarif-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "result_pointer_column": "__result_pointer",
    "location_pointer_column": "__location_pointer",
    "run_count": self.run_count.to_json(),
    "result_count": self.result_count.to_json(),
    "row_count": self.row_count.to_json(),
    "row_semantics": "one row per primary location; one blank-location row for locationless results",
    "severity_semantics": "declared result level and driver rule default only; effective severity is not computed",
    "uri_semantics": "run artifact indexes resolved; URI/base ID preserved, not fetched or made absolute",
    "omitted_metadata": [
      "fixes", "codeFlows", "relatedLocations", "properties", "invocations", "logicalLocations",
    ],
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}

///|
pub extend RetentionSarifTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionSarifTable with ToJson::{to_json}

///|
pub extend RetentionSarifTable with @moonbitlang/core/json.FromJson::{from_json}
