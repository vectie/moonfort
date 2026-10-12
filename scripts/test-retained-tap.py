#!/usr/bin/env python3
"""Focused compiled-CLI test. All synthetic inputs and outputs are retained.

Usage: python3 test-retained-tap.py ABSOLUTE-CLI NEW-ABSOLUTE-EVIDENCE-DIRECTORY
"""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()


cli, root = map(Path, sys.argv[1:])
assert cli.is_absolute() and cli.is_file()
assert root.is_absolute() and not root.exists()
root.mkdir(mode=0o700)


def write(path, data):
    with path.open("xb") as f:
        f.write(data)
    path.chmod(0o600)


def fixture(name, data, fingerprint=None):
    case = root / name
    case.mkdir(mode=0o700)
    for item in ["approvals", "approvals/pending", "approvals/consumed", "scratch",
                 "scratch/tap-report", "retention", "retention/output-artifacts",
                 "retention/live-output"]:
        (case / item).mkdir(mode=0o700)
    write(case / "scratch/tap-report/results.tap", data)
    binding = dict(protocol_version=1, retention_id="tap-report", workspace_id="demo",
                   approval_digest="b" * 64, command_digest="c" * 64)
    record = dict(retention_id="tap-report", scratch_path=str(case / "scratch/tap-report"),
                  expires_at_ms=str(int(time.time() * 1000) + 86400000), workspace_id="demo",
                  profile_digest="a" * 64, approval_digest="b" * 64, command_digest="c" * 64,
                  reviewable_files=[dict(relative_path="results.tap", kind="RegularFile",
                                         size_bytes=str(len(data)), fingerprint=fingerprint or digest(data))])
    config = dict(approval_root=str(case / "approvals"), scratch_root=str(case / "scratch"),
                  retention_root=str(case / "retention"), artifact_key_id="synthetic-key",
                  artifact_signing_key="synthetic-example-only-01234567890123456789",
                  workspaces={}, local_tools={}, aen_backends={},
                  limits=dict(max_protocol_bytes=65536, max_wall_clock_ms=5000, max_cpu_seconds=2,
                              max_memory_mib=256, max_disk_mib=32, max_processes=32,
                              max_output_bytes=65536, max_model_output_bytes=32768,
                              max_command_args=16, max_argument_bytes=4096,
                              max_changed_paths=32, retention_ms="86400000"))
    for filename, content in [("config.json", config), ("binding.json", binding),
                              ("retention/tap-report.json", record)]:
        write(case / filename, json.dumps(content).encode())
    return case, binding


def run(case, label, args=None, binding=None, success=True):
    before = {str(p.relative_to(case)): digest(p.read_bytes())
              for directory in ["scratch", "retention", "approvals"]
              for p in (case / directory).rglob("*") if p.is_file()}
    result = subprocess.run([str(cli), *(args or ["tap-csv", "results.tap"])],
                            input=binding or (case / "binding.json").read_bytes(),
                            env={**os.environ, "MOONFORT_EXECUTOR_CONFIG": str(case / "config.json")},
                            capture_output=True, timeout=30)
    write(case / (label + ".csv"), result.stdout)
    write(case / (label + ".context.json"), result.stderr)
    write(case / (label + ".exit"), str(result.returncode).encode())
    after = {str(p.relative_to(case)): digest(p.read_bytes())
             for directory in ["scratch", "retention", "approvals"]
             for p in (case / directory).rglob("*") if p.is_file()}
    assert before == after, "retained evidence changed"
    assert list((case / "approvals/consumed").iterdir()) == []
    if success:
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        sidecar = json.loads(result.stderr)
        data = (case / "scratch/tap-report/results.tap").read_bytes()
        assert sidecar["source_file"]["fingerprint"] == digest(data)
        assert int(sidecar["source_file"]["size_bytes"]) == len(data)
        assert sidecar["candidate_fingerprint"] == digest(result.stdout)
        assert sidecar["candidate_size_bytes"] == len(result.stdout)
        assert sidecar["binding"] == json.loads((case / "binding.json").read_bytes())
        rows = list(csv.reader(io.StringIO(result.stdout.decode(), newline="")))
        assert rows[0] == ["test_number", "report_line", "status", "description", "directive", "reason", "diagnostics"]
        assert len(rows) - 1 == sidecar["row_count"]
        rebuilt = io.StringIO(newline="")
        csv.writer(rebuilt, quoting=csv.QUOTE_ALL, lineterminator="\r\n").writerows(rows)
        assert rebuilt.getvalue().encode() == result.stdout
        for row in rows[1:]:
            assert data.decode().splitlines()[int(row[1]) - 1].startswith(("ok", "not ok"))
        return rows[1:], sidecar, result
    assert result.returncode != 0 and result.stdout == b"", result
    assert b"Artifact browse refused" in result.stderr


source = ('TAP version 13\r\n# preamble\r\n1..5\r\n'
          'ok 1 - Unicode 月,"cart"\r\nnot ok 2 - total\r\n'
          '  ---\r\n  message: "wrong total"\r\n  got: 3\r\n  ...\r\n'
          '# expected four\r\nok 3 - optional # skip no database\r\n'
          'not ok 4 - rounding # ToDo implement\r\nok 5 - fixed # TODO verify\r\n').encode()
case, binding = fixture("mixed", source)
rows, context, result = run(case, "all")
assert rows == [
    ["1", "4", "passed", 'Unicode 月,"cart"', "", "", ""],
    ["2", "5", "failed", "total", "", "", '  ---\n  message: "wrong total"\n  got: 3\n  ...\n# expected four'],
    ["3", "11", "skipped", "optional", "SKIP", "no database", ""],
    ["4", "12", "todo", "rounding", "TODO", "implement", ""],
    ["5", "13", "unexpected-pass", "fixed", "TODO", "verify", ""],
]
assert context["plan_count"] == context["test_count"] == 5 and context["plan_satisfied"]
assert context["status_counts"] == {"passed": 1, "failed": 1, "skipped": 1, "todo": 1, "unexpected-pass": 1}
filtered, fcontext, first = run(case, "failures", ["tap-csv", "results.tap", "--failures"])
assert filtered == rows[1:2] and fcontext["failures_only"] and fcontext["test_count"] == 5
_, _, repeated = run(case, "repeated", ["tap-csv", "results.tap", "--failures"])
assert (first.stdout, first.stderr) == (repeated.stdout, repeated.stderr)
for label, args in [("duplicate-option", ["tap-csv", "results.tap", "--failures", "--failures"]),
                    ("missing-file", ["tap-csv", "missing.tap"]), ("missing-path", ["tap-csv"])]:
    run(case, label, args, success=False)
run(case, "wrong-binding", binding=json.dumps({**binding, "command_digest": "d" * 64}).encode(), success=False)
for name, data, expected in [
    ("skipped", b"TAP version 13\n1..0 # SKIP not installed\n", (0, 0, True, None)),
    ("bailed", b"1..9\nnot ok 1 - setup\nBail out! unavailable\n", (1, 9, False, "unavailable")),
    ("unplanned", b"ok - first\nnot ok\n", (2, None, False, None)),
    ("trailing-plan", b"ok - first\nnot ok\n1..2\n", (2, 2, True, None)),
]:
    sample, _ = fixture(name, data)
    _, sidecar, _ = run(sample, "all")
    assert (sidecar["test_count"], sidecar["plan_count"], sidecar["plan_satisfied"], sidecar["bailout"]) == expected
    if name == "bailed": assert sidecar["bailout_line"] == 3
    if name == "skipped": assert sidecar["skip_reason"] == "not installed"
for name, data in [
    ("late-invalid", b"ok 1 - first\nnot ok 2 - later\n1..3\n"),
    ("nested", b"# Subtest: child\n    ok 1\nok 1 - child\n1..1\n"),
    ("invalid-utf8", b"ok 1 - \xff\n1..1\n"),
    ("output-bound", ('ok 1 - ' + '"' * 530000 + '\n1..1\n').encode()),
    ("input-bound", b"#" * 1048577),
]:
    sample, _ = fixture(name, data)
    run(sample, "refused", success=False)
sample, _ = fixture("changed-source", b"ok 1\n1..1\n", fingerprint="0" * 64)
run(sample, "refused", success=False)
print("PASS: compiled TAP CLI exact rows/CSV bytes, statuses, failure selection, source drillback, skipped/unplanned/bailout/trailing-plan reports, repeatability, binding/digests, retained-evidence immutability, late/format/option/size refusals")
