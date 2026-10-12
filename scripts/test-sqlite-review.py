#!/usr/bin/env python3
"""Saved review ZIP -> schema -> selected rows -> portable typed JSON/CSV."""
import base64
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
EVIDENCE = Path(os.environ.get('MOONFORT_SQLITE_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-sqlite-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()


def make_bundle(path, data, artifact='results/review.sqlite', mutate=None):
    files = [(artifact, data), ('reports/readme.txt', b'retained report context')]
    manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                'binding': {'protocol_version': 1, 'retention_id': 'saved-run', 'workspace_id': 'example-workspace',
                            'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                'expires_at_ms': '1', 'total_bytes': str(sum(len(content) for _, content in files)),
                'files': [{'relative_path': name, 'kind': 'RegularFile', 'size_bytes': str(len(content)), 'fingerprint': sha(content)} for name, content in files]}
    if mutate: mutate(manifest)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr('manifest.json', json.dumps(manifest))
        for name, content in files: archive.writestr('artifacts/' + name, content)
    return path


class SQLiteReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName
        self.root.mkdir()
        self.database = self.root / 'original.sqlite'
        with sqlite3.connect(self.database) as conn:
            conn.execute('CREATE TABLE samples (id INTEGER PRIMARY KEY, owner TEXT, status TEXT, score REAL, raw BLOB, note)')
            conn.executemany('INSERT INTO samples VALUES (?, ?, ?, ?, ?, ?)', [
                (11, 'Zoë', 'failed', 2.5, b'\x00\xff', None),
                (22, '月', 'passed', 1.0, b'', ''),
                (33, 'Zoë', 'failed', 2.5, None, 9223372036854775807),
                (44, '=SUM(A1)', 'failed', -0.125, b'abc', 'one\ntwo'),
                (55, 'zoë', 'failed', 7.0, b'x', '1'),
                (66, 'Zoë', 'failed', 7.0, b'y', 1),
                (77, 'Zoë', 'failed', 7.0, b'z', 1.0)])
            conn.execute('CREATE TABLE empty (value TEXT)')
            conn.execute('CREATE VIEW summary AS SELECT owner, count(*) FROM samples GROUP BY owner')
        self.bundle = make_bundle(self.root / 'retained.zip', self.database.read_bytes())
        self.counter = 0

    def recipe(self, data, name='selection.json'):
        path = self.root / name
        path.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return path

    def invoke(self, *args, source=None, artifact='results/review.sqlite', success=True):
        source = source or self.bundle
        hashes = [sha(source.read_bytes()), sha(self.database.read_bytes())]
        result = subprocess.run([sys.executable, str(CLI), str(source), '--database', artifact, *map(str, args)],
                                capture_output=True, timeout=15, env=os.environ | {'PYTHONDONTWRITEBYTECODE': '1'})
        self.counter += 1
        (self.root / f'{self.counter}.stdout').write_bytes(result.stdout)
        (self.root / f'{self.counter}.stderr').write_bytes(result.stderr)
        self.assertEqual(hashes, [sha(source.read_bytes()), sha(self.database.read_bytes())])
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            context = json.loads(result.stderr)
            self.assertEqual(context['candidate_sha256'], sha(result.stdout))
            self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
            self.assertEqual(context['source']['bundle_sha256'], hashes[0])
            with zipfile.ZipFile(source) as archive:
                self.assertEqual(context['source']['manifest_sha256'], sha(archive.read('manifest.json')))
                self.assertEqual(context['source']['source_file']['fingerprint'], sha(archive.read('artifacts/' + artifact)))
            self.assertEqual(context['source']['expires_at_ms'], '1')
        else:
            self.assertEqual(result.returncode, 1, result.stderr.decode()); self.assertEqual(result.stdout, b'')
        return result

    def test_schema_discovers_ordinary_tables_and_marks_views(self):
        result = json.loads(self.invoke('schema').stdout)
        objects = {item['name']: item for item in result['objects']}
        self.assertEqual(set(objects), {'empty', 'samples', 'summary'})
        self.assertFalse(objects['summary']['row_selection_supported'])
        self.assertEqual(objects['summary']['columns'], [])
        self.assertEqual(objects['samples']['columns'][0]['primary_key_position'], 1)
        self.assertEqual([column['name'] for column in objects['samples']['columns']], ['id', 'owner', 'status', 'score', 'raw', 'note'])

    def test_select_filter_sort_continue_and_read_back_exact_source_rows(self):
        recipe = self.recipe({'table': 'samples', 'columns': ['id', 'owner', 'score'],
                              'where': [{'column': 'status', 'value': {'type': 'text', 'value': 'failed'}}],
                              'order_by': [{'column': 'score', 'direction': 'desc'}]})
        pages, offset = [], 0
        while True:
            result = self.invoke('rows', '--selection', recipe, '--limit', 2, '--offset', offset)
            output = json.loads(result.stdout)
            self.assertEqual(output['selection_sha256'], sha(recipe.read_bytes()))
            pages.extend(output['rows'])
            if not output['has_more']:
                self.assertIsNone(output['next_offset']); break
            offset = output['next_offset']
        ids = [int(row['values'][0]['value']) for row in pages]
        self.assertEqual(ids, [55, 66, 77, 11, 33, 44])
        self.assertEqual(len({row['locator'][0]['value'] for row in pages}), 6)
        with sqlite3.connect(self.database) as conn:
            for row in pages:
                original = conn.execute('SELECT id, owner, score FROM samples WHERE _rowid_=?', [int(row['locator'][0]['value'])]).fetchone()
                self.assertEqual([str(original[0]), original[1], repr(original[2])], [v['value'] for v in row['values']])

    def test_default_order_and_typed_cells_preserve_null_blob_and_large_integer(self):
        recipe = self.recipe({'table': 'samples'})
        output = json.loads(self.invoke('rows', '--selection', recipe).stdout)
        rows = output['rows']
        self.assertEqual([int(row['locator'][0]['value']) for row in rows], [11, 22, 33, 44, 55, 66, 77])
        self.assertEqual(rows[0]['values'][4], {'type': 'blob', 'value': 'AP8='})
        self.assertEqual(rows[0]['values'][5], {'type': 'null', 'value': None})
        self.assertEqual(rows[1]['values'][4], {'type': 'blob', 'value': ''})
        self.assertEqual(rows[1]['values'][5], {'type': 'text', 'value': ''})
        self.assertEqual(rows[2]['values'][5], {'type': 'integer', 'value': '9223372036854775807'})
        self.assertEqual(rows[3]['values'][5], {'type': 'text', 'value': 'one\ntwo'})

    def test_csv_round_trip_preserves_typed_values_and_column_order(self):
        recipe = self.recipe({'table': 'samples', 'columns': ['note', 'owner', 'raw']})
        baseline = json.loads(self.invoke('rows', '--selection', recipe).stdout)
        output = self.invoke('rows', '--selection', recipe, '--format', 'csv')
        rows = list(csv.reader(io.StringIO(output.stdout.decode('utf-8'))))
        self.assertEqual(rows[0], ['locator_json', 'column:note', 'column:owner', 'column:raw'])
        for csv_row, json_row in zip(rows[1:], baseline['rows']):
            self.assertEqual(json.loads(csv_row[0]), json_row['locator'])
            self.assertEqual([json.loads(value) for value in csv_row[1:]], json_row['values'])
        self.assertEqual(json.loads(rows[4][2])['value'], '=SUM(A1)')

    def test_storage_type_filters_do_not_collapse_text_integer_real_or_null(self):
        for value, expected in [({'type': 'text', 'value': '1'}, [55]), ({'type': 'integer', 'value': '1'}, [66]),
                                ({'type': 'real', 'value': '1.0'}, [77]), ({'type': 'null', 'value': None}, [11])]:
            recipe = self.recipe({'table': 'samples', 'columns': ['id'], 'where': [{'column': 'note', 'value': value}]})
            rows = json.loads(self.invoke('rows', '--selection', recipe).stdout)['rows']
            self.assertEqual([int(row['values'][0]['value']) for row in rows], expected)

    def test_multiple_filters_include_exact_blob_and_case_sensitive_text(self):
        recipe = self.recipe({'table': 'samples', 'columns': ['id'], 'where': [
            {'column': 'owner', 'value': {'type': 'text', 'value': 'Zoë'}},
            {'column': 'raw', 'value': {'type': 'blob', 'value': base64.b64encode(b'y').decode()}}]})
        rows = json.loads(self.invoke('rows', '--selection', recipe).stdout)['rows']
        self.assertEqual([row['values'][0]['value'] for row in rows], ['66'])

    def test_empty_table_no_match_and_offset_past_end_are_explicit(self):
        for recipe_data, extra in [({'table': 'empty'}, []), ({'table': 'samples'}, ['--offset', '100']),
                                   ({'table': 'samples', 'where': [{'column': 'owner', 'value': {'type': 'text', 'value': 'absent'}}]}, [])]:
            recipe = self.recipe(recipe_data)
            output = json.loads(self.invoke('rows', '--selection', recipe, *extra).stdout)
            self.assertEqual(output['rows'], []); self.assertFalse(output['has_more']); self.assertIsNone(output['next_offset'])
        csv_result = self.invoke('rows', '--selection', self.recipe({'table': 'empty'}), '--format', 'csv')
        self.assertEqual(len(list(csv.reader(io.StringIO(csv_result.stdout.decode())))), 1)

    def test_without_rowid_composite_key_and_quoted_identifiers(self):
        database = self.root / 'keys.sqlite'
        with sqlite3.connect(database) as conn:
            conn.execute('CREATE TABLE "月\"\"table" ("part\"\"one" TEXT, slot INTEGER, value TEXT, PRIMARY KEY ("part\"\"one",slot)) WITHOUT ROWID')
            conn.executemany('INSERT INTO "月\"\"table" VALUES (?, ?, ?)', [('b', 2, 'second'), ('a', 3, 'third'), ('a', 1, 'first')])
        source = make_bundle(self.root / 'keys.zip', database.read_bytes())
        recipe = self.recipe({'table': '月"table', 'columns': ['value']})
        output = json.loads(self.invoke('rows', '--selection', recipe, source=source).stdout)
        self.assertEqual(output['locator'], {'kind': 'primary-key', 'columns': ['part"one', 'slot']})
        self.assertEqual([row['values'][0]['value'] for row in output['rows']], ['first', 'third', 'second'])
        self.assertEqual(output['rows'][0]['locator'], [{'type': 'text', 'value': 'a'}, {'type': 'integer', 'value': '1'}])

    def test_relocated_archive_and_selection_reopen_deterministically(self):
        recipe = self.recipe({'table': 'samples', 'columns': ['owner']})
        first = self.invoke('rows', '--selection', recipe)
        moved = self.root / 'moved'; moved.mkdir()
        source, selection = moved / 'copy.zip', moved / 'recipe.json'
        shutil.copyfile(self.bundle, source); shutil.copyfile(recipe, selection)
        second = self.invoke('rows', '--selection', selection, source=source)
        self.assertEqual(first.stdout, second.stdout); self.assertEqual(first.stderr, second.stderr)
        self.assertEqual(sorted(path.name for path in moved.iterdir()), ['copy.zip', 'recipe.json'])

    def test_generated_columns_are_disclosed_and_stored_columns_remain_usable(self):
        database = self.root / 'generated.sqlite'
        with sqlite3.connect(database) as conn:
            conn.execute('CREATE TABLE computed (value INTEGER, doubled INTEGER AS (value * 2))')
            conn.execute('INSERT INTO computed (value) VALUES (3)')
        source = make_bundle(self.root / 'generated.zip', database.read_bytes())
        schema = json.loads(self.invoke('schema', source=source).stdout)
        self.assertTrue(schema['objects'][0]['columns'][1]['generated'])
        output = json.loads(self.invoke('rows', '--selection', self.recipe({'table': 'computed'}), source=source).stdout)
        self.assertEqual(output['selection']['columns'], ['value'])
        self.invoke('rows', '--selection', self.recipe({'table': 'computed', 'columns': ['doubled']}), source=source, success=False)

    def test_rowid_alias_shadow_uses_available_alias(self):
        database = self.root / 'shadow.sqlite'
        with sqlite3.connect(database) as conn:
            conn.execute('CREATE TABLE names (_ROWID_ TEXT, rowid TEXT, value TEXT)')
            conn.execute("INSERT INTO names VALUES ('display', 'field', 'data')")
        source = make_bundle(self.root / 'shadow.zip', database.read_bytes())
        output = json.loads(self.invoke('rows', '--selection', self.recipe({'table': 'names'}), source=source).stdout)
        self.assertEqual(output['locator'], {'kind': 'rowid', 'columns': ['oid']})
        self.assertEqual(output['rows'][0]['locator'][0]['value'], '1')

    def test_unsupported_selection_and_bounded_page_refuse_without_partial_output(self):
        for recipe in [{'table': 'summary'}, {'table': 'absent'}, {'table': 'samples', 'columns': ['ID']},
                       {'table': 'samples', 'sql': 'DELETE FROM samples'}, {'table': 'samples', 'columns': ['id', 'id']}]:
            self.invoke('rows', '--selection', self.recipe(recipe), success=False)
        selection = self.recipe({'table': 'samples'})
        self.invoke('rows', '--selection', selection, '--limit', 1001, success=False)
        self.invoke('rows', '--selection', selection, '--offset', -1, success=False)

    def test_missing_or_changed_bundled_evidence_refuses(self):
        self.invoke('schema', artifact='results/missing.sqlite', success=False)
        source = make_bundle(self.root / 'changed.zip', self.database.read_bytes(), mutate=lambda m: m['files'][1].update(fingerprint='0'*64))
        self.invoke('schema', source=source, success=False)

    def test_non_database_and_wal_mode_are_not_presented_as_complete_snapshots(self):
        self.invoke('schema', source=make_bundle(self.root / 'text.zip', b'not a database'), success=False)
        data = bytearray(self.database.read_bytes()); data[18:20] = b'\x02\x02'
        self.invoke('schema', source=make_bundle(self.root / 'wal.zip', data), success=False)


if __name__ == '__main__': unittest.main()
