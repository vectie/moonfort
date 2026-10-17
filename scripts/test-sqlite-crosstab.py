"""Two-axis exploration with typed categories and original member records."""
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
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from sqlite_crosstab import crosstab
from sqlite_review import database
def sha(data): return hashlib.sha256(data).hexdigest()

class Crosstab(unittest.TestCase):
    def setUp(self):
        with sqlite3.connect(':memory:') as conn:
            conn.execute('CREATE TABLE samples(id INTEGER PRIMARY KEY, owner, status, detail)')
            conn.executemany('INSERT INTO samples VALUES (?,?,?,?)',[(1,'Alex','pass','a'),(2,'Alex','fail','b'),(3,'Jo','pass','c'),(4,1,None,'d'),(5,'1',None,'e'),(6,1.0,None,'f'),(7,b'1',None,'g')])
            self.data=conn.serialize()
        self.recipe={'database_sha256':sha(self.data),'table':'samples','row_column':'owner','column_column':'status'}
    def calculate(self, recipe=None):
        with database(self.data) as conn: return crosstab(conn,json.dumps(recipe or self.recipe).encode(),sha(self.data))
    def test_matrix_totals_and_exact_members(self):
        r=self.calculate()
        self.assertEqual(r['selected_row_count'],7)
        self.assertEqual(len(r['row_keys']),6)
        self.assertEqual(sum(r['row_totals']),7);self.assertEqual(sum(r['column_totals']),7)
        self.assertEqual(len(r['counts'][0]),3)
        i=r['row_keys'].index({'type':'text','value':'Jo'});j=r['column_keys'].index({'type':'text','value':'fail'})
        self.assertEqual(r['counts'][i][j],0)
        self.assertEqual(sum(len(c['rows']) for c in r['cells']),7)
        self.assertEqual(r['columns'],['id','owner','status','detail'])
        self.assertEqual(len(r['cells'][0]['rows'][0]['values']),4)
    def test_filtered_empty_and_stale(self):
        self.recipe['where']=[{'column':'id','value':{'type':'integer','value':'999'}}]
        r=self.calculate();self.assertEqual(r['counts'],[]);self.assertEqual(r['cells'],[])
        for change in ({'database_sha256':'0'*64},{'column_column':'owner'},{'row_column':'missing'}):
            with self.assertRaises(ValueError):self.calculate(self.recipe|change)
    def test_axis_bound(self):
        with sqlite3.connect(':memory:') as conn:
            conn.execute('CREATE TABLE samples(id INTEGER PRIMARY KEY, owner, status)')
            conn.executemany('INSERT INTO samples VALUES (?,?,?)',[(i,i,'x') for i in range(65)])
            self.data=conn.serialize()
        self.recipe['database_sha256']=sha(self.data)
        with self.assertRaisesRegex(ValueError,'64'):self.calculate()
    def test_zip_cli_and_unchanged_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(os.environ.get('MOONFORT_CROSSTAB_EVIDENCE',tmp));folder.mkdir(parents=True,exist_ok=True)
            artifact='results/samples.sqlite'
            manifest={'format_version':1,'purpose':'Review copy only; not approval or promotion','binding':{'protocol_version':1,'retention_id':'crosstab','workspace_id':'synthetic','approval_digest':'a'*64,'command_digest':'b'*64},'expires_at_ms':'1','total_bytes':str(len(self.data)),'files':[{'relative_path':artifact,'kind':'RegularFile','size_bytes':str(len(self.data)),'fingerprint':sha(self.data)}]}
            archive=folder/'review.zip'
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('manifest.json',json.dumps(manifest));z.writestr('artifacts/'+artifact,self.data)
            recipe=folder/'selection.json';recipe.write_text(json.dumps(self.recipe))
            before=sha(archive.read_bytes())
            cmd=[sys.executable,'-B',str(ROOT/'tools/sqlite_review.py'),str(archive),'--database',artifact,'crosstab','--selection',str(recipe)]
            run=subprocess.run(cmd,capture_output=True)
            (folder/'crosstab.json').write_bytes(run.stdout);(folder/'context.json').write_bytes(run.stderr)
            self.assertEqual(run.returncode,0,run.stderr);self.assertEqual(json.loads(run.stdout)['selected_row_count'],7)
            self.assertEqual(before,sha(archive.read_bytes()))
            recipe.write_text(json.dumps(self.recipe|{'database_sha256':'0'*64}))
            bad=subprocess.run(cmd,capture_output=True)
            self.assertNotEqual(bad.returncode,0);self.assertEqual(bad.stdout,b'')
            recipe.write_text(json.dumps(self.recipe))

if __name__=='__main__':unittest.main()
