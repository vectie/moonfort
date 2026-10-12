#!/usr/bin/env python3
"""Retained failed sample -> declared parent record -> typed review readback."""
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
EVIDENCE = Path(os.environ.get('MOONFORT_RELATIONS_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-sqlite-relations-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()
def integer(value): return {'type': 'integer', 'value': str(value)}
def text(value): return {'type': 'text', 'value': value}


class RelationshipReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName
        self.root.mkdir()
        self.database = self.root / 'original.sqlite'
        self.counter = 0
        self.selection_counter = 0
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''
                CREATE TABLE configurations (id INTEGER PRIMARY KEY, label TEXT, payload BLOB, notes TEXT);
                CREATE TABLE runs (name TEXT COLLATE NOCASE PRIMARY KEY, configuration INTEGER REFERENCES configurations(id));
                CREATE TABLE samples (id INTEGER PRIMARY KEY, run_name TEXT REFERENCES runs(name), status TEXT);
                INSERT INTO configurations VALUES (9007199254740993, '月 build', X'00FF', 'first\nsecond');
                INSERT INTO runs VALUES ('Nightly', 9007199254740993);
                INSERT INTO samples VALUES (11, 'nightly', 'failed'), (22, NULL, 'skipped'), (33, 'unrecorded', 'failed');
            ''')
        self.bundle = self.package('retained.zip')

    def package(self, name):
        path = self.root / name
        data = self.database.read_bytes()
        files = [('results/review.sqlite', data), ('reports/readme.txt', b'unchanged retained output')]
        manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                    'binding': {'protocol_version': 1, 'retention_id': 'retained-sample-run', 'workspace_id': 'review-workspace',
                                'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                    'expires_at_ms': '1', 'total_bytes': str(sum(len(v) for _, v in files)),
                    'files': [{'relative_path': k, 'kind': 'RegularFile', 'size_bytes': str(len(v)), 'fingerprint': sha(v)} for k, v in files]}
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
            for k, v in files: archive.writestr('artifacts/' + k, v)
        return path

    def selection(self, table='samples', locator=None, foreign_key=0, **options):
        value = {'database_sha256': sha(self.database.read_bytes()), 'table': table,
                 'locator': locator or [integer(11)], 'foreign_key': foreign_key} | options
        self.selection_counter += 1
        path = self.root / f'selection-{self.selection_counter}.json'
        path.write_text(json.dumps(value, ensure_ascii=False))
        return path

    def invoke(self, command, *args, source=None, success=True):
        source = source or self.bundle
        before = (sha(source.read_bytes()), sha(self.database.read_bytes()))
        result = subprocess.run([sys.executable, str(CLI), str(source), '--database', 'results/review.sqlite', command, *map(str, args)],
                                capture_output=True, timeout=15, env=os.environ | {'PYTHONDONTWRITEBYTECODE': '1'})
        self.counter += 1
        (self.root / f'{self.counter}.stdout').write_bytes(result.stdout)
        (self.root / f'{self.counter}.stderr').write_bytes(result.stderr)
        self.assertEqual(before, (sha(source.read_bytes()), sha(self.database.read_bytes())))
        if not success:
            self.assertEqual(result.returncode, 1, result.stderr.decode()); self.assertEqual(result.stdout, b'')
            return result
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        context = json.loads(result.stderr)
        self.assertEqual(context['candidate_sha256'], sha(result.stdout))
        self.assertEqual(context['candidate_size_bytes'], len(result.stdout))
        self.assertEqual(context['source']['bundle_sha256'], before[0])
        self.assertEqual(context['source']['binding']['retention_id'], 'retained-sample-run')
        with zipfile.ZipFile(source) as archive:
            self.assertEqual(context['source']['manifest_sha256'], sha(archive.read('manifest.json')))
            self.assertEqual(context['source']['source_file']['fingerprint'], sha(archive.read('artifacts/results/review.sqlite')))
        if command == 'related':
            raw = Path(args[list(args).index('--selection') + 1]).read_bytes()
            self.assertEqual(context['selection_sha256'], sha(raw))
            self.assertEqual(context['relation_selection'], json.loads(raw))
        return result

    def related(self, selection=None, *args, **kwargs):
        return self.invoke('related', '--selection', selection or self.selection(), *args, **kwargs)

    def test_schema_discloses_declared_outgoing_relationships(self):
        output = json.loads(self.invoke('schema').stdout)
        objects = {obj['name']: obj for obj in output['objects']}
        self.assertEqual(objects['samples']['foreign_keys'], [{'id': 0, 'referenced_table': 'runs', 'columns': ['run_name'],
            'referenced_columns': ['name'], 'on_update': 'NO ACTION', 'on_delete': 'NO ACTION', 'match': 'NONE'}])
        self.assertEqual(objects['configurations']['foreign_keys'], [])

    def test_failed_row_drills_through_two_hops_with_exact_locators_and_receipt(self):
        recipe = self.root / 'failed.json'
        recipe.write_text(json.dumps({'table': 'samples', 'where': [{'column': 'status', 'value': text('failed')}]}))
        samples = json.loads(self.invoke('rows', '--selection', recipe).stdout)
        run = json.loads(self.related(self.selection(locator=samples['rows'][0]['locator'])).stdout)
        self.assertEqual(run['source_row']['reference_values'], [text('nightly')])
        self.assertEqual(run['rows'][0]['values'], [text('Nightly'), integer(9007199254740993)])
        config = json.loads(self.related(self.selection('runs', run['rows'][0]['locator'])).stdout)
        self.assertEqual(config['rows'][0]['values'], [integer(9007199254740993), text('月 build'),
            {'type': 'blob', 'value': 'AP8='}, text('first\nsecond')])
        self.assertEqual(config['source'], samples['source'])
        with sqlite3.connect(self.database) as conn:
            original = conn.execute('SELECT label FROM configurations WHERE rowid=?', [int(config['rows'][0]['locator'][0]['value'])]).fetchone()
        self.assertEqual(original[0], config['rows'][0]['values'][1]['value'])

    def test_parent_affinity_and_declared_collation_are_used(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE numeric_parent (id INTEGER PRIMARY KEY, value TEXT);
                CREATE TABLE numeric_child (ref TEXT REFERENCES numeric_parent(id));
                INSERT INTO numeric_parent VALUES (7, 'numeric parent');
                INSERT INTO numeric_child VALUES ('007');''')
        self.bundle = self.package('affinity.zip')
        output = json.loads(self.related(self.selection('numeric_child', [integer(1)])).stdout)
        self.assertEqual(output['source_row']['reference_values'], [text('007')])
        self.assertEqual(output['rows'][0]['values'][0], integer(7))
        case = json.loads(self.related().stdout)
        self.assertEqual(case['rows'][0]['values'][0], text('Nightly'))

    def test_composite_implicit_parent_key_and_without_rowid_source(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE parents (region TEXT, version INTEGER, label TEXT, PRIMARY KEY(region,version)) WITHOUT ROWID;
                CREATE TABLE checks (batch TEXT, slot INTEGER, region TEXT, version INTEGER,
                    PRIMARY KEY(batch,slot), FOREIGN KEY(region,version) REFERENCES parents) WITHOUT ROWID;
                INSERT INTO parents VALUES ('eu', 2, 'second revision'), ('us', 2, 'other region');
                INSERT INTO checks VALUES ('b', 3, 'eu', 2), ('b', 4, 'eu', NULL);''')
        self.bundle = self.package('composite.zip')
        output = json.loads(self.related(self.selection('checks', [text('b'), integer(3)])).stdout)
        self.assertEqual(output['relationship']['referenced_columns'], [None, None])
        self.assertEqual(output['relationship']['resolved_columns'], ['region', 'version'])
        self.assertEqual(output['source_row']['locator']['kind'], 'primary-key')
        self.assertEqual(output['rows'][0]['locator'], [text('eu'), integer(2)])
        self.assertEqual(output['rows'][0]['values'][2], text('second revision'))
        null_key = json.loads(self.related(self.selection('checks', [text('b'), integer(4)])).stdout)
        self.assertEqual(null_key['reference_status'], 'null-reference')
        self.assertEqual(null_key['rows'], [])

    def test_null_and_unresolved_references_are_explicit(self):
        for identity, status in [(22, 'null-reference'), (33, 'no-matching-parent')]:
            output = json.loads(self.related(self.selection(locator=[integer(identity)])).stdout)
            self.assertEqual(output['reference_status'], status)
            self.assertEqual(output['rows'], []); self.assertFalse(output['has_more']); self.assertIsNone(output['next_offset'])
        output = self.related(self.selection(locator=[integer(22)]), '--format', 'csv')
        self.assertEqual(len(list(csv.reader(io.StringIO(output.stdout.decode())))), 1)

    def test_csv_reopens_same_typed_parent_values(self):
        selection = self.selection('runs', [integer(1)], columns=['notes', 'payload', 'id'])
        expected = json.loads(self.related(selection).stdout)
        output = self.related(selection, '--format', 'csv')
        rows = list(csv.reader(io.StringIO(output.stdout.decode())))
        self.assertEqual(rows[0], ['locator_json', 'column:notes', 'column:payload', 'column:id'])
        self.assertEqual(json.loads(rows[1][0]), expected['rows'][0]['locator'])
        self.assertEqual([json.loads(value) for value in rows[1][1:]], expected['rows'][0]['values'])
        self.assertEqual(json.loads(output.stderr)['reference_status'], 'matching-parent-rows')

    def test_nonunique_declared_parent_keeps_all_matches_and_continuation(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE labels (code TEXT, label TEXT);
                CREATE TABLE observations (code TEXT REFERENCES labels(code));
                INSERT INTO labels VALUES ('x','first'), ('x','second'), ('x','third');
                INSERT INTO observations VALUES ('x');''')
        self.bundle = self.package('duplicate-parents.zip')
        recipe = self.selection('observations', [integer(1)], columns=['label'], order_by=[{'column':'label','direction':'desc'}])
        first = json.loads(self.related(recipe, '--limit', 2).stdout)
        second = json.loads(self.related(recipe, '--limit', 2, '--offset', first['next_offset']).stdout)
        self.assertEqual([row['values'][0]['value'] for row in first['rows'] + second['rows']], ['third', 'second', 'first'])
        self.assertTrue(first['has_more']); self.assertFalse(second['has_more'])
        past = json.loads(self.related(recipe, '--offset', 50).stdout)
        self.assertEqual(past['rows'], []); self.assertEqual(past['reference_status'], 'matching-parent-rows')

    def test_schema_selected_foreign_key_id_disambiguates_multiple_parents(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE pairs (first TEXT REFERENCES runs(name), second INTEGER REFERENCES configurations(id));
                INSERT INTO pairs VALUES ('Nightly',9007199254740993);''')
        self.bundle = self.package('two-keys.zip')
        schema = json.loads(self.invoke('schema').stdout)
        keys = next(obj for obj in schema['objects'] if obj['name'] == 'pairs')['foreign_keys']
        for key in keys:
            output = json.loads(self.related(self.selection('pairs', [integer(1)], key['id'])).stdout)
            self.assertEqual(output['selection']['table'], key['referenced_table'])
            self.assertEqual(len(output['rows']), 1)

    def test_case_folded_quoted_table_and_column_references_resolve(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE "Parent" ("A""Key" TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE "Child" ("Ref" TEXT REFERENCES "pARENT"("a""kEY"));
                INSERT INTO "Parent" VALUES ('same','quoted value'); INSERT INTO "Child" VALUES ('same');''')
        self.bundle = self.package('quoted.zip')
        output = json.loads(self.related(self.selection('Child', [integer(1)])).stdout)
        self.assertEqual(output['relationship']['resolved_table'], 'Parent')
        self.assertEqual(output['relationship']['resolved_columns'], ['A"Key'])
        self.assertEqual(output['rows'][0]['values'][1], text('quoted value'))

    def test_relocated_bundle_and_recipe_are_replayable(self):
        recipe = self.selection()
        original = self.related(recipe)
        moved = self.root / 'moved'; moved.mkdir()
        shutil.copyfile(self.bundle, moved / 'review.zip'); shutil.copyfile(recipe, moved / 'selection.json')
        again = self.related(moved / 'selection.json', source=moved / 'review.zip')
        self.assertEqual(original.stdout, again.stdout); self.assertEqual(original.stderr, again.stderr)
        self.assertEqual(sorted(path.name for path in moved.iterdir()), ['review.zip', 'selection.json'])

    def test_stale_database_or_absent_or_inexact_source_locator_refuses(self):
        old = self.selection()
        with sqlite3.connect(self.database) as conn: conn.execute("UPDATE samples SET run_name='changed' WHERE id=11")
        self.bundle = self.package('changed.zip')
        self.assertIn(b'fingerprint', self.related(old, success=False).stderr)
        for locator in ([integer(999)], [text('11')], [{'type':'null','value':None}]):
            self.related(self.selection(locator=locator), success=False)

    def test_unavailable_or_generated_relationship_target_is_not_evaluated(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE missing (ref INTEGER REFERENCES absent(id)); INSERT INTO missing VALUES(1);
                CREATE TABLE calculated (id INTEGER, key INTEGER AS (id * 2)); INSERT INTO calculated(id) VALUES(1);
                CREATE TABLE child_computed (ref INTEGER REFERENCES calculated(key)); INSERT INTO child_computed VALUES(2);''')
        self.bundle = self.package('unsupported.zip')
        for table in ('missing','child_computed'):
            self.related(self.selection(table, [integer(1)]), success=False)
        self.related(self.selection(foreign_key=99), success=False)


if __name__ == '__main__': unittest.main()
