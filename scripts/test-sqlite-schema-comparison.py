#!/usr/bin/env python3
"""Real retained ZIPs -> schema changes -> both-side rows and relationships."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'tools/sqlite_review.py'
EVIDENCE = Path(os.environ.get('MOONFORT_SCHEMA_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-schema-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained synthetic evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()
def typed(kind, value): return {'type': kind, 'value': value}


def db(script):
    with sqlite3.connect(':memory:') as conn:
        conn.execute('PRAGMA page_size=512')
        conn.executescript(script)
        return conn.serialize()


def snapshot(name, data, artifact='results/review.sqlite', tamper=False):
    path = EVIDENCE / (name + '.zip')
    files = [(artifact, data), ('reports/context.txt', b'Synthetic retained-copy fixture only')]
    manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                'binding': {'protocol_version': 1, 'retention_id': name, 'workspace_id': 'synthetic-workspace',
                            'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                'expires_at_ms': '1', 'total_bytes': str(sum(len(data) for _, data in files)),
                'files': [{'relative_path': item, 'kind': 'RegularFile', 'size_bytes': str(len(content)),
                           'fingerprint': sha(content)} for item, content in files]}
    if tamper: manifest['files'][1]['fingerprint'] = '0' * 64
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr('manifest.json', json.dumps(manifest))
        for item, content in files: archive.writestr('artifacts/' + item, content)
    return {'path': path, 'data': data, 'artifact': artifact, 'manifest': manifest}


class SchemaComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shared = '''CREATE TABLE runs (id INTEGER PRIMARY KEY, title TEXT);
            INSERT INTO runs VALUES (7, 'Nightly');
            CREATE TABLE owners (id INTEGER PRIMARY KEY, title TEXT);
            INSERT INTO owners VALUES (7, 'Ada');
            CREATE TABLE hidden (rowid TEXT, _rowid_ TEXT, oid TEXT);
            CREATE TABLE "月\"\"items" ("part\"\"one" TEXT, slot INTEGER, value TEXT,
                PRIMARY KEY ("part\"\"one", slot)) WITHOUT ROWID;
            INSERT INTO "月\"\"items" VALUES ('A', 1, 'quoted');
            CREATE TABLE same (id INTEGER PRIMARY KEY, note TEXT);'''
        before = shared + '''CREATE TABLE results (id INTEGER PRIMARY KEY,
            owner_id INTEGER REFERENCES runs(id) ON DELETE CASCADE,
            score INTEGER NOT NULL DEFAULT 0, note TEXT,
            label TEXT GENERATED ALWAYS AS (score || ' units') STORED);
            INSERT INTO results(id, owner_id, score, note) VALUES (11,7,2,'old'),(22,7,3,'kept'),(33,7,4,NULL);
            CREATE TABLE removed (id INTEGER PRIMARY KEY); INSERT INTO removed VALUES (1);
            CREATE TABLE flags (id INTEGER PRIMARY KEY, value TEXT);
            CREATE VIEW summary AS SELECT 1 AS value;
            INSERT INTO same VALUES (1, 'before');'''
        after = shared + '''CREATE TABLE results (id INTEGER PRIMARY KEY,
            owner_id INTEGER REFERENCES owners(id) ON DELETE RESTRICT,
            score REAL NOT NULL DEFAULT 1.5, state TEXT DEFAULT 'pending',
            label TEXT GENERATED ALWAYS AS (score || ' units') VIRTUAL);
            INSERT INTO results(id, owner_id, score, state) VALUES (11,7,2.5,'ready'),(22,7,3.5,'ready'),(44,7,4.5,'pending');
            CREATE TABLE added (id INTEGER PRIMARY KEY); INSERT INTO added VALUES (2);
            CREATE TABLE flags (id INTEGER PRIMARY KEY, value TEXT) WITHOUT ROWID, STRICT;
            CREATE VIEW summary AS SELECT 2 AS value;
            INSERT INTO same VALUES (1, 'after');'''
        cls.before = snapshot('before', db(before))
        cls.after = snapshot('after', db(after), 'changed/review.sqlite')

    def setUp(self):
        self.counter = 0
        self.protected = {item['path']: sha(item['path'].read_bytes()) for item in (self.before, self.after)}

    def tearDown(self):
        self.assertEqual({path: sha(path.read_bytes()) for path in self.protected}, self.protected)
        self.assertFalse(list(EVIDENCE.glob('*-wal')) + list(EVIDENCE.glob('*-shm')) + list(EVIDENCE.glob('*-journal')))

    def save(self, name, value):
        path = EVIDENCE / (self._testMethodName + '-' + name + '.json')
        path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        return path

    def invoke(self, fixture, *arguments, success=True):
        self.counter += 1
        prefix = EVIDENCE / (self._testMethodName + '-' + str(self.counter))
        command = [sys.executable, str(CLI), str(fixture['path']), '--database', fixture['artifact'], *map(str, arguments)]
        fingerprints = {path: sha(path.read_bytes()) for path in EVIDENCE.glob('*.zip')}
        result = subprocess.run(command, capture_output=True, timeout=15,
                                env=os.environ | {'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertLessEqual(len(result.stdout) + len(result.stderr), 65536)
        prefix.with_suffix('.stdout').write_bytes(result.stdout)
        prefix.with_suffix('.stderr').write_bytes(result.stderr)
        with (EVIDENCE / 'commands.jsonl').open('a') as log:
            log.write(json.dumps({'argv': command, 'returncode': result.returncode,
                                  'stdout': prefix.name + '.stdout', 'stderr': prefix.name + '.stderr'}) + '\n')
        self.assertEqual({path: sha(path.read_bytes()) for path in fingerprints}, fingerprints)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            context = json.loads(result.stderr)
            self.assertEqual(context['candidate_sha256'], sha(result.stdout))
            self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
        else:
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            self.assertEqual(result.stdout, b'')
        return result

    def compare(self, table=None, before=None, after=None, request=None, success=True):
        before, after = before or self.before, after or self.after
        if request is None:
            request = {'before_database_sha256': sha(before['data']), 'after_database_sha256': sha(after['data'])}
            if table is not None: request['table'] = table
        recipe = self.save('comparison-' + str(self.counter), request)
        result = self.invoke(before, 'compare-schema', after['path'], '--after-database', after['artifact'],
                             '--selection', recipe, success=success)
        if not success: return result
        output = json.loads(result.stdout)
        self.assertEqual(output['selection_sha256'], sha(recipe.read_bytes()))
        for side, fixture in [('before', before), ('after', after)]:
            source = output[side]['source']
            self.assertEqual(source['bundle_sha256'], sha(fixture['path'].read_bytes()))
            self.assertEqual(source['binding'], fixture['manifest']['binding'])
            self.assertEqual(source['source_file']['fingerprint'], sha(fixture['data']))
            self.assertEqual(source['expires_at_ms'], '1')
        return output

    def navigate(self, fixture, action, name, offset=0, limit=2):
        selection = self.save(name, action['selection'])
        args = list(action['argv_after_bundle'])
        self.assertEqual(args[:3], ['--database', fixture['artifact'], 'rows'])
        args[args.index('--selection') + 1] = str(selection)
        args[args.index('--offset') + 1] = str(offset)
        args[args.index('--limit') + 1] = str(limit)
        return json.loads(self.invoke(fixture, *args[2:]).stdout)

    def test_change_index_and_honest_metadata_scope(self):
        result = self.compare()
        entries = {entry['name']: entry for entry in result['objects']}
        self.assertEqual(result['counts'], {'added': 1, 'removed': 1, 'changed': 2, 'unchanged': 6})
        self.assertEqual(entries['results']['changed_fields'], ['columns', 'foreign_keys'])
        self.assertEqual(entries['flags']['changed_fields'], ['without_rowid', 'strict', 'columns'])
        self.assertEqual(entries['same']['change'], 'unchanged')  # Different rows are outside schema scope.
        self.assertEqual(entries['summary']['change'], 'unchanged')  # Different view SQL is expressly outside scope.
        self.assertEqual(entries['runs']['change'], 'unchanged')  # Incoming changes do not rewrite parent schema.
        self.assertTrue(result['complete_metadata_inventory'])
        self.assertIn('view/virtual/shadow definitions', ' '.join(result['limits']))
        self.assertNotIn('selected', result)

    def test_select_changed_columns_defaults_generated_kinds_and_foreign_keys(self):
        selected = self.compare('results')['selected']
        changes = {entry['name']: entry for entry in selected['column_changes']}
        self.assertEqual(changes['note']['change'], 'removed')
        self.assertEqual(changes['state']['change'], 'added')
        self.assertEqual(changes['score']['before']['column']['default_sql'], '0')
        self.assertEqual(changes['score']['after']['column']['default_sql'], '1.5')
        self.assertEqual(changes['score']['after']['column']['declared_type'], 'REAL')
        self.assertEqual(changes['label']['before']['column']['generated_kind'], 'stored')
        self.assertEqual(changes['label']['after']['column']['generated_kind'], 'virtual')
        self.assertEqual(selected['before']['foreign_keys'][0]['referenced_table'], 'runs')
        self.assertEqual(selected['after']['foreign_keys'][0]['referenced_table'], 'owners')
        self.assertEqual(selected['after']['foreign_keys'][0]['on_delete'], 'RESTRICT')

    def test_returned_navigation_runs_existing_rows_on_both_sides_and_pages(self):
        actions = self.compare('results')['selected']['row_navigation']
        for side, fixture, expected in [('before', self.before, [11, 22, 33]), ('after', self.after, [11, 22, 44])]:
            action = actions[side]
            self.assertTrue(action['available'])
            self.assertNotIn('label', action['selection']['columns'])
            pages, offset = [], 0
            while True:
                page = self.navigate(fixture, action, side + '-' + str(offset), offset)
                self.assertEqual(page['expected_database_sha256'], sha(fixture['data']))
                pages += [int(row['locator'][0]['value']) for row in page['rows']]
                if not page['has_more']: break
                self.assertGreater(page['next_offset'], offset)
                offset = page['next_offset']
            self.assertEqual(pages, expected)

    def test_navigated_row_follows_each_sides_actual_foreign_key(self):
        selected = self.compare('results')['selected']
        for side, fixture, expected in [('before', self.before, 'Nightly'), ('after', self.after, 'Ada')]:
            page = self.navigate(fixture, selected['row_navigation'][side], 'rows-' + side)
            recipe = self.save('related-' + side, {'database_sha256': sha(fixture['data']), 'table': 'results',
                                                  'locator': page['rows'][0]['locator'], 'foreign_key': 0})
            related = json.loads(self.invoke(fixture, 'related', '--selection', recipe).stdout)
            self.assertEqual(related['rows'][0]['values'][1]['value'], expected)
            reverse = self.save('referencing-' + side, {'database_sha256': sha(fixture['data']),
                'table': related['selection']['table'], 'locator': related['rows'][0]['locator'],
                'child_table': 'results', 'foreign_key': 0})
            incoming = json.loads(self.invoke(fixture, 'referencing', '--selection', reverse, '--limit', 2).stdout)
            self.assertEqual(incoming['row_count'], 2)
            self.assertTrue(incoming['has_more'])

    def test_added_removed_unsupported_and_missing_objects_are_explicit(self):
        for table, absent in [('added', 'before'), ('removed', 'after')]:
            selected = self.compare(table)['selected']
            self.assertIsNone(selected[absent])
            self.assertFalse(selected['row_navigation'][absent]['available'])
            side = 'after' if absent == 'before' else 'before'
            fixture = self.after if side == 'after' else self.before
            self.assertEqual(self.navigate(fixture, selected['row_navigation'][side], table)['row_count'], 1)
        for table in ['summary', 'hidden']:
            result = self.compare(table)
            for action in result['selected']['row_navigation'].values():
                self.assertFalse(action['available'])
                self.assertIn('reason', action)
        self.compare('Results', success=False)
        self.compare('unknown', success=False)

    def test_composite_and_quoted_identifiers_reenter_rows(self):
        selected = self.compare('月"items')['selected']
        for side, fixture in [('before', self.before), ('after', self.after)]:
            action = selected['row_navigation'][side]
            self.assertEqual(action['locator']['kind'], 'primary-key')
            page = self.navigate(fixture, action, side)
            self.assertEqual(page['rows'][0]['locator'], [typed('text', 'A'), typed('integer', '1')])

    def test_stale_fingerprints_and_closed_recipe_fail_without_output(self):
        request = {'before_database_sha256': sha(self.before['data']), 'after_database_sha256': sha(self.after['data'])}
        for invalid in [request | {'before_database_sha256': '0' * 64}, request | {'after_database_sha256': '0' * 64},
                        request | {'sql': 'DELETE FROM results'}, request | {'table': 1}, {}, []]:
            self.compare(request=invalid, success=False)
        selection = self.save('rows', {'table': 'results'})
        result = self.invoke(self.after, 'rows', '--selection', selection,
                            '--expected-database-sha256', sha(self.before['data']), success=False)
        self.assertIn(b'fingerprint does not match', result.stderr)

    def test_full_bundle_validation_wal_and_bounded_objects_refuse(self):
        tampered = snapshot('unrelated-artifact-tampered', self.after['data'], tamper=True)
        self.compare(after=tampered, success=False)
        wal = bytearray(self.after['data']); wal[18:20] = b'\x02\x02'
        self.compare(after=snapshot('wal', bytes(wal)), success=False)
        many = db(';'.join('CREATE TABLE t' + str(i) + '(id)' for i in range(101)))
        result = self.compare(after=snapshot('too-many', many), success=False)
        self.assertIn(b'exceeds 100 schema objects', result.stderr)
        oversized = EVIDENCE / (self._testMethodName + '-oversized.json')
        oversized.write_bytes(b' ' * (65536 + 1))
        self.invoke(self.before, 'compare-schema', self.after['path'], '--after-database', self.after['artifact'],
                    '--selection', oversized, success=False)

    def test_existing_schema_rows_filters_csv_compare_and_summary_still_work(self):
        schema = json.loads(self.invoke(self.before, 'schema').stdout)
        self.assertEqual(schema['object_count'], 9)
        row_recipe = self.save('filtered', {'table': 'results', 'columns': ['id', 'score'],
             'where': [{'column': 'score', 'op': 'between', 'value': typed('integer', '2'), 'upper': typed('integer', '3')}]})
        rows = list(csv.DictReader(io.StringIO(self.invoke(self.before, 'rows', '--selection', row_recipe, '--format', 'csv').stdout.decode())))
        self.assertEqual(len(rows), 2)
        self.assertEqual(json.loads(rows[0]['column:id']), typed('integer', '11'))
        comparison = self.save('row-compare', {'before_database_sha256': sha(self.before['data']),
            'after_database_sha256': sha(self.after['data']), 'table': 'same', 'key_columns': ['id']})
        result = json.loads(self.invoke(self.before, 'compare', self.after['path'], '--after-database', self.after['artifact'],
                                        '--selection', comparison).stdout)
        self.assertEqual(result['counts']['changed'], 1)
        summary = self.save('summary', {'database_sha256': sha(self.before['data']), 'table': 'results',
                                      'group_by': ['owner_id'], 'measures': ['score']})
        grouped = json.loads(self.invoke(self.before, 'summarize', '--selection', summary).stdout)
        self.assertEqual(grouped['selected_row_count'], 3)
        group = self.save('group', grouped['groups'][0]['key'])
        members = json.loads(self.invoke(self.before, 'group-rows', '--selection', summary, '--group', group, '--limit', 2).stdout)
        self.assertEqual(members['total_group_rows'], 3)
        self.assertTrue(members['has_more'])


if __name__ == '__main__': unittest.main()
