///|
test "JUnit suites preserve cases diagnostics entities CDATA and observed outcomes" {
  let xml =
    #|<?xml version="1.0" encoding="UTF-8"?>
    #|<!-- generator metadata -->
    #|<testsuites tests="999"><testsuite name="unit &amp; smoke" failures="999">
    #|<properties><property name="build" value="local"/></properties>
    #|<testcase classname="a.Class" name="ok" time="0.0100" file="tests/a.mbt" line="007"/>
    #|<testcase name="月&#x1F319;, &quot;check&quot;" time="1e-9"><failure type="Assertion" message="&lt;bad&gt;&#10;next"><![CDATA[expected <1> & got "2"
    #|second line]]>&#33;</failure><failure message="again">trace &amp; detail</failure></testcase>
    #|<testsuite name="inner"><testcase name="setup"><error message="down">connect</error><failure>secondary</failure></testcase>
    #|<testcase name="later"><skipped message="waiting"/></testcase><testcase name="disabled" status="notrun" result="suppressed"/>
    #|</testsuite><system-out>not a testcase: &lt;testcase/&gt;</system-out>
    #|</testsuite></testsuites>
  let report = @junit.parse(xml)
  assert_eq(
    (report.passed, report.failed, report.errors, report.skipped),
    (1, 1, 1, 2),
  )
  assert_eq(report.rows.length(), 5)
  assert_eq(report.rows[0], [
    "5", "unit & smoke", "a.Class", "ok", "passed", "0.0100", "tests/a.mbt", "007",
    "", "", "0", "0", "0",
  ])
  assert_eq(report.rows[1][0], "6")
  assert_eq(report.rows[1][3], "月🌙, \"check\"")
  assert_eq(report.rows[1][8], "<bad>\nnext\nagain")
  assert_eq(
    report.rows[1][9],
    "[failure: Assertion]\nexpected <1> & got \"2\"\nsecond line!\n\n[failure]\ntrace & detail",
  )
  assert_eq(report.rows[1][10], "2")
  assert_eq(report.rows[2][1], "unit & smoke / inner")
  assert_eq(report.rows[2][4], "error")
  assert_eq(report.rows[2][10:13].to_owned(), ["1", "1", "0"])
  assert_eq(report.rows[4][4], "skipped")
}

///|
test "JUnit single suite empty suite duplicate cases and XML normalization" {
  assert_eq(@junit.parse("<testsuites/>").rows.length(), 0)
  assert_eq(@junit.parse("<testsuite/>").rows.length(), 0)
  let source = "\u{feff}<?xml version = '1.0' standalone='yes'?>\r\n<testsuite name='one'><testcase name='same'/><!-- safe -->\r\n<testcase name='same' classname='a\t b\r\nc' file='x&#9;y' line='&#x37;'/></testsuite>"
  let rows = @junit.parse(source).rows
  assert_eq(rows.length(), 2)
  assert_eq(rows[0][0], "2")
  assert_eq(rows[1][0], "3")
  assert_eq(rows[1][2], "a  b c")
  assert_eq(rows[1][6], "x\ty")
  assert_eq(rows[1][7], "7")
  assert_eq(
    @junit.parse(
      "<testsuite><testcase name='=A1' status='run' result='skipped'/></testsuite>",
    ).rows[0][4],
    "skipped",
  )
}

///|
test "JUnit refuses malformed XML and unsupported ambiguous outcome inputs" {
  for
    bad in [
      "", "<root/>", "<testsuite>", "<testsuite></testsuites>", "<testsuite/><testsuite/>",
      "text<testsuite/>", "<testsuite/>text", " < ?xml?>", " <?xml version='1.0'?><testsuite/>",
      "<?xml encoding='UTF-8' version='1.0'?><testsuite/>", "<?xml version='1.1'?><testsuite/>",
      "<?xml version='1.0' encoding='UTF-16'?><testsuite/>", "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><testsuite/>",
      "<!DOCTYPE testsuite [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><testsuite/>",
      "<testsuite><?work x?></testsuite>", "<j:testsuite xmlns:j='urn:example'/>",
      "<testsuite xmlns='urn:example'/>", "<testsuite a='1' a='2'/>", "<testsuite a='1'b='2'/>",
      "<testsuite a=unquoted/>", "<testsuite><!-- bad--comment --></testsuite>",
      "<testsuite><!--unclosed</testsuite>", "<testsuite>]]></testsuite>", "<testsuite a='<bad>'/>",
      "<testsuite a='&unknown;'/>", "<testsuite a='&#0;'/>", "<testsuite a='&#xD800;'/>",
      "<testsuite a='&#x110000;'/>", "<testsuite a='&#;'/>", "<testsuite a='&#x;'/>",
      "<testsuite a='&#12a;'/>", "<testsuite a='&#xFFFFFFFFFFFF;'/>", "<testsuite>\u{1}</testsuite>",
      "<testsuite>\r<testcase name='x'/></testsuite>", "<testsuites><testcase name='x'/></testsuites>",
      "<testsuite><testcase/></testsuite>", "<testsuite><testcase name=''/></testsuite>",
      "<testsuite><testcase name='x'>ignored?</testcase></testsuite>", "<testsuite><testcase name='x'><flakyFailure/></testcase></testsuite>",
      "<testsuite><testcase name='x'><failure><b>not plain text</b></failure></testcase></testsuite>",
      "<testsuite><testcase name='x'><skipped/><failure/></testcase></testsuite>",
      "<testsuite><testcase name='x' status='notrun' result='completed'/></testsuite>",
      "<testsuite><testcase name='x' result='suppressed'><error/></testcase></testsuite>",
      "<testsuite><testcase name='x' status='unknown'/></testsuite>", "<testsuite><system-out><hidden/></system-out></testsuite>",
      "<testsuite><properties><unknown/></properties></testsuite>",
    ] {
    expect_junit_rejected(bad)
  }
}

///|
fn expect_junit_rejected(text : String) -> Unit raise {
  try @junit.parse(text) catch {
    _ => ()
  } noraise {
    _ => fail("accepted invalid XML: " + text)
  }
}

///|
test "JUnit input element nesting testcase attribute and cell bounds" {
  expect_junit_rejected(" ".repeat(1_048_577))
  expect_junit_rejected("<testsuite>".repeat(33) + "</testsuite>".repeat(33))
  expect_junit_rejected(
    "<testsuite><testcase name='x'><failure>" +
    "x".repeat(16_385) +
    "</failure></testcase></testsuite>",
  )
  expect_junit_rejected(
    "<testsuite><testcase name='" + "x".repeat(16_385) + "'/></testsuite>",
  )
  assert_eq(
    @junit.parse(
      "<testsuite>" + "<testcase name='x'/>".repeat(10_000) + "</testsuite>",
    ).rows.length(),
    10_000,
  )
  expect_junit_rejected(
    "<testsuite>" + "<testcase name='x'/>".repeat(10_001) + "</testsuite>",
  )
  expect_junit_rejected(
    "<testsuite><properties>" +
    "<property/>".repeat(20_000) +
    "</properties></testsuite>",
  )
  let attrs = Array::makei(65, index => " a" + index.to_string() + "='x'").join(
    "",
  )
  expect_junit_rejected("<testsuite" + attrs + "/>")
}
