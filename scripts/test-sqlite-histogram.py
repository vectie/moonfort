"""Numeric-band exploration of a real retained SQLite ZIP."""
import hashlib
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
sys.path.insert(0, str(ROOT/'tools'))
from sqlite_histogram import distribution
from sqlite_review import database

EVIDENCE = Path(os.environ.get('MOONFORT_HISTOGRAM_EVIDENCE') or tempfile.mkdtemp(prefix='histogram-'))
EVIDENCE.mkdir(parents=True, exist_ok=True)
def sha(data): return hashlib.sha256(data).hexdigest()
def integer(value): return {'type':'integer', 'value':str(value)}

class Histograms(unittest.TestCase):
    def setUp(self):
        with sqlite3.connect(':memory:') as conn:
            conn.execute('CREATE TABLE samples(id INTEGER PRIMARY KEY, latency)')
            conn.executemany('INSERT INTO samples VALUES (?,?)', enumerate([-1,0,1.5,10,11,None,'10',b'10',9007199254740993], 1))
            self.data = conn.serialize()
        self.recipe = {'database_sha256':sha(self.data), 'table':'samples', 'column':'latency', 'boundaries':[integer(0), integer(10)]}

    def calculate(self, recipe=None):
        with database(self.data) as conn: return distribution(conn, json.dumps(recipe or self.recipe).encode(), sha(self.data))

    def test_exact_bands_and_exclusions(self):
        result = self.calculate()
        self.assertEqual([b['count'] for b in result['bands']], [1,2,3])
        self.assertEqual([result['excluded'][k]['count'] for k in ('null','text','blob')], [1,1,1])
        self.assertEqual(result['bands'][2]['rows'][-1]['value'], integer(9007199254740993))
        self.assertEqual(result['selected_row_count'], 9)
        self.assertEqual(result['columns'], ['id', 'latency'])
        self.assertEqual(result['bands'][1]['rows'][0]['values'], [integer(2), integer(0)])

    def test_boundary_precision_filters_and_empty(self):
        self.recipe['boundaries'] = [integer(9007199254740992),integer(9007199254740993)]
        self.assertEqual([b['count'] for b in self.calculate()['bands']], [5,0,1])
        self.recipe['where'] = [{'column':'id','value':integer(999)}]
        self.assertEqual(self.calculate()['selected_row_count'], 0)

    def test_refuse_stale_or_unsorted(self):
        for changes in ({'database_sha256':'0'*64}, {'boundaries':[integer(10),integer(0)]}, {'boundaries':[]}):
            with self.assertRaises(ValueError): self.calculate(self.recipe | changes)

    def test_retained_zip_cli(self):
        artifact = 'results/samples.sqlite'
        manifest = {'format_version':1, 'purpose':'Review copy only; not approval or promotion',
            'binding':{'protocol_version':1,'retention_id':'histogram','workspace_id':'synthetic','approval_digest':'a'*64,'command_digest':'b'*64},
            'expires_at_ms':'1','total_bytes':str(len(self.data)),
            'files':[{'relative_path':artifact,'kind':'RegularFile','size_bytes':str(len(self.data)),'fingerprint':sha(self.data)}]}
        archive = EVIDENCE/'review.zip'
        with zipfile.ZipFile(archive,'w') as z:
            z.writestr('manifest.json',json.dumps(manifest)); z.writestr('artifacts/'+artifact,self.data)
        recipe = EVIDENCE/'bands.json'; recipe.write_text(json.dumps(self.recipe))
        before = sha(archive.read_bytes())
        run = subprocess.run([sys.executable,'-B',str(ROOT/'tools/sqlite_review.py'),str(archive),'--database',artifact,'histogram','--selection',str(recipe)],capture_output=True)
        (EVIDENCE/'histogram.json').write_bytes(run.stdout); (EVIDENCE/'context.json').write_bytes(run.stderr)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertEqual(json.loads(run.stdout)['bands'][1]['count'],2)
        self.assertEqual(before,sha(archive.read_bytes()))

if __name__ == '__main__': unittest.main()
