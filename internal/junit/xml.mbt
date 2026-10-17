///|
// A deliberately bounded XML 1.0 subset for local JUnit reports. No DTD,
// external entities, namespaces, schema fetching, or processing instructions.
priv struct XmlElement {
  name : String
  attrs : Map[String, String]
  children : Array[XmlElement]
  text : String
  line : Int
}

///|
priv struct XmlReader {
  chars : Array[Char]
  mut position : Int
  mut line : Int
  mut nodes : Int
}

///|
fn xml_space(ch : Char) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

///|
fn xml_character(code : Int) -> Bool {
  code == 9 ||
  code == 10 ||
  code == 13 ||
  (code >= 0x20 && code <= 0xd7ff) ||
  (code >= 0xe000 && code <= 0xfffd) ||
  (code >= 0x10000 && code <= 0x10ffff)
}

///|
fn XmlReader::starts(self : XmlReader, value : String) -> Bool {
  let wanted = value.iter().collect()
  if self.position + wanted.length() > self.chars.length() {
    return false
  }
  for index, ch in wanted {
    if self.chars[self.position + index] != ch {
      return false
    }
  }
  true
}

///|
fn XmlReader::take(self : XmlReader) -> Char raise {
  guard self.chars.get(self.position) is Some(ch) else {
    fail("unexpected end of XML at line \{self.line}")
  }
  self.position += 1
  if ch == '\n' {
    self.line += 1
  }
  ch
}

///|
fn XmlReader::expect(self : XmlReader, value : String) -> Unit raise {
  guard self.starts(value) else {
    fail("expected \{value} at XML line \{self.line}")
  }
  for _ in value {
    self.take() |> ignore
  }
}

///|
fn XmlReader::spaces(self : XmlReader) -> Bool {
  let before = self.position
  while self.chars.get(self.position) is Some(ch) && xml_space(ch) {
    if ch == '\n' {
      self.line += 1
    }
    self.position += 1
  }
  before != self.position
}

///|
fn XmlReader::name(self : XmlReader) -> String raise {
  let result = StringBuilder()
  let start = self.position
  while self.chars.get(self.position) is Some(ch) {
    let letter = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      ch == '_'
    if !letter &&
      !(self.position > start &&
      ((ch >= '0' && ch <= '9') || ch == '-' || ch == '.')) {
      break
    }
    result.write_char(self.take())
  }
  guard self.position > start else {
    fail("expected an unprefixed ASCII XML name at line \{self.line}")
  }
  result.to_string()
}

///|
fn XmlReader::entity(self : XmlReader) -> Char raise {
  self.expect("&")
  let value = StringBuilder()
  let start = self.position
  while !self.starts(";") {
    guard self.position - start < 12 else {
      fail("unsupported XML entity at line \{self.line}")
    }
    value.write_char(self.take())
  }
  self.expect(";")
  let entity = value.to_string()
  match entity {
    "amp" => '&'
    "lt" => '<'
    "gt" => '>'
    "quot" => '"'
    "apos" => '\''
    _ => {
      let (digits, base) = if entity.has_prefix("#x") {
        (entity[2:], 16)
      } else if entity.has_prefix("#") {
        (entity[1:], 10)
      } else {
        fail("unknown XML entity at line \{self.line}")
      }
      guard !digits.is_empty() else { fail("empty XML character reference") }
      let mut code = 0
      for ch in digits {
        let digit = if ch >= '0' && ch <= '9' {
          ch.to_int() - 48
        } else if base == 16 && ch >= 'a' && ch <= 'f' {
          ch.to_int() - 87
        } else if base == 16 && ch >= 'A' && ch <= 'F' {
          ch.to_int() - 55
        } else {
          fail("invalid XML character reference")
        }
        code = code * base + digit
        guard code <= 0x10ffff else {
          fail("XML character reference is out of range")
        }
      }
      guard xml_character(code) else { fail("invalid XML character reference") }
      code.unsafe_to_char()
    }
  }
}

///|
fn XmlReader::attributes(
  self : XmlReader,
  terminator : String,
) -> Map[String, String] raise {
  let attrs : Map[String, String] = Map([])
  while true {
    let separated = self.spaces()
    if self.starts(terminator) || self.starts("/>") {
      break
    }
    guard separated && attrs.length() < 64 else {
      fail("XML attributes need whitespace and at most 64 entries")
    }
    let name = self.name()
    if terminator == "?>" {
      guard (attrs.is_empty() && name == "version") ||
        (
          !attrs.is_empty() &&
          name == "encoding" &&
          !attrs.contains("standalone")
        ) ||
        (!attrs.is_empty() && name == "standalone") else {
        fail("invalid XML declaration attribute order")
      }
    }
    guard name != "xmlns" && !attrs.contains(name) else {
      fail("XML namespaces and duplicate attributes are unsupported")
    }
    self.spaces() |> ignore
    self.expect("=")
    self.spaces() |> ignore
    let quote = self.take()
    guard quote == '\'' || quote == '"' else {
      fail("XML attribute requires quotes")
    }
    let value = StringBuilder()
    let mut units = 0
    while self.chars.get(self.position) != Some(quote) {
      let ch = if self.starts("&") {
        self.entity()
      } else {
        let ch = self.take()
        guard ch != '<' else { fail("XML attribute contains raw <") }
        // XML 1.0 literal attribute whitespace normalizes to spaces. Numeric
        // references preserve their decoded character, including newlines.
        if xml_space(ch) {
          ' '
        } else {
          ch
        }
      }
      value.write_char(ch)
      units += if ch.to_int() > 65535 { 2 } else { 1 }
      guard units <= 16_384 else {
        fail("XML attribute exceeds 16384 UTF-16 units")
      }
    }
    self.take() |> ignore
    attrs[name] = value.to_string()
  }
  attrs
}

///|
fn XmlReader::comment(self : XmlReader) -> Unit raise {
  self.expect("<!--")
  while !self.starts("-->") {
    guard !self.starts("--") else { fail("invalid XML comment") }
    self.take() |> ignore
  }
  self.expect("-->")
}

///|
fn XmlReader::misc(self : XmlReader) -> Unit raise {
  while true {
    self.spaces() |> ignore
    if self.starts("<!--") {
      self.comment()
    } else {
      break
    }
  }
}

///|
fn XmlReader::element(self : XmlReader, depth : Int) -> XmlElement raise {
  guard depth <= 32 && self.nodes < 20_000 else {
    fail("XML exceeds 32 levels or 20000 elements")
  }
  self.nodes += 1
  let line = self.line
  self.expect("<")
  let name = self.name()
  let attrs = self.attributes(">")
  let children : Array[XmlElement] = []
  let text = StringBuilder()
  if self.starts("/>") {
    self.expect("/>")
  } else {
    self.expect(">")
    while true {
      if self.starts("</") {
        self.expect("</")
        guard self.name() == name else {
          fail("mismatched XML close tag at line \{self.line}")
        }
        self.spaces() |> ignore
        self.expect(">")
        break
      } else if self.starts("<!--") {
        self.comment()
      } else if self.starts("<![CDATA[") {
        self.expect("<![CDATA[")
        while !self.starts("]]>") {
          text.write_char(self.take())
        }
        self.expect("]]>")
      } else if self.starts("<") {
        children.push(self.element(depth + 1))
      } else if self.starts("&") {
        text.write_char(self.entity())
      } else {
        guard !self.starts("]]>") else { fail("raw ]]> outside XML CDATA") }
        text.write_char(self.take())
      }
    }
  }
  { name, attrs, children, text: text.to_string(), line, }
}

///|
fn parse_xml(text : String) -> XmlElement raise {
  guard @utf8.encode(text).length() <= 1_048_576 else {
    fail("JUnit XML exceeds 1 MiB")
  }
  guard !text.replace_all(old="\r\n", new="\n").contains("\r") else {
    fail("JUnit XML requires LF or CRLF lines for source drillback")
  }
  let normalized = text
    .strip_prefix("\u{feff}")
    .unwrap_or(text[:])
    .to_owned()
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\r", new="\n")
  guard normalized.iter().all(ch => xml_character(ch.to_int())) else {
    fail("invalid XML character")
  }
  let reader : XmlReader = {
    chars: normalized.iter().collect(),
    position: 0,
    line: 1,
    nodes: 0,
  }
  if reader.starts("<?xml") {
    reader.expect("<?xml")
    let attrs = reader.attributes("?>")
    guard attrs.get("version") == Some("1.0") &&
      attrs
      .iter()
      .all(pair => {
        pair.0 == "version" ||
        (pair.0 == "encoding" && (pair.1 == "UTF-8" || pair.1 == "utf-8")) ||
        (pair.0 == "standalone" && (pair.1 == "yes" || pair.1 == "no"))
      }) else {
      fail("XML declaration requires version 1.0 and optional UTF-8 encoding")
    }
    reader.expect("?>")
  }
  reader.misc()
  let root = reader.element(1)
  reader.misc()
  guard reader.position == reader.chars.length() else {
    fail("trailing XML content")
  }
  root
}
