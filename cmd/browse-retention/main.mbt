///|
extern "C" fn artifact_reader_exit(code : Int) = "exit"

///|
let usage : String =
  #|Usage: browse-retention COMMAND < receipt-binding.json
  #|  list [--prefix PATH] [--contains TEXT] [--after PATH] [--limit 1..200] [--json]
  #|  preview PATH [--offset BYTES] [--bytes 1..32768] [--json]
  #|  search-all --query TEXT [--prefix PATH] [--contains TEXT] [--ignore-case] [--after-path PATH --after-line N] [--limit 1..100] [--json]
  #|  search PATH --query TEXT [--ignore-case] [--after-line N] [--limit 1..100] [--json]
  #|  table PATH [--columns 1,3] [--where-column N --equals TEXT] [--after-row N] [--limit 1..100] [--json | --csv]
  #|  aggregate-csv PATH --value-column N [--group-by 2,3] > new-rollup.csv 2> new-context.json
  #|  summarize-csv PATH --group-by 2,3 [--where-column N --equals TEXT] > new-summary.csv 2> new-context.json
  #|  json PATH [--pointer POINTER] [--after-child N] [--limit 1..100] [--json | --value]
  #|  json-csv PATH --mapping LOCAL-FILE > new-candidate.csv 2> new-context.json
  #|  timeline --mapping LOCAL-FILE [--skip-blank-lines] > new-timeline.csv 2> new-context.json
  #|  lcov-csv PATH [--uncovered] > new-lines.csv 2> new-context.json
  #|  tap-csv PATH [--failures] > new-tests.csv 2> new-context.json
  #|  sarif-csv PATH > new-findings.csv 2> new-context.json
  #|  har-csv PATH [--method METHOD] [--status CODE] [--minimum-ms MS] > new-requests.csv 2> new-context.json
  #|  junit-csv PATH > new-tests.csv 2> new-context.json
  #|  jsonl-csv PATH --mapping LOCAL-FILE [--skip-blank-lines] > new-candidate.csv 2> new-context.json
  #|  edit-json PATH --recipe LOCAL-FILE > new-candidate.json 2> new-context.json
  #|  edit-csv PATH --recipe LOCAL-FILE > new-candidate.csv 2> new-context.json
  #|  edit-text PATH --recipe LOCAL-FILE > new-candidate.txt 2> new-context.json
  #|  stack-csv --manifest LOCAL-FILE > new-combined.csv 2> new-context.json
  #|  enrich-csv PATH --lookup LOCAL-FILE --source-key N --lookup-key N [--lookup-columns 2,3] [--prefix TEXT] > new-candidate.csv 2> new-context.json
  #|  export PATH > new-artifact-file
  #|  bundle [--prefix PATH] [--contains TEXT] > new-review.zip
  #|
  #|Uses the existing MOONFORT_EXECUTOR_CONFIG. Read-only; no execution or promotion.
  #|Export preserves exact bytes, up to 16 MiB and the configured disk limit.
  #|edit-json derives a candidate; the original artifact and receipt are unchanged.
  #|enrich-csv appends local lookup columns by exact key; it never promotes results.
  #|

///|
async fn local_data_file(path : String, limit : Int, label : String) -> Bytes {
  guard @fs.kind(path) is Regular else {
    fail(label + " requires a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.kind() == Regular else { fail(label + " requires a regular file") }
  guard file.size() <= limit.to_int64() else {
    fail(label + " exceeds byte limit")
  }
  let input = @buffer.Buffer()
  while file.read_some(max_len=(limit - input.length() + 1).min(8192))
        is Some(bytes) {
    guard input.length() + bytes.length() <= limit else {
      fail(label + " exceeds byte limit")
    }
    input.write_bytes(bytes)
  }
  input.to_bytes()
}

///|
async fn binding_stdin(limit : Int) -> @executor.RetentionArtifactBinding {
  guard limit >= 4096 && limit <= 1_048_576 else {
    fail("invalid protocol byte limit")
  }
  let input = @buffer.Buffer()
  while @stdio.stdin.read_some(max_len=(limit - input.length() + 1).min(8192))
        is Some(bytes) {
    guard input.length() + bytes.length() <= limit else {
      fail("input exceeds byte limit")
    }
    input.write_bytes(bytes)
  }
  @executor.decode_retention_artifact_binding(
    @json.parse(@utf8.decode(input.to_bytes())),
  )
}

///|
fn preview_text(text : String) -> String {
  let result = StringBuilder::new()
  for character in text {
    if (character < ' ' && character != '\n' && character != '\t') ||
      character == '\u{7f}' ||
      (character >= '\u{80}' && character <= '\u{9f}') ||
      (character >= '\u{202a}' && character <= '\u{202e}') ||
      (character >= '\u{2066}' && character <= '\u{2069}') {
      result.write_string("[U+" + character.to_int().to_string(radix=16) + "]")
    } else {
      result.write_char(character)
    }
  }
  result.to_string()
}

///|
fn list_text(list : @executor.RetentionArtifactList) -> String {
  let output = StringBuilder::new()
  output.write_string("Retained artifacts: " + list.binding.retention_id + "\n")
  output.write_string(
    "Matched \{list.matched_files} files / \{list.matched_bytes} bytes; total \{list.total_files} files / \{list.total_bytes} bytes\n",
  )
  output.write_string(
    "Saved manifest; preview/export verify the selected file. Expires at \{list.expires_at_ms} ms.\n",
  )
  for file in list.files {
    let name = file.relative_path.to_json().stringify()
    let large = if file.size_bytes > list.max_export_bytes.to_int64() {
      " [over export limit]"
    } else {
      ""
    }
    output.write_string(
      "\{file.size_bytes} bytes  \{name}\{large}\n  SHA256 \{file.fingerprint}\n",
    )
  }
  if list.files.is_empty() {
    output.write_string("No files on this page.\n")
  }
  if list.has_more {
    let cursor = list.next_after.to_json().stringify()
    output.write_string(
      "More files. Next cursor (JSON string): \{cursor}\nPass its literal value to --after with the same filters.\n",
    )
  }
  output.to_string()
}

///|
async fn run(args : Array[String]) -> Unit {
  guard args.length() >= 2 &&
    [
      "list", "preview", "search", "search-all", "table", "json", "json-csv", "edit-json",
      "edit-csv", "timeline", "enrich-csv", "aggregate-csv", "summarize-csv", "jsonl-csv",
      "export", "bundle", "junit-csv", "sarif-csv", "lcov-csv", "tap-csv", "stack-csv",
      "har-csv", "edit-text",
    ].contains(args[1]) else {
    fail("invalid command")
  }
  let command = args[1]
  let filtered = command == "list" ||
    command == "bundle" ||
    command == "search-all" ||
    command == "timeline" ||
    command == "stack-csv"
  let path = if filtered {
    ""
  } else {
    guard args.length() >= 3 else { fail("artifact path required") }
    args[2]
  }
  let options : Map[String, String] = {}
  let mut json_output = false
  let mut csv_output = false
  let mut value_output = false
  let mut ignore_case = false
  let mut uncovered_only = false
  let mut failures_only = false
  let mut skip_blank_lines = false
  for index = (if filtered { 2 } else { 3 }); index < args.length(); {
    let key = args[index]
    if key == "--failures" && command == "tap-csv" && !failures_only {
      failures_only = true
      continue index + 1
    }
    if key == "--uncovered" && command == "lcov-csv" && !uncovered_only {
      uncovered_only = true
      continue index + 1
    }
    if key == "--skip-blank-lines" &&
      (command == "jsonl-csv" || command == "timeline") &&
      !skip_blank_lines {
      skip_blank_lines = true
      continue index + 1
    }
    if key == "--json" &&
      ["list", "preview", "search", "search-all", "table", "json"].contains(
        command,
      ) &&
      !json_output &&
      !csv_output &&
      !value_output {
      json_output = true
      continue index + 1
    }
    if key == "--csv" && command == "table" && !csv_output && !json_output {
      csv_output = true
      continue index + 1
    }
    if key == "--value" && command == "json" && !value_output && !json_output {
      value_output = true
      continue index + 1
    }
    if key == "--ignore-case" &&
      (command == "search" || command == "search-all") &&
      !ignore_case {
      ignore_case = true
      continue index + 1
    }
    let allowed = if command == "list" {
      ["--prefix", "--contains", "--after", "--limit"]
    } else if command == "bundle" {
      ["--prefix", "--contains"]
    } else if command == "preview" {
      ["--offset", "--bytes"]
    } else if command == "search-all" {
      [
        "--query", "--prefix", "--contains", "--after-path", "--after-line", "--limit",
      ]
    } else if command == "search" {
      ["--query", "--after-line", "--limit"]
    } else if command == "table" {
      ["--columns", "--where-column", "--equals", "--after-row", "--limit"]
    } else if command == "aggregate-csv" {
      ["--group-by", "--value-column"]
    } else if command == "summarize-csv" {
      ["--group-by", "--where-column", "--equals"]
    } else if command == "json" {
      ["--pointer", "--after-child", "--limit"]
    } else if command == "json-csv" ||
      command == "jsonl-csv" ||
      command == "timeline" {
      ["--mapping"]
    } else if command == "stack-csv" {
      ["--manifest"]
    } else if command == "har-csv" {
      ["--method", "--status", "--minimum-ms"]
    } else if command == "edit-json" ||
      command == "edit-csv" ||
      command == "edit-text" {
      ["--recipe"]
    } else if command == "enrich-csv" {
      [
        "--lookup", "--source-key", "--lookup-key", "--lookup-columns", "--prefix",
      ]
    } else {
      []
    }
    guard allowed.contains(key) &&
      index + 1 < args.length() &&
      !options.contains(key) else {
      fail("invalid option")
    }
    options[key] = args[index + 1]
    continue index + 2
  }
  guard @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") is Some(config_path) else {
    fail("configuration required")
  }
  let config = @executor.load_executor_config(config_path)
  let binding = binding_stdin(config.limits.max_protocol_bytes)
  match command {
    "har-csv" => {
      let status = match options.get("--status") {
        Some(value) => Some(@string.parse_int(value))
        None => None
      }
      let minimum_ms = match options.get("--minimum-ms") {
        Some(value) => {
          guard @json.parse(value) is Number(number, ..) else {
            fail("minimum milliseconds requires a JSON number")
          }
          number
        }
        None => 0.0
      }
      let result = @executor.tabulate_retained_har(
        binding,
        path,
        config,
        method=options.get("--method").unwrap_or(""),
        status?,
        minimum_ms~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "stack-csv" => {
      guard options.get("--manifest") is Some(manifest_path) else {
        fail("CSV consolidation requires --manifest LOCAL-FILE")
      }
      let result = @executor.stack_retained_csv(
        binding,
        config,
        local_data_file(manifest_path, 65_536, "CSV stack manifest"),
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "tap-csv" => {
      let result = @executor.tabulate_retained_tap(
        binding,
        path,
        config,
        failures_only~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "lcov-csv" => {
      let result = @executor.tabulate_retained_lcov(
        binding,
        path,
        config,
        uncovered_only~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "sarif-csv" => {
      let result = @executor.tabulate_retained_sarif(binding, path, config)
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "junit-csv" => {
      let result = @executor.tabulate_retained_junit(binding, path, config)
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "timeline" => {
      guard options.get("--mapping") is Some(mapping_path) else {
        fail("retained timeline requires --mapping LOCAL-FILE")
      }
      let result = @executor.merge_retained_timeline(
        binding,
        config,
        local_data_file(mapping_path, 65_536, "timeline mapping"),
        skip_blank_lines~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "aggregate-csv" => {
      guard options.get("--value-column") is Some(value) else {
        fail("CSV aggregation requires --value-column N")
      }
      let group_by : Array[Int] = []
      if options.get("--group-by") is Some(columns) {
        for part in columns.split(",") {
          group_by.push(@string.parse_int(part.to_owned()))
        }
      }
      let result = @executor.aggregate_retained_csv(
        binding,
        path,
        config,
        value_column=@string.parse_int(value),
        group_by~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "summarize-csv" => {
      guard options.get("--group-by") is Some(value) else {
        fail("CSV summary requires --group-by COLUMNS")
      }
      guard options.contains("--where-column") == options.contains("--equals") else {
        fail("CSV summary requires --where-column and --equals together")
      }
      let group_by : Array[Int] = []
      for part in value.split(",") {
        group_by.push(@string.parse_int(part.to_owned()))
      }
      let where_column = if options.get("--where-column") is Some(column) {
        let number = @string.parse_int(column)
        guard number >= 1 else {
          fail("CSV summary filter column must be positive")
        }
        number
      } else {
        0
      }
      let result = @executor.summarize_retained_csv(
        binding,
        path,
        config,
        group_by~,
        where_column~,
        equals=options.get("--equals").unwrap_or(""),
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "jsonl-csv" => {
      guard options.get("--mapping") is Some(mapping_path) else {
        fail("JSONL table export requires --mapping LOCAL-FILE")
      }
      let result = @executor.tabulate_retained_jsonl(
        binding,
        path,
        config,
        local_data_file(mapping_path, 65_536, "JSONL table mapping"),
        skip_blank_lines~,
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "json-csv" => {
      guard options.get("--mapping") is Some(mapping_path) else {
        fail("JSON table export requires --mapping LOCAL-FILE")
      }
      let result = @executor.tabulate_retained_json(
        binding,
        path,
        config,
        local_data_file(mapping_path, 65_536, "JSON table mapping"),
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "enrich-csv" => {
      guard options.get("--lookup") is Some(lookup_path) &&
        options.get("--source-key") is Some(source_key) &&
        options.get("--lookup-key") is Some(lookup_key) else {
        fail("CSV enrichment requires --lookup, --source-key and --lookup-key")
      }
      let lookup_columns : Array[Int] = []
      if options.get("--lookup-columns") is Some(value) {
        for part in value.split(",") {
          lookup_columns.push(@string.parse_int(part.to_owned()))
        }
      }
      let result = @executor.enrich_retained_csv(
        binding,
        path,
        config,
        local_data_file(lookup_path, 1_048_576, "CSV lookup"),
        source_key=@string.parse_int(source_key),
        lookup_key=@string.parse_int(lookup_key),
        lookup_columns~,
        prefix=options.get("--prefix").unwrap_or("lookup_"),
      )
      @stdio.stderr.write(result.context().stringify() + "\n")
      @stdio.stdout.write(result.csv)
    }
    "edit-text" => {
      guard options.get("--recipe") is Some(recipe_path) else {
        fail("text editing requires --recipe LOCAL-FILE")
      }
      let draft = @executor.draft_retained_text(
        binding,
        path,
        config,
        local_data_file(recipe_path, 65_536, "text edit recipe"),
      )
      @stdio.stderr.write(draft.context().stringify() + "\n")
      @stdio.stdout.write(draft.text)
    }
    "edit-csv" => {
      guard options.get("--recipe") is Some(recipe_path) else {
        fail("CSV editing requires --recipe LOCAL-FILE")
      }
      let draft = @executor.draft_retained_csv(
        binding,
        path,
        config,
        local_data_file(recipe_path, 65_536, "CSV edit recipe"),
      )
      @stdio.stderr.write(draft.context().stringify() + "\n")
      @stdio.stdout.write(draft.csv)
    }
    "edit-json" => {
      guard options.get("--recipe") is Some(recipe_path) else {
        fail("JSON editing requires --recipe LOCAL-FILE")
      }
      let draft = @executor.draft_retained_json(
        binding,
        path,
        config,
        local_data_file(recipe_path, 65_536, "JSON edit recipe"),
      )
      @stdio.stderr.write(draft.context().stringify() + "\n")
      @stdio.stdout.write(draft.value.stringify() + "\n")
    }
    "json" => {
      let pointer = options.get("--pointer").unwrap_or("")
      if value_output {
        guard !options.contains("--after-child") && !options.contains("--limit") else {
          fail("JSON value export cannot be combined with pagination")
        }
        let selection = @executor.extract_retained_json(
          binding,
          path,
          config,
          pointer~,
        )
        // Stdout is a reusable typed JSON value. Keep source context in a
        // separate JSON line so a caller can retain both files without editing.
        let context : Json = {
          "binding": selection.binding.to_json(),
          "file": selection.file.to_json(),
          "pointer": selection.pointer.to_json(),
          "derived_selection": true,
        }
        @stdio.stderr.write(context.stringify() + "\n")
        @stdio.stdout.write(selection.value.stringify() + "\n")
      } else {
        let page = @executor.browse_retained_json(
          binding,
          path,
          config,
          pointer~,
          after_child=@string.parse_int(
            options.get("--after-child").unwrap_or("0"),
          ),
          limit=@string.parse_int(options.get("--limit").unwrap_or("20")),
        )
        if json_output {
          @stdio.stdout.write(page.to_json().stringify() + "\n")
        } else {
          let output = StringBuilder()
          output.write_string(
            "Retained JSON: " +
            preview_text(path.to_json().stringify()) +
            "\nSHA256: " +
            page.file.fingerprint +
            "\n",
          )
          output.write_string(
            "Pointer " +
            preview_text(pointer.to_json().stringify()) +
            ": " +
            page.selected.kind +
            "; " +
            page.selected.child_count.to_string() +
            " children\n",
          )
          output.write_string(
            preview_text(page.selected.preview) +
            (if page.selected.preview_truncated {
              " [preview truncated]"
            } else {
              ""
            }) +
            "\n",
          )
          for child in page.children {
            output.write_string(
              preview_text(child.pointer.to_json().stringify()) +
              "  " +
              child.kind +
              "  " +
              preview_text(child.preview) +
              (if child.preview_truncated {
                " [preview truncated]"
              } else {
                ""
              }) +
              "\n",
            )
          }
          output.write_string(
            if page.has_more {
              "[More: --after-child \{page.next_after_child}; keep the same pointer]\n"
            } else {
              "[End of children]\n"
            },
          )
          @stdio.stdout.write(output.to_string())
        }
      }
    }
    "table" => {
      guard options.contains("--where-column") == options.contains("--equals") else {
        fail("CSV filter requires both --where-column and --equals")
      }
      let columns : Array[Int] = []
      if options.get("--columns") is Some(value) {
        for part in value.split(",") {
          columns.push(@string.parse_int(part.to_owned()))
        }
      }
      let where_column = @string.parse_int(
        options.get("--where-column").unwrap_or("0"),
      )
      guard !options.contains("--where-column") || where_column > 0 else {
        fail("CSV filter column must be one-based")
      }
      let result = @executor.read_retained_csv(
        binding,
        path,
        config,
        columns~,
        where_column~,
        equals=options.get("--equals").unwrap_or(""),
        after_row=@string.parse_int(options.get("--after-row").unwrap_or("0")),
        limit=@string.parse_int(options.get("--limit").unwrap_or("20")),
      )
      let footer = if result.has_more {
        "[More: --after-row \{result.next_after_row}; keep the same columns and filter]"
      } else {
        "[End of table selection]"
      }
      if json_output {
        @stdio.stdout.write(result.to_json().stringify() + "\n")
      } else if csv_output {
        @stdio.stdout.write(result.to_csv())
        @stdio.stderr.write(
          "CSV page: \{result.rows.length()} of \{result.matching_rows} matching data rows. " +
          footer +
          "\n",
        )
      } else {
        let output = StringBuilder()
        output.write_string(
          "CSV table: " +
          preview_text(path.to_json().stringify()) +
          "\nSHA256: " +
          result.file.fingerprint +
          "\n",
        )
        output.write_string(
          "\{result.matching_rows} matching data rows of \{result.total_rows}. Columns (one-based): " +
          result.columns.to_json().stringify() +
          "\nHeaders: " +
          preview_text(result.headers.to_json().stringify()) +
          "\n",
        )
        for row in result.rows {
          output.write_string(
            "\{row.row}: " +
            preview_text(row.cells.to_json().stringify()) +
            "\n",
          )
        }
        output.write_string(footer + "\n")
        @stdio.stdout.write(output.to_string())
      }
    }
    "search-all" => {
      guard options.get("--query") is Some(query) else {
        fail("search query required")
      }
      let result = @executor.search_retained_run(
        binding,
        query,
        config,
        prefix=options.get("--prefix").unwrap_or(""),
        contains=options.get("--contains").unwrap_or(""),
        after_path=options.get("--after-path").unwrap_or(""),
        after_line=@string.parse_int(options.get("--after-line").unwrap_or("0")),
        limit=@string.parse_int(options.get("--limit").unwrap_or("20")),
        ignore_ascii_case=ignore_case,
      )
      @stdio.stdout.write(
        if json_output {
          result.to_json().stringify() + "\n"
        } else {
          run_search_text(result)
        },
      )
    }
    "search" => {
      guard options.get("--query") is Some(query) else {
        fail("search query required")
      }
      let result = @executor.search_retained_artifact(
        binding,
        path,
        query,
        config,
        after_line=@string.parse_int(options.get("--after-line").unwrap_or("0")),
        limit=@string.parse_int(options.get("--limit").unwrap_or("20")),
        ignore_ascii_case=ignore_case,
      )
      if json_output {
        @stdio.stdout.write(result.to_json().stringify() + "\n")
      } else {
        let output = StringBuilder::new()
        output.write_string(
          "Search: " +
          preview_text(path.to_json().stringify()) +
          "\nSHA256: " +
          result.file.fingerprint +
          "\n",
        )
        output.write_string(
          "\{result.matching_lines} matching lines in \{result.total_lines} lines (literal, " +
          (if ignore_case {
            "ASCII case-insensitive"
          } else {
            "case-sensitive"
          }) +
          ").\n",
        )
        for hit in result.matches {
          let before = if hit.omitted_before { "…" } else { "" }
          let after = if hit.omitted_after { "…" } else { "" }
          output.write_string(
            "\{hit.line}: \{before}" + preview_text(hit.excerpt) + after + "\n",
          )
        }
        if result.has_more {
          output.write_string(
            "[More: --after-line \{result.next_after_line}; keep the same query and case mode]\n",
          )
        } else {
          output.write_string("[End of search]\n")
        }
        @stdio.stdout.write(output.to_string())
      }
    }
    "bundle" => {
      let paths : Array[String] = []
      for after = "" {
        let page = @executor.list_retained_artifacts(
          binding,
          config,
          prefix=options.get("--prefix").unwrap_or(""),
          contains=options.get("--contains").unwrap_or(""),
          after~,
          limit=50,
        )
        guard page.matched_files > 0 && page.matched_files <= 200 else {
          fail("bundle selection requires 1..200 files")
        }
        for file in page.files {
          paths.push(file.relative_path)
        }
        guard paths.length() <= 200 else { fail("bundle selection too large") }
        if !page.has_more {
          break
        }
        continue page.next_after
      }
      @stdio.stdout.write(
        @executor.export_retained_bundle(binding, paths, config),
      )
    }
    "list" => {
      let result = @executor.list_retained_artifacts(
        binding,
        config,
        prefix=options.get("--prefix").unwrap_or(""),
        contains=options.get("--contains").unwrap_or(""),
        after=options.get("--after").unwrap_or(""),
        limit=@string.parse_int(options.get("--limit").unwrap_or("50")),
      )
      @stdio.stdout.write(
        if json_output {
          result.to_json().stringify() + "\n"
        } else {
          list_text(result)
        },
      )
    }
    "preview" => {
      let result = @executor.read_retained_artifact(
        binding,
        path,
        config,
        offset=@string.parse_int64(options.get("--offset").unwrap_or("0")),
        max_bytes=@string.parse_int(options.get("--bytes").unwrap_or("4096")),
      )
      if json_output {
        @stdio.stdout.write(result.to_json().stringify() + "\n")
      } else {
        let name = result.file.relative_path.to_json().stringify()
        let bytes = @base64.decode(result.content_base64)
        let text = preview_text(@utf8.decode(bytes)) catch {
          _ => "[Binary or incomplete UTF-8 page; use --json or export.]"
        }
        let footer = if result.eof {
          "[End of artifact]"
        } else {
          "[More: --offset \{result.next_offset}]"
        }
        @stdio.stdout.write(
          "Preview: \{name}\nSHA256: \{result.file.fingerprint}\nBytes \{result.offset}..\{result.next_offset} of \{result.file.size_bytes}\n\n\{text}\n\{footer}\n",
        )
      }
    }
    "export" =>
      @stdio.stdout.write(
        @executor.export_retained_artifact(binding, path, config),
      )
    _ => fail("invalid command")
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "--help" {
    @stdio.stdout.write(usage)
    return
  }
  run(args) catch {
    _ => {
      ignore(
        @stdio.stderr.write(
          "Artifact browse refused. Check the command, receipt binding, retention lifetime, and file size.\n" +
          usage,
        ) catch {
          _ => ()
        },
      )
      artifact_reader_exit(1)
    }
  }
}

///|
fn run_search_text(result : @executor.RetentionRunSearch) -> String {
  let output = StringBuilder()
  output.write_string(
    "Run search: " + preview_text(result.binding.retention_id) + "\n",
  )
  output.write_string(
    "\{result.matching_lines} matching lines in \{result.matching_files} files; searched \{result.searched_files}/\{result.selected_files} selected files (\{result.searched_bytes} bytes).\n",
  )
  output.write_string(
    "Literal query " +
    preview_text(result.query.to_json().stringify()) +
    (if result.ignore_ascii_case {
      " (ASCII case-insensitive)\n"
    } else {
      " (case-sensitive)\n"
    }),
  )
  for omission in result.skipped_files {
    output.write_string(
      "Skipped " +
      preview_text(omission.file.relative_path.to_json().stringify()) +
      ": " +
      omission.reason +
      (if omission.bytes_verified {
        " (bytes verified; not text searched)\n"
      } else {
        " (bytes not read or verified)\n"
      }),
    )
  }
  for found in result.matches {
    output.write_string(
      preview_text(found.file.relative_path.to_json().stringify()) +
      ":" +
      found.hit.line.to_string() +
      ": " +
      (if found.hit.omitted_before { "…" } else { "" }) +
      preview_text(found.hit.excerpt) +
      (if found.hit.omitted_after { "…" } else { "" }) +
      "\nSHA256: " +
      found.file.fingerprint +
      "\n",
    )
  }
  if result.has_more {
    output.write_string(
      "More matches. Next path (JSON string): " +
      preview_text(result.next_after_path.to_json().stringify()) +
      "; line: " +
      result.next_after_line.to_string() +
      "\nPass the literal path to --after-path and the line to --after-line; keep the same query, case mode and filters.\n",
    )
  } else {
    output.write_string(
      "[End of searchable matches; inspect any skipped files separately]\n",
    )
  }
  output.to_string()
}
