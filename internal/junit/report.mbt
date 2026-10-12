///|
/// Document-order testcase rows. Outcomes are observed from testcase children,
/// never copied from suite counters. Source lines refer to testcase start tags.
pub(all) struct Report {
  headers : Array[String]
  rows : Array[Array[String]]
  passed : Int
  failed : Int
  errors : Int
  skipped : Int
} derive(Debug, Eq)

///|
fn junit_metadata(element : XmlElement) -> Unit raise {
  if element.name == "properties" {
    guard element.text.iter().all(xml_space) else {
      fail("text outside JUnit property")
    }
    for property in element.children {
      guard property.name == "property" && property.children.is_empty() else {
        fail("unsupported JUnit property content")
      }
    }
  } else {
    guard element.children.is_empty() else {
      fail("nested JUnit system output is unsupported")
    }
  }
}

///|
fn junit_case(element : XmlElement, suite : String) -> Array[String] raise {
  guard element.attrs.get("name") is Some(name) && !name.is_empty() else {
    fail("JUnit testcase requires a nonempty name")
  }
  guard element.text.iter().all(xml_space) else {
    fail("unexpected text in JUnit testcase")
  }
  let status = element.attrs.get("status").unwrap_or("")
  let result = element.attrs.get("result").unwrap_or("")
  guard ["", "run", "notrun"].contains(status) &&
    ["", "completed", "suppressed", "skipped"].contains(result) else {
    fail(
      "unsupported JUnit testcase status/result at source line \{element.line}",
    )
  }
  let mut failures = 0
  let mut errors = 0
  let mut skipped = 0
  let messages : Array[String] = []
  let details : Array[String] = []
  for child in element.children {
    if ["failure", "error", "skipped"].contains(child.name) {
      guard child.children.is_empty() else {
        fail("nested JUnit outcome content is unsupported")
      }
      match child.name {
        "failure" => failures += 1
        "error" => errors += 1
        _ => skipped += 1
      }
      let message = child.attrs.get("message").unwrap_or("")
      messages.push(message)
      let kind = child.attrs.get("type").unwrap_or("")
      details.push(
        "[" +
        child.name +
        (if kind.is_empty() { "" } else { ": " + kind }) +
        "]\n" +
        child.text,
      )
    } else if ["properties", "system-out", "system-err"].contains(child.name) {
      junit_metadata(child)
    } else {
      fail("unsupported JUnit testcase element: " + child.name)
    }
  }
  guard !(status == "notrun" && result == "completed") else {
    fail("contradictory JUnit status/result")
  }
  let notrun = status == "notrun" ||
    result == "suppressed" ||
    result == "skipped"
  guard !(notrun && (failures > 0 || errors > 0)) &&
    !(skipped > 0 && (failures > 0 || errors > 0)) else {
    fail("contradictory JUnit skipped and failing outcomes")
  }
  let outcome = if errors > 0 {
    "error"
  } else if failures > 0 {
    "failed"
  } else if skipped > 0 || notrun {
    "skipped"
  } else {
    "passed"
  }
  let cells = [
    element.line.to_string(),
    suite,
    element.attrs.get("classname").unwrap_or(""),
    name,
    outcome,
    element.attrs.get("time").unwrap_or(""),
    element.attrs.get("file").unwrap_or(""),
    element.attrs.get("line").unwrap_or(""),
    messages.join("\n"),
    details.join("\n\n"),
    failures.to_string(),
    errors.to_string(),
    skipped.to_string(),
  ]
  guard cells.all(cell => cell.length() <= 16_384) else {
    fail("JUnit CSV cell exceeds 16384 UTF-16 units")
  }
  cells
}

///|
fn junit_suites(
  element : XmlElement,
  parents : Array[String],
  rows : Array[Array[String]],
) -> Unit raise {
  guard element.text.iter().all(xml_space) else {
    fail("unexpected text in JUnit suite")
  }
  let path = if element.name == "testsuite" {
    parents + [element.attrs.get("name").unwrap_or("")]
  } else {
    parents
  }
  for child in element.children {
    if child.name == "testsuite" {
      junit_suites(child, path, rows)
    } else if child.name == "testcase" && element.name == "testsuite" {
      guard rows.length() < 10_000 else {
        fail("JUnit exceeds 10000 testcases")
      }
      rows.push(junit_case(child, path.join(" / ")))
    } else if element.name == "testsuite" &&
      ["properties", "system-out", "system-err"].contains(child.name) {
      junit_metadata(child)
    } else {
      fail("unsupported JUnit suite element: " + child.name)
    }
  }
}

///|
/// Read bounded, unprefixed UTF-8 JUnit XML with testsuite/testsuites roots.
/// Metadata and system streams validate but are omitted; failure text remains.
/// Unsupported constructs refuse the entire report instead of partial output.
pub fn parse(text : String) -> Report raise {
  let root = parse_xml(text)
  guard root.name == "testsuites" || root.name == "testsuite" else {
    fail("JUnit requires testsuite or testsuites root")
  }
  let rows : Array[Array[String]] = []
  junit_suites(root, [], rows)
  {
    headers: [
      "__source_line", "suite", "classname", "name", "outcome", "time", "file", "line",
      "message", "details", "failure_count", "error_count", "skipped_count",
    ],
    rows,
    passed: rows.filter(row => row[4] == "passed").length(),
    failed: rows.filter(row => row[4] == "failed").length(),
    errors: rows.filter(row => row[4] == "error").length(),
    skipped: rows.filter(row => row[4] == "skipped").length(),
  }
}
