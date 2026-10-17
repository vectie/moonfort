"""Complete read-only custom SQL results against real retained ZIP fixtures."""
import csv
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
sys.path.insert(0, str(ROOT / 'tools'))
import sqlite_review as review
EVIDENCE = Path(os.environ.get('MOONFORT_QUERY_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-query-'))
EVIDENCE.mkdir(parents=True, exist_ok=True)


class QueryTests(unittest.TestCase):
    def setUp(self):
        self.folder = EVIDENCE / self._testMethodName
        self.folder.mkdir()
        with sqlite3.connect(':memory:') as conn:
            conn.execute('CREATE TABLE owners(id INTEGER PRIMARY KEY, name TEXT)')
            conn.execute('CREATE TABLE samples(id INTEGER PRIMARY KEY, owner_id INTEGER, score, raw BLOB, note TEXT)')
            conn.executemany('INSERT INTO owners VALUES (?,?)', [(1, '月'), (2, '=SUM(A1)')])
            conn.executemany('INSERT INTO samples VALUES (?,?,?,?,?)', [(1, 1, 2, b'\x00\xff', 'one\ntwo'), (2, 1, 3.5, None, None), (3, 2, 9223372036854775807, b'', 'quote,"')])
            conn.execute('CREATE TABLE generated(value INTEGER, doubled INTEGER AS (value * 2))')
            conn.execute('INSERT INTO generated(value) VALUES (4)')
            conn.execute('CREATE VIEW hidden_view AS SELECT * FROM samples')
            conn.execute('CREATE VIRTUAL TABLE virtual_rows USING fts5(text)')
            self.data = conn.serialize()
        self.database = self.folder / 'original.sqlite'; self.database.write_bytes(self.data)
        self.archive = self.folder / 'review.zip'
        artifact = 'results/samples.sqlite'
        manifest = {'format_version': 1, 'purpose': 'Review copy only; not approval or promotion',
                    'binding': {'protocol_version': 1, 'retention_id': 'synthetic-query', 'workspace_id': 'synthetic', 'approval_digest': 'a' * 64, 'command_digest': 'b' * 64},
                    'expires_at_ms': '1', 'total_bytes': str(len(self.data)),
                    'files': [{'relative_path': artifact, 'kind': 'RegularFile', 'size_bytes': str(len(self.data)), 'fingerprint': review.sha(self.data)}]}
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
            archive.writestr('artifacts/' + artifact, self.data)
        self.count = 0

    def query(self, sql, parameters=None, *, success=True, format='json', max_rows=1000, fingerprint=None, raw_parameters=None):
        self.count += 1
        prefix = self.folder / str(self.count)
        sql_path = prefix.with_suffix('.sql'); sql_path.write_text(sql, encoding='utf-8')
        param_path = prefix.with_suffix('.parameters.json')
        param_path.write_bytes(raw_parameters if raw_parameters is not None else json.dumps({'database_sha256': fingerprint or review.sha(self.data), 'parameters': parameters or []}).encode())
        before = {p: review.sha(p.read_bytes()) for p in (self.archive, self.database, sql_path, param_path)}
        args = [sys.executable, '-B', str(ROOT / 'tools/sqlite_review.py'), str(self.archive), '--database', 'results/samples.sqlite', 'query', '--sql', str(sql_path), '--parameters', str(param_path), '--format', format, '--max-rows', str(max_rows)]
        run = subprocess.run(args, capture_output=True, timeout=15)
        prefix.with_suffix('.stdout').write_bytes(run.stdout); prefix.with_suffix('.stderr').write_bytes(run.stderr)
        prefix.with_suffix('.command.json').write_text(json.dumps({'argv': args, 'exit': run.returncode}))
        self.assertEqual(before, {p: review.sha(p.read_bytes()) for p in before})
        self.assertEqual(run.returncode, 0 if success else 1, run.stderr)
        if not success:
            self.assertEqual(run.stdout, b'')
        else:
            context = json.loads(run.stderr)
            self.assertEqual(context['candidate_sha256'], review.sha(run.stdout))
            self.assertEqual(context['sql_sha256'], before[sql_path])
            self.assertEqual(context['parameters_sha256'], before[param_path])
            self.assertEqual(context['source']['bundle_sha256'], before[self.archive])
            self.assertTrue(context['complete'])
        return run

    def test_join_derived_columns_typed_parameters_and_complete_metadata(self):
        sql = 'SELECT o.name, s.id, s.score * ? AS weighted, CASE WHEN s.note IS NULL THEN ? ELSE s.note END AS note FROM samples s JOIN owners o ON o.id=s.owner_id WHERE o.name=? ORDER BY s.id'
        run = self.query(sql, [{'type': 'real', 'value': '2.0'}, {'type': 'text', 'value': 'missing'}, {'type': 'text', 'value': '月'}])
        result = json.loads(run.stdout)
        self.assertEqual(result['columns'], ['name', 'id', 'weighted', 'note'])
        self.assertEqual(result['row_count'], 2)
        self.assertEqual([r[2]['value'] for r in result['rows']], ['4.0', '7.0'])
        self.assertEqual(result['rows'][1][3]['value'], 'missing')

    def test_aggregates_and_correlated_subquery(self):
        run = self.query('SELECT o.name, count(s.id), sum(s.score), avg(s.score), min(s.score), max(s.score), coalesce(NULL, ?) FROM owners o JOIN samples s ON s.owner_id=o.id WHERE o.id=1 GROUP BY o.id', [{'type': 'text', 'value': 'fallback'}])
        self.assertEqual([c['value'] for c in json.loads(run.stdout)['rows'][0]], ['月', '2', '5.5', '2.75', '2', '3.5', 'fallback'])
        result = self.query('SELECT id FROM owners o WHERE EXISTS (SELECT 1 FROM samples s WHERE s.owner_id=o.id) ORDER BY id')
        self.assertEqual(len(json.loads(result.stdout)['rows']), 2)

    def test_typed_round_trip_csv_duplicate_labels_and_empty_result(self):
        sql = 'SELECT raw AS x, score AS x, note AS "" FROM samples ORDER BY id'
        result = json.loads(self.query(sql).stdout)
        rows = list(csv.reader(io.StringIO(self.query(sql, format='csv').stdout.decode())))
        self.assertEqual(rows[0], ['column:1:x', 'column:2:x', 'column:3:'])
        self.assertEqual([[json.loads(v) for v in row] for row in rows[1:]], result['rows'])
        self.assertEqual(result['rows'][2][1], {'type': 'integer', 'value': '9223372036854775807'})
        self.assertEqual(result['rows'][0][0], {'type': 'blob', 'value': 'AP8='})
        empty = json.loads(self.query('SELECT id FROM samples WHERE 0').stdout)
        self.assertEqual(empty['rows'], []); self.assertEqual(empty['columns'], ['id'])

    def test_bound_parameters_are_data_and_preserve_all_storage_classes(self):
        typed = [{'type': 'null', 'value': None}, {'type': 'blob', 'value': 'AP8='}, {'type': 'integer', 'value': '9223372036854775807'}, {'type': 'real', 'value': '1.5'}, {'type': 'text', 'value': "'; DROP TABLE samples;--"}]
        result = json.loads(self.query('SELECT ?, ?, ?, ?, ?', typed).stdout)
        self.assertEqual(result['rows'][0], typed)
        self.assertEqual(json.loads(self.query('SELECT count(*) FROM samples').stdout)['rows'][0][0]['value'], '3')

    def test_writes_pragma_attach_extensions_and_multiple_statements_refused(self):
        for sql in ['DELETE FROM samples', 'UPDATE samples SET note="changed"', 'CREATE TABLE new(value)', 'DROP TABLE owners', 'INSERT INTO owners VALUES(3,"other") RETURNING id', 'PRAGMA query_only=OFF', 'PRAGMA table_list', "ATTACH DATABASE ':memory:' AS other", 'SELECT load_extension(?)', 'SELECT 1; SELECT 2', 'VACUUM', 'BEGIN', 'SELECT random()', 'SELECT readfile(?)']:
            with self.subTest(sql=sql):
                self.query(sql, [{'type': 'text', 'value': 'nonexistent'}] if '?' in sql else [], success=False)

    def test_views_virtual_shadow_schema_generated_and_recursive_refused(self):
        for sql in ['SELECT * FROM hidden_view', 'SELECT * FROM virtual_rows', 'SELECT * FROM virtual_rows_data', 'SELECT * FROM sqlite_master', 'SELECT doubled FROM generated', 'WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<4) SELECT * FROM x']:
            with self.subTest(sql=sql): self.query(sql, success=False)
        self.assertEqual(json.loads(self.query('SELECT value * 2 FROM generated').stdout)['rows'][0][0]['value'], '8')

    def test_row_work_and_sql_size_bounds_refuse_without_partial_results(self):
        self.query('SELECT * FROM samples', max_rows=2, success=False)
        self.query('SELECT * FROM samples LIMIT 2', max_rows=2)
        for bound in (0, 10001): self.query('SELECT 1', max_rows=bound, success=False)
        self.query('SELECT 1' + ' ' * review.MAX_SELECTION, success=False)
        self.query('SELECT count(*) FROM samples a,samples b,samples c,samples d,samples e,samples f,samples g,samples h,samples i,samples j,samples k,samples l,samples m,samples n,samples o', success=False)

    def test_stale_invalid_parameters_binding_and_nonfinite_refused(self):
        self.query('SELECT 1', fingerprint='0' * 64, success=False)
        for raw in (b'{"database_sha256":"x","database_sha256":"y","parameters":[]}', b'{"parameters":[]}'):
            self.query('SELECT 1', raw_parameters=raw, success=False)
        for typed in ({'type': 'integer', 'value': '9223372036854775808'}, {'type': 'real', 'value': '1e999'}, {'type': 'blob', 'value': '%%%'}):
            self.query('SELECT ?', [typed], success=False)
        self.query('SELECT ?', success=False)
        self.query('SELECT 1', [{'type': 'null', 'value': None}], success=False)
        self.query('SELECT 1e999', success=False)
        self.query('', success=False)
        self.query('SELECT\x00 1', success=False)


if __name__ == '__main__': unittest.main()
