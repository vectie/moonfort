#!/usr/bin/env python3
"""Retained snapshots -> explicit keys -> changed records -> exact source drillback."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'tools/sqlite_review.py'
EVIDENCE = Path(os.environ.get('MOONFORT_COMPARISON_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-comparison-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()
def typed(kind, value): return {'type': kind, 'value': value}


class SQLiteComparisonTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName
        self.root.mkdir()
        self.counter = 0
        self.before = self.snapshot('before', [('A', 'linux', 'passed', 1, None, b'', 7),
                                              ('B', 'linux', 'failed', 2, 'old', b'\x00\xff', 7),
                                              ('C', 'mac', 'failed', 3, 'removed', None, 7)])
        self.after = self.snapshot('after', [('D', 'mac', 'passed', 4, 'added', b'x', 7),
                                            ('B', 'linux', 'passed', 2.5, 'new\n月', b'\x00\xff', 7),
                                            ('A', 'linux', 'passed', 1, None, b'', 7)])

    def snapshot(self, name, rows, schema=None, table='results', artifact='results/review.sqlite'):
        schema = schema or ('CREATE TABLE runs (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO runs VALUES (7, "Nightly"); '
                            'CREATE TABLE results (code TEXT, platform TEXT, status TEXT, score, note, raw BLOB, run_id INTEGER REFERENCES runs(id));')
        database = self.root / (name + '.sqlite')
        conn = sqlite3.connect(database)
        try:
            conn.executescript(schema)
            if rows:
                placeholders = ','.join('?' for _ in rows[0])
                conn.executemany('INSERT INTO "' + table.replace('"', '""') + '" VALUES (' + placeholders + ')', rows)
            conn.commit()
        finally: conn.close()
        data = database.read_bytes()
        path = self.root / (name + '.zip')
        files = [(artifact, data), ('reports/readme.txt', b'retained run context')]
        manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                    'binding': {'protocol_version': 1, 'retention_id': name, 'workspace_id': 'review-workspace',
                                'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                    'expires_at_ms': '1', 'total_bytes': str(sum(len(content) for _, content in files)),
                    'files': [{'relative_path': item, 'kind': 'RegularFile', 'size_bytes': str(len(content)),
                               'fingerprint': sha(content)} for item, content in files]}
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
            for item, content in files: archive.writestr('artifacts/' + item, content)
        return {'path': path, 'database': database, 'data': data, 'artifact': artifact, 'manifest': manifest}

    def recipe(self, before=None, after=None, **extra):
        before, after = before or self.before, after or self.after
        recipe = {'before_database_sha256': sha(before['data']), 'after_database_sha256': sha(after['data']),
                  'table': 'results', 'key_columns': ['code', 'platform']} | extra
        path = self.root / ('recipe-' + str(self.counter) + '.json')
        path.write_text(json.dumps(recipe, ensure_ascii=False), encoding='utf-8')
        return path

    def invoke(self, recipe=None, before=None, after=None, format='json', success=True, extra=()):
        before, after = before or self.before, after or self.after
        recipe = recipe or self.recipe(before, after)
        protected = [item[key] for item in (before, after) for key in ('path', 'database')]
        fingerprints = [sha(path.read_bytes()) for path in protected]
        command = [sys.executable, str(CLI), str(before['path']), '--database', before['artifact'],
                   'compare', str(after['path']), '--selection', str(recipe), '--format', format, *map(str, extra)]
        result = subprocess.run(command, capture_output=True, timeout=20, env=os.environ | {'PYTHONDONTWRITEBYTECODE': '1'})
        self.counter += 1
        (self.root / f'{self.counter}.stdout').write_bytes(result.stdout)
        (self.root / f'{self.counter}.stderr').write_bytes(result.stderr)
        self.assertEqual([sha(path.read_bytes()) for path in protected], fingerprints)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            context = json.loads(result.stderr)
            self.assertEqual(context['candidate_sha256'], sha(result.stdout))
            self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
            self.assertEqual(context['selection_sha256'], sha(recipe.read_bytes()))
            for side, fixture in [('before', before), ('after', after)]:
                source = context[side]['source']
                self.assertEqual(source['bundle_sha256'], sha(fixture['path'].read_bytes()))
                self.assertEqual(source['source_file']['fingerprint'], sha(fixture['data']))
                self.assertEqual(source['binding'], fixture['manifest']['binding'])
                self.assertEqual(source['expires_at_ms'], '1')
                with zipfile.ZipFile(fixture['path']) as archive:
                    self.assertEqual(source['manifest_sha256'], sha(archive.read('manifest.json')))
        else:
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            self.assertEqual(result.stdout, b'')
        return result

    def test_reordered_rows_compare_by_business_key_and_drill_back_each_side(self):
        output = json.loads(self.invoke().stdout)
        self.assertEqual(output['counts'], {'before_rows': 3, 'after_rows': 3, 'added': 1, 'removed': 1, 'changed': 1, 'unchanged': 1})
        self.assertTrue(output['complete'])
        entries = {entry['key'][0]['value']: entry for entry in output['changes']}
        self.assertEqual(set(entries), {'B', 'C', 'D'})
        self.assertEqual(entries['B']['changed_columns'], ['status', 'score', 'note'])
        self.assertNotIn('before', entries['D']); self.assertNotIn('after', entries['C'])
        for side, fixture in [('before', self.before), ('after', self.after)]:
            conn = sqlite3.connect(fixture['database'])
            try:
                for entry in entries.values():
                    if side not in entry: continue
                    row = entry[side]
                    locator = int(row['locator'][0]['value'])
                    actual = conn.execute('SELECT code, platform, status, score, note, raw, run_id FROM results WHERE _rowid_=?', [locator]).fetchone()
                    self.assertEqual(actual[0], entry['key'][0]['value'])
                    self.assertEqual(actual[2], row['values'][2]['value'])
                    self.assertEqual(str(actual[3]), row['values'][3]['value'])
            finally: conn.close()
        # Returned changed-row locators re-enter the already supported outgoing reference flow.
        selected = {'database_sha256': sha(self.after['data']), 'table': 'results',
                    'locator': entries['B']['after']['locator'], 'foreign_key': 0}
        recipe = self.root / 'follow-run.json'; recipe.write_text(json.dumps(selected))
        related = subprocess.run([sys.executable, str(CLI), str(self.after['path']), '--database', self.after['artifact'],
                                  'related', '--selection', str(recipe)], capture_output=True, timeout=15)
        (self.root / 'follow-run.stdout').write_bytes(related.stdout); (self.root / 'follow-run.stderr').write_bytes(related.stderr)
        self.assertEqual(related.returncode, 0, related.stderr.decode())
        self.assertEqual(json.loads(related.stdout)['rows'][0]['values'][1]['value'], 'Nightly')

    def test_csv_round_trip_preserves_absent_sides_and_typed_values(self):
        recipe = self.recipe()
        output = json.loads(self.invoke(recipe).stdout)
        result = self.invoke(recipe, format='csv')
        records = list(csv.DictReader(io.StringIO(result.stdout.decode())))
        self.assertEqual(len(records), len(output['changes']))
        for record, entry in zip(records, output['changes']):
            self.assertEqual(record['change'], entry['change'])
            self.assertEqual(json.loads(record['key_json']), entry['key'])
            self.assertEqual(json.loads(record['changed_columns_json']), entry['changed_columns'])
            for side in ('before', 'after'):
                expected = entry.get(side)
                for field in ('locator', 'values'):
                    self.assertEqual(json.loads(record[side + '_' + field + '_json']), expected[field] if expected else None)

    def test_typed_keys_do_not_coerce_integer_real_text_blob_or_case(self):
        schema = 'CREATE TABLE results (key COLLATE NOCASE, value TEXT)'
        rows = [(1, 'integer'), (1.0, 'real'), ('1', 'text'), (b'1', 'blob'), ('A', 'upper'), ('a', 'lower'), ('', 'empty text'), (b'', 'empty blob')]
        before = self.snapshot('typed-before', rows, schema)
        after = self.snapshot('typed-after', list(reversed(rows)), schema)
        recipe = self.recipe(before, after, key_columns=['key'])
        output = json.loads(self.invoke(recipe, before, after).stdout)
        self.assertEqual(output['counts']['unchanged'], 8)
        self.assertEqual(output['changes'], [])

    def test_storage_type_changes_and_large_values_remain_visible(self):
        schema = 'CREATE TABLE results (key TEXT, value, other)'
        before = self.snapshot('values-before', [('one', 1, None), ('big', 9223372036854775807, b''), ('null', None, '')], schema)
        after = self.snapshot('values-after', [('one', 1.0, None), ('big', 9223372036854775806, b'\x00'), ('null', '', '=SUM(A1)')], schema)
        output = json.loads(self.invoke(self.recipe(before, after, key_columns=['key']), before, after).stdout)
        changes = {entry['key'][0]['value']: entry for entry in output['changes']}
        self.assertEqual(changes['one']['before']['values'][1], typed('integer', '1'))
        self.assertEqual(changes['one']['after']['values'][1], typed('real', '1.0'))
        self.assertEqual(changes['big']['before']['values'][1], typed('integer', '9223372036854775807'))
        self.assertEqual(changes['null']['before']['values'][1], typed('null', None))
        self.assertEqual(changes['null']['after']['values'][1], typed('text', ''))

    def test_composite_without_rowid_locators_and_quoted_names(self):
        table = '月"results'
        schema = 'CREATE TABLE "月""results" ("part""one" TEXT, slot INTEGER, value TEXT, PRIMARY KEY ("part""one", slot)) WITHOUT ROWID'
        before = self.snapshot('composite-before', [('A', 1, 'old'), ('A', 2, 'same')], schema, table)
        after = self.snapshot('composite-after', [('A', 2, 'same'), ('A', 1, 'new')], schema, table)
        recipe = self.recipe(before, after, table=table, key_columns=['part"one', 'slot'])
        output = json.loads(self.invoke(recipe, before, after).stdout)
        self.assertEqual(output['before']['locator'], {'kind': 'primary-key', 'columns': ['part"one', 'slot']})
        self.assertEqual(output['changes'][0]['before']['locator'], [typed('text', 'A'), typed('integer', '1')])
        self.assertEqual(output['changes'][0]['changed_columns'], ['value'])

    def test_key_change_is_removed_and_added_not_inferred_rename(self):
        schema = 'CREATE TABLE results (key TEXT, value TEXT)'
        before = self.snapshot('rename-before', [('old', 'same')], schema)
        after = self.snapshot('rename-after', [('new', 'same')], schema)
        output = json.loads(self.invoke(self.recipe(before, after, key_columns=['key']), before, after).stdout)
        self.assertEqual(output['counts']['changed'], 0)
        self.assertEqual({entry['change'] for entry in output['changes']}, {'added', 'removed'})

    def test_empty_and_identical_snapshots_are_complete_with_header_only_csv(self):
        empty = self.snapshot('empty', [])
        recipe = self.recipe(empty, empty)
        output = json.loads(self.invoke(recipe, empty, empty).stdout)
        self.assertEqual(sum(output['counts'].values()), 0)
        self.assertEqual(len(list(csv.reader(io.StringIO(self.invoke(recipe, empty, empty, format='csv').stdout.decode())))), 1)
        output = json.loads(self.invoke(self.recipe(self.before, self.before), self.before, self.before).stdout)
        self.assertEqual(output['counts']['unchanged'], 3)
        self.assertEqual(output['changes'], [])
        output = json.loads(self.invoke(self.recipe(empty, self.after), empty, self.after).stdout)
        self.assertEqual(output['counts']['added'], 3)

    def test_schema_evolution_requires_explicit_shared_projection(self):
        before = self.snapshot('schema-before', [('A', 'passed')], 'CREATE TABLE results (key TEXT, status TEXT)')
        after = self.snapshot('schema-after', [('A', 'passed', 'new metadata')], 'CREATE TABLE results (key TEXT, status TEXT, note TEXT)')
        failed = self.invoke(self.recipe(before, after, key_columns=['key']), before, after, success=False)
        self.assertIn(b'stored columns differ', failed.stderr)
        output = json.loads(self.invoke(self.recipe(before, after, key_columns=['key'], columns=['key', 'status']), before, after).stdout)
        self.assertEqual(output['counts']['unchanged'], 1)
        self.assertEqual(output['columns'], ['key', 'status'])

    def test_missing_and_ambiguous_keys_refuse_instead_of_picking_a_row(self):
        schema = 'CREATE TABLE results (key, value TEXT)'
        valid = self.snapshot('key-valid', [('A', 'one')], schema)
        for label, rows, diagnostic in [('duplicate', [('A', 'one'), ('A', 'two')], b'duplicate typed key'),
                                         ('null', [(None, 'one')], b'key contains NULL')]:
            invalid = self.snapshot(label, rows, schema)
            for side in ('before', 'after'):
                left, right = (invalid, valid) if side == 'before' else (valid, invalid)
                result = self.invoke(self.recipe(left, right, key_columns=['key']), left, right, success=False)
                self.assertIn(side.encode() + b' ' + diagnostic, result.stderr)
        result = self.invoke(self.recipe(key_columns=['missing']), success=False)
        self.assertIn(b'key columns must be included', result.stderr)

    def test_fingerprint_pinning_and_relocation(self):
        recipe = self.recipe()
        original = self.invoke(recipe).stdout
        moved = self.root / 'moved'; moved.mkdir()
        before, after = dict(self.before), dict(self.after)
        for side, fixture in [('before', before), ('after', after)]:
            path = moved / (side + '.zip'); shutil.copyfile(fixture['path'], path); fixture['path'] = path
        self.assertEqual(self.invoke(recipe, before, after).stdout, original)
        for side in ('before', 'after'):
            altered = json.loads(recipe.read_text()); altered[side + '_database_sha256'] = '0' * 64
            path = self.root / (side + '-stale.json'); path.write_text(json.dumps(altered))
            result = self.invoke(path, success=False)
            self.assertIn(side.encode() + b' database fingerprint', result.stderr)

    def test_complete_scan_bound_never_silently_compares_first_page(self):
        schema = 'CREATE TABLE results (key INTEGER, value TEXT)'
        maximum = self.snapshot('maximum', [(n, 'same') for n in range(10000)], schema)
        output = json.loads(self.invoke(self.recipe(maximum, maximum, key_columns=['key']), maximum, maximum).stdout)
        self.assertEqual(output['counts']['unchanged'], 10000)
        excessive = self.snapshot('excessive', [(n, 'same') for n in range(10001)], schema)
        result = self.invoke(self.recipe(maximum, excessive, key_columns=['key']), maximum, excessive, success=False)
        self.assertIn(b'after selection exceeds 10000 rows', result.stderr)

    def test_independent_after_artifact_path_and_whole_bundle_verification(self):
        after = self.snapshot('renamed', [('B', 'linux', 'passed', 2.5, 'new', None, 7)], artifact='output/final.sqlite')
        output = json.loads(self.invoke(self.recipe(self.before, after), self.before, after,
                                      extra=('--after-database', after['artifact'])).stdout)
        self.assertEqual(output['after']['source']['source_file']['relative_path'], 'output/final.sqlite')
        with zipfile.ZipFile(after['path']) as archive:
            members = {item.filename: archive.read(item.filename) for item in archive.infolist()}
        members['artifacts/reports/readme.txt'] = b'corrupted context!!!'
        with zipfile.ZipFile(after['path'], 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, content in members.items(): archive.writestr(name, content)
        result = self.invoke(self.recipe(self.before, after), self.before, after, success=False,
                             extra=('--after-database', after['artifact']))
        self.assertTrue(b'fingerprint mismatch' in result.stderr or b'wrong-size artifact' in result.stderr)


if __name__ == '__main__': unittest.main(verbosity=2)
