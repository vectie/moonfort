#!/usr/bin/env python3
"""Inspect one retained configuration -> runs -> filtered sample records."""
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
EVIDENCE = Path(os.environ.get('MOONFORT_REFERENCING_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-sqlite-referencing-'))
EVIDENCE.mkdir(exist_ok=True)
print('Retained evidence: ' + str(EVIDENCE), flush=True)


def sha(data): return hashlib.sha256(data).hexdigest()
def integer(value): return {'type': 'integer', 'value': str(value)}
def text(value): return {'type': 'text', 'value': value}


class ReferencingReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE / self._testMethodName
        self.root.mkdir()
        self.database = self.root / 'source.sqlite'
        self.counter = 0
        self.recipe_counter = 0
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''
                CREATE TABLE configurations (id INTEGER PRIMARY KEY, label TEXT);
                CREATE TABLE runs (name TEXT COLLATE NOCASE PRIMARY KEY, configuration INTEGER REFERENCES configurations(id));
                CREATE TABLE samples (id INTEGER PRIMARY KEY, run_name TEXT REFERENCES runs(name), status TEXT, notes TEXT, payload BLOB);
                INSERT INTO configurations VALUES (9007199254740993, '月 build'), (2, 'unused');
                INSERT INTO runs VALUES ('Nightly', 9007199254740993), ('Weekly', 9007199254740993);
                INSERT INTO samples VALUES (11, 'nightly', 'failed', 'first\nsecond', X'00FF'),
                    (12, 'NIGHTLY', 'passed', '', NULL), (13, 'nightly', 'failed', 'last', X''),
                    (22, NULL, 'skipped', '', NULL), (33, 'unrecorded', 'failed', '', NULL);
            ''')
        self.bundle = self.package('retained.zip')

    def package(self, name):
        path = self.root / name
        data = self.database.read_bytes()
        files = [('results/review.sqlite', data), ('reports/readme.txt', b'unchanged retained output')]
        manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                    'binding': {'protocol_version': 1, 'retention_id': 'retained-reference-run', 'workspace_id': 'review-workspace',
                                'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                    'expires_at_ms': '1', 'total_bytes': str(sum(len(v) for _, v in files)),
                    'files': [{'relative_path': k, 'kind': 'RegularFile', 'size_bytes': str(len(v)), 'fingerprint': sha(v)} for k, v in files]}
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
            for k, v in files: archive.writestr('artifacts/' + k, v)
        return path

    def selection(self, table='runs', locator=None, child_table='samples', foreign_key=0, **options):
        value = {'database_sha256': sha(self.database.read_bytes()), 'table': table,
                 'locator': [integer(1)] if locator is None else locator, 'child_table': child_table, 'foreign_key': foreign_key} | options
        self.recipe_counter += 1
        path = self.root / f'recipe-{self.recipe_counter}.json'
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
        self.assertEqual(context['source']['binding']['retention_id'], 'retained-reference-run')
        with zipfile.ZipFile(source) as archive:
            self.assertEqual(context['source']['manifest_sha256'], sha(archive.read('manifest.json')))
            self.assertEqual(context['source']['source_file']['fingerprint'], sha(archive.read('artifacts/results/review.sqlite')))
        if command == 'referencing':
            raw = Path(args[list(args).index('--selection') + 1]).read_bytes()
            self.assertEqual(context['selection_sha256'], sha(raw))
            self.assertEqual(context['relation_selection'], json.loads(raw))
        return result

    def referencing(self, recipe=None, *args, **kwargs):
        return self.invoke('referencing', '--selection', recipe or self.selection(), *args, **kwargs)

    def test_discover_configuration_then_runs_then_failed_samples(self):
        schema = json.loads(self.invoke('schema').stdout)
        objects = {item['name']: item for item in schema['objects']}
        relation = objects['configurations']['incoming_foreign_keys'][0]
        self.assertEqual(relation['child_table'], 'runs')
        runs = json.loads(self.referencing(self.selection('configurations', [integer(9007199254740993)], relation['child_table'], relation['id'])).stdout)
        self.assertEqual([row['values'][0] for row in runs['rows']], [text('Nightly'), text('Weekly')])
        incoming = objects['runs']['incoming_foreign_keys'][0]
        samples = json.loads(self.referencing(self.selection('runs', runs['rows'][0]['locator'], incoming['child_table'], incoming['id'],
            where=[{'column': 'status', 'value': text('failed')}])).stdout)
        self.assertEqual([row['values'][0] for row in samples['rows']], [integer(11), integer(13)])
        self.assertEqual(samples['source'], runs['source'])
        self.assertEqual(samples['source_row']['reference_values'], [text('Nightly')])
        self.assertEqual(samples['relationship']['resolved_child_columns'], ['run_name'])
        # Returned child locators remain usable by the existing outgoing workflow.
        outgoing = self.root / 'outgoing.json'
        outgoing.write_text(json.dumps({'database_sha256': sha(self.database.read_bytes()), 'table': 'samples',
                                       'locator': samples['rows'][0]['locator'], 'foreign_key': incoming['id']}))
        parent = json.loads(self.invoke('related', '--selection', outgoing).stdout)
        self.assertEqual(parent['rows'][0]['locator'], runs['rows'][0]['locator'])

    def test_pages_filters_sorting_and_past_end_preserve_match_status(self):
        recipe = self.selection(columns=['id', 'status'], order_by=[{'column':'id', 'direction':'desc'}])
        first = json.loads(self.referencing(recipe, '--limit', 2).stdout)
        second = json.loads(self.referencing(recipe, '--limit', 2, '--offset', first['next_offset']).stdout)
        self.assertEqual([row['values'][0] for row in first['rows'] + second['rows']], [integer(13), integer(12), integer(11)])
        self.assertTrue(first['has_more']); self.assertFalse(second['has_more'])
        past = json.loads(self.referencing(recipe, '--offset', 20).stdout)
        self.assertEqual(past['rows'], []); self.assertEqual(past['reference_status'], 'matching-child-rows')
        filtered = json.loads(self.referencing(self.selection(where=[{'column':'status','value':text('missing')}])).stdout)
        self.assertEqual(filtered['reference_status'], 'no-matching-child-rows')

    def test_parent_affinity_wins_over_child_affinity_like_sqlite_foreign_keys(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''
                CREATE TABLE numeric_parent (id INTEGER PRIMARY KEY);
                CREATE TABLE text_child (ref TEXT REFERENCES numeric_parent(id));
                INSERT INTO numeric_parent VALUES (7); INSERT INTO text_child VALUES ('007'), ('7'), ('7.0'), ('wrong');
                CREATE TABLE text_parent (id TEXT PRIMARY KEY);
                CREATE TABLE numeric_child (ref INTEGER REFERENCES text_parent(id));
                INSERT INTO text_parent VALUES ('007'), ('7'); INSERT INTO numeric_child VALUES (7);
                CREATE TABLE raw_parent (id PRIMARY KEY);
                CREATE TABLE other_numeric (ref INTEGER REFERENCES raw_parent(id));
                INSERT INTO raw_parent VALUES ('7'); INSERT INTO other_numeric VALUES (7);
            ''')
        self.bundle = self.package('affinity.zip')
        numeric = json.loads(self.referencing(self.selection('numeric_parent', [integer(7)], 'text_child')).stdout)
        self.assertEqual([r['values'][0] for r in numeric['rows']], [text('007'), text('7'), text('7.0')])
        text_zeroes = json.loads(self.referencing(self.selection('text_parent', [integer(1)], 'numeric_child')).stdout)
        text_plain = json.loads(self.referencing(self.selection('text_parent', [integer(2)], 'numeric_child')).stdout)
        raw = json.loads(self.referencing(self.selection('raw_parent', [integer(1)], 'other_numeric')).stdout)
        self.assertEqual(text_zeroes['rows'], []); self.assertEqual(raw['rows'], [])
        self.assertEqual(text_plain['rows'][0]['values'], [integer(7)])
        # Independent SQLite constraint oracle: parent TEXT '007' does not accept integer 7.
        with sqlite3.connect(':memory:') as conn:
            conn.execute('PRAGMA foreign_keys=ON')
            conn.executescript("CREATE TABLE p(id TEXT PRIMARY KEY); CREATE TABLE c(ref INTEGER REFERENCES p(id)); INSERT INTO p VALUES ('007');")
            with self.assertRaises(sqlite3.IntegrityError): conn.execute('INSERT INTO c VALUES (7)')
            conn.execute("INSERT INTO p VALUES ('7')"); conn.execute('INSERT INTO c VALUES (7)')

    def test_implicit_composite_without_rowid_and_exact_anchor(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE parents (region TEXT COLLATE NOCASE, version INTEGER, PRIMARY KEY(region,version)) WITHOUT ROWID;
                CREATE TABLE checks (batch TEXT, slot INTEGER, region TEXT, version TEXT,
                    PRIMARY KEY(batch,slot), FOREIGN KEY(region,version) REFERENCES parents) WITHOUT ROWID;
                INSERT INTO parents VALUES ('EU', 2), ('US', 2);
                INSERT INTO checks VALUES ('b',3,'eu','02'), ('b',4,'EU',NULL), ('b',5,'us','2');''')
        self.bundle = self.package('composite.zip')
        result = json.loads(self.referencing(self.selection('parents', [text('EU'), integer(2)], 'checks')).stdout)
        self.assertEqual(result['rows'][0]['locator'], [text('b'), integer(3)])
        self.assertEqual(result['source_row']['locator']['kind'], 'primary-key')
        self.assertEqual(result['relationship']['resolved_columns'], ['region', 'version'])
        self.assertEqual(len(result['rows']), 1)
        self.referencing(self.selection('parents', [text('eu'), integer(2)], 'checks'), success=False)

    def test_null_parent_key_and_unused_anchor_are_explicit(self):
        unused = json.loads(self.referencing(self.selection('runs', [integer(2)])).stdout)
        self.assertEqual(unused['reference_status'], 'no-matching-child-rows')
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE labels (code TEXT); CREATE TABLE observations (code TEXT REFERENCES labels(code));
                INSERT INTO labels VALUES (NULL); INSERT INTO observations VALUES (NULL);''')
        self.bundle = self.package('null.zip')
        null = json.loads(self.referencing(self.selection('labels', [integer(1)], 'observations')).stdout)
        self.assertEqual(null['reference_status'], 'null-parent-key'); self.assertEqual(null['rows'], [])
        self.assertFalse(null['has_more']); self.assertIsNone(null['next_offset'])

    def test_duplicate_parent_keys_do_not_duplicate_child_rows(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE labels (code TEXT); CREATE TABLE observations (code TEXT REFERENCES labels(code));
                INSERT INTO labels VALUES ('x'), ('x'); INSERT INTO observations VALUES ('x'), ('x');''')
        self.bundle = self.package('duplicates.zip')
        for anchor in (1, 2):
            output = json.loads(self.referencing(self.selection('labels', [integer(anchor)], 'observations')).stdout)
            self.assertEqual([row['locator'] for row in output['rows']], [[integer(1)], [integer(2)]])

    def test_multiple_relationships_and_self_reference_are_selected_explicitly(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE edges (id INTEGER PRIMARY KEY, first TEXT REFERENCES runs(name), second TEXT REFERENCES runs(name));
                INSERT INTO edges VALUES (1,'Nightly','Weekly'), (2,'Weekly','Nightly');
                CREATE TABLE nodes (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES nodes(id));
                INSERT INTO nodes VALUES (1,1), (2,1), (3,2);''')
        self.bundle = self.package('multiple.zip')
        schema = json.loads(self.invoke('schema').stdout)
        incoming = next(item for item in schema['objects'] if item['name'] == 'runs')['incoming_foreign_keys']
        edges = [item for item in incoming if item['child_table'] == 'edges']
        self.assertEqual(len(edges), 2)
        for key in edges:
            output = json.loads(self.referencing(self.selection(child_table='edges', foreign_key=key['id'])).stdout)
            self.assertEqual(output['rows'][0]['values'][0], integer(1 if key['columns'] == ['first'] else 2))
        self_rows = json.loads(self.referencing(self.selection('nodes', [integer(1)], 'nodes')).stdout)
        self.assertEqual(len(self_rows['rows']), 2)

    def test_quoted_case_folded_declarations_and_typed_csv_readback(self):
        with sqlite3.connect(self.database) as conn:
            conn.executescript('''CREATE TABLE "P""arent" ("K""ey" TEXT PRIMARY KEY);
                CREATE TABLE "C""hild" ("R""ef" TEXT REFERENCES "p""ARENT"("k""EY"), payload BLOB, notes TEXT);
                INSERT INTO "P""arent" VALUES ('月'); INSERT INTO "C""hild" VALUES ('月',X'00FF','line 1
line 2');''')
        self.bundle = self.package('quoted.zip')
        recipe = self.selection('P"arent', [integer(1)], 'C"hild', columns=['notes', 'payload', 'R"ef'])
        expected = json.loads(self.referencing(recipe).stdout)
        output = self.referencing(recipe, '--format', 'csv')
        rows = list(csv.reader(io.StringIO(output.stdout.decode())))
        self.assertEqual([json.loads(c) for c in rows[1][1:]], expected['rows'][0]['values'])
        self.assertEqual(json.loads(rows[1][0]), expected['rows'][0]['locator'])
        self.assertEqual(expected['relationship']['resolved_columns'], ['K"ey'])

    def test_recipe_and_bundle_relocation_preserve_exact_output(self):
        recipe = self.selection()
        original = self.referencing(recipe)
        moved = self.root / 'moved'; moved.mkdir()
        shutil.copyfile(self.bundle, moved / 'review.zip'); shutil.copyfile(recipe, moved / 'selection.json')
        again = self.referencing(moved / 'selection.json', source=moved / 'review.zip')
        self.assertEqual(original.stdout, again.stdout); self.assertEqual(original.stderr, again.stderr)
        self.assertEqual(sorted(path.name for path in moved.iterdir()), ['review.zip', 'selection.json'])

    def test_stale_anchor_and_wrong_relationship_refuse_before_output(self):
        stale = self.selection()
        with sqlite3.connect(self.database) as conn: conn.execute("UPDATE runs SET name='changed' WHERE rowid=1")
        self.bundle = self.package('changed.zip')
        self.assertIn(b'fingerprint', self.referencing(stale, success=False).stderr)
        self.assertIn(b'anchor table', self.referencing(self.selection('configurations', [integer(2)], 'samples'), success=False).stderr)
        self.assertIn(b'exactly one', self.referencing(self.selection(locator=[integer(999)]), success=False).stderr)
        self.assertIn(b'exactly one', self.referencing(self.selection(locator=[text('1')]), success=False).stderr)


if __name__ == '__main__': unittest.main()
