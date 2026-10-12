#!/usr/bin/env python3
"""Retained ZIP -> testcase comparison -> JSON/CSV readback, with all evidence kept."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'tools/junit_review.py'
EVIDENCE = Path(os.environ.get('MOONFORT_JUNIT_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-junit-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
from junit_review import junit, compare_cases


def sha(data): return hashlib.sha256(data).hexdigest()


def fixture(path, xml, report='reports/tests.xml', mutate=None):
    data = xml.encode() if isinstance(xml, str) else xml
    files = [(report, data), ('notes.txt', b'retained context')]
    manifest = dict(format_version=1, purpose='Review copy only; not approval or promotion',
        binding=dict(protocol_version=1, retention_id=path.stem, workspace_id='workspace-demo', approval_digest='a'*64, command_digest='b'*64),
        expires_at_ms='1', files=[dict(relative_path=name, kind='RegularFile', size_bytes=str(len(content)), fingerprint=sha(content)) for name, content in files],
        total_bytes=str(sum(len(content) for _, content in files)))
    if mutate: mutate(manifest)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr('manifest.json', json.dumps(manifest))
        for name, content in files: archive.writestr('artifacts/' + name, content)
    return path

BEFORE = '''<testsuites><testsuite name="unit" tests="999">
<testcase classname="Cart" name="checkout" time="0.010"><failure message="bad &amp; input">old diagnostic</failure></testcase>
<testcase classname="Cart" name="remove"/>
<testcase classname="Cart" name="skip"><skipped message="no provider"/></testcase>
<testcase classname="Cart" name="duplicate"/><testcase classname="Cart" name="duplicate"><failure/></testcase>
<testcase classname="Cart" name="stable"/>
<testcase classname="Cart" name="detail" time="1.0"/>
</testsuite></testsuites>'''
AFTER = '''<testsuites><testsuite name="unit">
<testcase classname="Cart" name="stable"/>
<testcase classname="Cart" name="checkout" time="0.020"/>
<testcase classname="Cart" name="new"/>
<testcase classname="Cart" name="skip"><error type="Timeout">new diagnostic</error></testcase>
<testcase classname="Cart" name="duplicate"/>
<testcase classname="Cart" name="detail" time="1.00"/>
</testsuite></testsuites>'''


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName; self.root.mkdir()
        self.old = fixture(self.root / 'before.zip', BEFORE)
        self.new = fixture(self.root / 'after.zip', AFTER)
        self.counter = 0

    def invoke(self, *args, success=True, after=None):
        paths = [self.old, after or self.new]; hashes = [sha(p.read_bytes()) for p in paths]
        result = subprocess.run([sys.executable, str(CLI), *map(str, paths), '--report', 'reports/tests.xml', *args], capture_output=True, timeout=15)
        self.counter += 1
        (self.root / f'{self.counter}.stdout').write_bytes(result.stdout)
        (self.root / f'{self.counter}.stderr').write_bytes(result.stderr)
        self.assertEqual(hashes, [sha(p.read_bytes()) for p in paths])
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            context = json.loads(result.stderr)
            self.assertEqual(context['candidate_sha256'], sha(result.stdout))
            self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
            self.assertEqual(context['before']['bundle_sha256'], hashes[0])
            self.assertEqual(context['after']['bundle_sha256'], hashes[1])
        else:
            self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, b'')
        return result

    def test_outcomes_duplicates_and_exact_source_drillback(self):
        result = json.loads(self.invoke().stdout); rows = {r['name']: r for r in result['rows']}
        self.assertEqual(rows['checkout']['status'], 'changed-outcome')
        self.assertEqual(rows['checkout']['before'][0]['outcome'], 'failed')
        self.assertEqual(rows['checkout']['after'][0]['outcome'], 'passed')
        self.assertEqual(rows['skip']['before'][0]['outcome'], 'skipped')
        self.assertEqual(rows['skip']['after'][0]['outcome'], 'error')
        self.assertEqual(rows['remove']['status'], 'removed'); self.assertEqual(rows['new']['status'], 'added')
        self.assertEqual(rows['duplicate']['status'], 'ambiguous-identity')
        self.assertEqual(len(rows['duplicate']['before']), 2)
        self.assertEqual(rows['stable']['status'], 'unchanged'); self.assertEqual(rows['detail']['status'], 'changed-details')
        self.assertEqual(result['before']['testcase_count'], 7)
        for row in result['rows']:
            for label, source in [('before', BEFORE), ('after', AFTER)]:
                for case in row[label]: self.assertIn('name="' + case['name'] + '"', source.splitlines()[case['source_line']-1])
        self.assertEqual(rows['checkout']['before'][0]['diagnostics'][0]['message'], 'bad & input')
        self.assertEqual(result['before']['expires_at_ms'], '1')

    def test_csv_reopens_arrays_and_changes_only_retains_ambiguity(self):
        output = self.invoke('--format', 'csv', '--changes-only')
        rows = list(csv.DictReader(io.StringIO(output.stdout.decode())))
        self.assertNotIn('stable', [r['name'] for r in rows])
        duplicate = next(r for r in rows if r['name'] == 'duplicate')
        self.assertEqual(len(json.loads(duplicate['before_json'])), 2)
        self.assertEqual(json.loads(duplicate['suite_path_json']), ['unit'])
        self.assertEqual(json.loads(output.stderr)['status_counts']['unchanged'], 1)

    def test_report_rename_and_empty_suite(self):
        after = fixture(self.root / 'renamed.zip', '<testsuite name="empty"/>', report='new.xml')
        result = json.loads(self.invoke('--after-report', 'new.xml', after=after).stdout)
        self.assertEqual(result['after']['testcase_count'], 0)
        self.assertTrue(all(r['status'] in ('removed', 'ambiguous-identity') for r in result['rows']))

    def test_hierarchical_identity_does_not_collapse_display_delimiters(self):
        old = junit(b'<testsuite name="a / b"><testcase name="x"/></testsuite>')
        new = junit(b'<testsuite name="a"><testsuite name="b"><testcase name="x"/></testsuite></testsuite>')
        rows, _ = compare_cases(old, new)
        self.assertEqual({r['status'] for r in rows}, {'added', 'removed'})

    def test_notrun_status_and_diagnostic_precedence(self):
        rows = junit(b'<testsuite><testcase name="skip" status="notrun"/><testcase name="err"><failure/><error/></testcase></testsuite>')
        self.assertEqual([r['outcome'] for r in rows], ['skipped', 'error'])
        self.assertEqual([x['kind'] for x in rows[1]['diagnostics']], ['failure', 'error'])

    def test_unicode_multiline_diagnostic_and_original_duration(self):
        data = '<testsuite name="月"><testcase name="=SUM(A1)" time="01.230"><failure message="oops"><![CDATA[one\ntwo <three>]]></failure></testcase></testsuite>'
        after = fixture(self.root / 'unicode.zip', data)
        result = json.loads(self.invoke(after=after).stdout)
        row = next(r for r in result['rows'] if r['name'] == '=SUM(A1)')['after'][0]
        self.assertEqual(row['time'], '01.230'); self.assertEqual(row['diagnostics'][0]['text'], 'one\ntwo <three>')
        self.assertEqual(row['suite_path'], ['月'])

    def test_missing_and_tampered_artifacts_refuse_without_output(self):
        after = fixture(self.root / 'tampered.zip', AFTER, mutate=lambda m: m['files'][1].update(fingerprint='0'*64))
        self.invoke(after=after, success=False)
        self.invoke('--after-report', 'absent.xml', success=False)

    def test_unsupported_or_contradictory_reports_refuse(self):
        reports = ['<wrong/>', '<testsuite><testcase name="x"><failure/><skipped/></testcase></testsuite>',
                   '<testsuite><testcase name="x" status="mystery"/></testsuite>',
                   '<testsuite><testcase name="x" status="notrun" result="completed"/></testsuite>',
                   '<testsuite><testcase/></testsuite>', '<testsuite>',
                   '<!DOCTYPE testsuite [<!ENTITY e "fake">]><testsuite name="&e;"/>']
        for i, report in enumerate(reports):
            self.invoke(after=fixture(self.root / f'bad{i}.zip', report), success=False)

    def test_repeated_read_is_deterministic_and_source_reordering_is_not_change(self):
        self.assertEqual(self.invoke().stdout, self.invoke().stdout)
        old = junit(b'<testsuite><testcase name="a"/><testcase name="b"/></testsuite>')
        new = junit(b'<testsuite>\n<testcase name="b"/>\n<testcase name="a"/></testsuite>')
        rows, counts = compare_cases(old, new)
        self.assertEqual(counts, {'unchanged': 2})
        self.assertNotEqual(rows[0]['before'][0]['source_line'], rows[0]['after'][0]['source_line'])


if __name__ == '__main__': unittest.main()
