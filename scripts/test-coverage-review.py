#!/usr/bin/env python3
"""Real-file, dependency-free review-bundle coverage workflow; evidence is retained."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

CLI = Path(__file__).resolve().parents[1] / 'tools/coverage_review.py'
EVIDENCE = Path(os.environ.get('MOONFORT_COVERAGE_EVIDENCE', tempfile.mkdtemp(prefix='moonfort-coverage-')))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()


def fixture(path, lcov, retention='before', report='reports/coverage.info', mutate=None, extra=None):
    data = lcov.encode() if isinstance(lcov, str) else lcov
    files = [(report, data), ('reports/details.bin', b'\x00\xffretained')]
    manifest = dict(format_version=1, purpose='Review copy only; not approval or promotion',
        binding=dict(protocol_version=1, retention_id=retention, workspace_id='workspace-demo', approval_digest='a' * 64, command_digest='b' * 64),
        expires_at_ms='1', files=[dict(relative_path=name, kind='RegularFile', size_bytes=str(len(content)), fingerprint=sha(content)) for name, content in files],
        total_bytes=str(sum(len(content) for _, content in files)))
    if mutate: mutate(manifest)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False, separators=(',', ':')) + '\n')
        for name, content in files: archive.writestr('artifacts/' + name, content)
        if extra: archive.writestr(extra, b'extra')
    return path


BEFORE = ('TN:unit\nSF:src/total.mbt\nDA:1,2,a\nDA:2,0,b\nDA:3,1,c\nDA:4,0,d\nLF:4\nLH:2\nend_of_record\n'
          'TN:integration\nSF:src/total.mbt\nDA:2,4,b\nend_of_record\n'
          'SF:src/old.mbt\nDA:1,0\nend_of_record\n')
AFTER = ('TN:unit\nSF:src/total.mbt\nDA:1,0,a\nDA:2,0,b\nDA:3,2,c\nDA:4,3,d\nDA:5,0,e\nLF:5\nLH:2\nend_of_record\n'
         'TN:integration\nSF:src/total.mbt\nDA:2,0,b\nend_of_record\n'
         'SF:src/new月.mbt\nDA:1,1\nend_of_record\n')


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName; self.root.mkdir()
        self.before = fixture(self.root / 'before.zip', BEFORE)
        self.after = fixture(self.root / 'after.zip', AFTER, 'after')
        self.counter = 0

    def invoke(self, *options, success=True, before=None, after=None):
        paths = [before or self.before, after or self.after]
        hashes = [sha(p.read_bytes()) for p in paths]
        result = subprocess.run([sys.executable, str(CLI), *map(str, paths), '--report', 'reports/coverage.info', *options], capture_output=True, timeout=15)
        self.counter += 1
        (self.root / f'{self.counter}.stdout').write_bytes(result.stdout)
        (self.root / f'{self.counter}.stderr').write_bytes(result.stderr)
        self.assertEqual(hashes, [sha(p.read_bytes()) for p in paths])
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            context = json.loads(result.stderr)
            self.assertEqual(context['candidate_sha256'], sha(result.stdout))
            self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
            self.assertEqual(context['before']['bundle_sha256'], hashes[0])
            self.assertEqual(context['after']['bundle_sha256'], hashes[1])
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
            self.assertTrue(result.stderr)
        return result

    def test_complete_union_comparison_and_drillback(self):
        output = self.invoke(); result = json.loads(output.stdout)
        rows = {(r['source_path'], r['source_line']): r for r in result['rows']}
        self.assertEqual(len(rows), 7)
        expected = {1: 'covered-to-uncovered', 2: 'covered-to-uncovered', 3: 'still-covered', 4: 'uncovered-to-covered', 5: 'added-uncovered'}
        for line, status in expected.items(): self.assertEqual(rows[('src/total.mbt', line)]['status'], status)
        line_two = rows[('src/total.mbt', 2)]
        self.assertTrue(line_two['before']['covered'])
        self.assertEqual(line_two['before']['reported_hits_sum'], 4)
        self.assertEqual([o['test_name'] for o in line_two['before']['observations']], ['unit', 'integration'])
        self.assertEqual(line_two['comparison_basis'], 'same-reported-checksum')
        self.assertEqual(rows[('src/old.mbt', 1)]['status'], 'removed-uncovered')
        self.assertEqual(rows[('src/new月.mbt', 1)]['status'], 'added-covered')
        for row in result['rows']:
            for label, source in [('before', BEFORE), ('after', AFTER)]:
                if row[label]:
                    for obs in row[label]['observations']:
                        self.assertTrue(source.splitlines()[obs['report_line'] - 1].startswith('DA:'))
        self.assertEqual(result['before']['binding']['retention_id'], 'before')
        self.assertEqual(result['after']['binding']['retention_id'], 'after')
        self.assertEqual(result['before']['expires_at_ms'], '1')  # downloaded review copy remains readable
        self.assertEqual(self.invoke().stdout, output.stdout)

    def test_csv_reopens_with_full_provenance_and_changes_filter(self):
        output = self.invoke('--format', 'csv', '--changes-only')
        rows = list(csv.DictReader(io.StringIO(output.stdout.decode(), newline='')))
        context = json.loads(output.stderr)
        self.assertEqual(len(rows), 6)
        self.assertEqual(context['status_counts']['still-covered'], 1)
        self.assertTrue(context['changes_only'])
        self.assertNotIn('still-covered', [r['status'] for r in rows])
        for row in rows:
            for field in ('before_json', 'after_json'): json.loads(row[field])
        rebuilt = io.StringIO(newline=''); writer = csv.DictWriter(rebuilt, fieldnames=list(rows[0]), quoting=csv.QUOTE_ALL, lineterminator='\r\n')
        writer.writeheader(); writer.writerows(rows)
        self.assertEqual(rebuilt.getvalue().encode(), output.stdout)

    def test_renamed_report_and_relocated_bundles(self):
        renamed = fixture(self.root / 'renamed.zip', AFTER, 'after', report='renamed.info')
        result = self.invoke('--after-report', 'renamed.info', after=renamed)
        self.assertEqual(json.loads(result.stdout)['after']['source_file']['relative_path'], 'renamed.info')
        copied = self.root / 'copied.zip'; shutil.copyfile(self.before, copied)
        self.assertEqual(json.loads(self.invoke(before=copied).stdout)['rows'], json.loads(result.stdout)['rows'])

    def test_checksum_changed_conflicting_and_missing_stay_visible(self):
        left = fixture(self.root / 'left.zip', 'SF:file\nDA:1,1,a\nDA:2,1\nDA:3,1,a\nend_of_record\nSF:file\nDA:3,0,b\nend_of_record\n')
        right = fixture(self.root / 'right.zip', 'SF:file\nDA:1,0,b\nDA:2,0\nDA:3,0,a\nend_of_record\n')
        rows = json.loads(self.invoke(before=left, after=right).stdout)['rows']
        self.assertEqual([r['status'] for r in rows], ['source-changed', 'covered-to-uncovered', 'checksum-conflict'])
        self.assertEqual(rows[1]['comparison_basis'], 'coordinate-only')
        self.assertEqual(rows[2]['before']['checksums'], ['a', 'b'])

    def test_empty_records_and_header_only_filtered_result(self):
        empty = fixture(self.root / 'empty.zip', 'TN:none\r\nSF:empty\r\nLF:0\r\nLH:0\r\nend_of_record\r\n')
        output = self.invoke('--format', 'csv', '--changes-only', before=empty, after=empty)
        rows = list(csv.reader(io.StringIO(output.stdout.decode(), newline='')))
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(output.stderr)['before']['record_count'], 1)

    def test_opaque_paths_duplicate_reports_and_ignored_metadata(self):
        report = 'SF:=C:\\private,月\nFN:1,function\nBRDA:1,0,0,1\nDA:001,2\nend_of_record\nSF:=C:\\private,月\nDA:1,3\nend_of_record\n'
        one = fixture(self.root / 'opaque.zip', report)
        row = json.loads(self.invoke(before=one, after=one).stdout)['rows'][0]
        self.assertEqual(row['source_path'], '=C:\\private,月')
        self.assertEqual(row['before']['reported_hits_sum'], 5)
        self.assertEqual(len(row['before']['observations']), 2)
        self.assertEqual(row['comparison_basis'], 'coordinate-only')

    def test_invalid_late_report_refuses_without_partial_output(self):
        variants = ['SF:f\nDA:1,1\nDA:01,0\nend_of_record\n',
                    'SF:f\nDA:1,1\nLF:2\nend_of_record\n', 'SF:f\nDA:1,1\n',
                    'SF:f\nDA:0,1\nend_of_record\n', 'SF:f\nDA:1,2147483648\nend_of_record\n',
                    'SF:f\nDA:1,1\nFNL:1\nend_of_record\n', 'TN:dangling\n',
                    b'SF:f\nDA:1,1\nend_of_record\n\xff']
        for i, report in enumerate(variants):
            malformed = fixture(self.root / f'bad-{i}.zip', report)
            self.invoke(after=malformed, success=False)

    def test_changed_selected_or_unselected_artifact_refuses(self):
        for index in (0, 1):
            bad = fixture(self.root / f'changed-{index}.zip', AFTER,
                          mutate=lambda m: m['files'][index].update(fingerprint='0' * 64))
            self.invoke(after=bad, success=False)

    def test_bundle_inventory_and_path_errors_refuse(self):
        variants = [lambda m: m.update(total_bytes='0'), lambda m: m.update(format_version=True),
                    lambda m: m['files'][0].update(relative_path='../escape'),
                    lambda m: m['binding'].update(command_digest='bad'),
                    lambda m: m['files'][0].update(kind='SymbolicLink')]
        for i, mutation in enumerate(variants):
            bad = fixture(self.root / f'invalid-{i}.zip', AFTER, mutate=mutation)
            self.invoke(after=bad, success=False)
        extra = fixture(self.root / 'extra.zip', AFTER, extra='extra')
        self.invoke(after=extra, success=False)
        self.invoke('--after-report', 'missing.info', success=False)

    def test_report_and_observation_bounds(self):
        oversized = fixture(self.root / 'oversized.zip', b'#' * (1024 * 1024 + 1))
        self.invoke(after=oversized, success=False)
        report = 'SF:f\n' + ''.join(f'DA:{n},0\n' for n in range(1, 10002)) + 'end_of_record\n'
        excessive = fixture(self.root / 'excessive.zip', report)
        self.invoke(after=excessive, success=False)


if __name__ == '__main__': unittest.main()
