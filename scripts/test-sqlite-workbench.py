#!/usr/bin/env python3
"""Real loopback HTTP plus production UI in a minimal DOM; not browser qualification."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from sqlite_workbench import Workbench, server
EVIDENCE=Path(os.environ.get('MOONFORT_WORKBENCH_EVIDENCE') or tempfile.mkdtemp(prefix='moonfort-workbench-'))
EVIDENCE.mkdir(exist_ok=True)
print('Evidence: '+str(EVIDENCE),flush=True)

class WorkbenchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        db=EVIDENCE/'fixture.sqlite'
        with sqlite3.connect(db) as conn:
            conn.executescript('''CREATE TABLE parents(id INTEGER PRIMARY KEY, payload BLOB, missing TEXT);
            CREATE TABLE samples(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parents(id), status TEXT);
            CREATE TABLE categories(id INTEGER PRIMARY KEY, category, channel TEXT, included INTEGER);
            CREATE TABLE measurements(id INTEGER PRIMARY KEY, latency, included INTEGER, note TEXT);
            INSERT INTO measurements VALUES(1,-1,1,'negative'),(2,0,1,'zero'),(3,1.5,1,'fraction'),
              (4,10,1,'edge'),(5,11,1,'above'),(6,NULL,1,'missing'),(7,'10',1,'numeric text'),
              (8,X'3130',1,'bytes'),(9,9007199254740993,1,'large exact'),(10,0,0,'filtered out'),
              (11,9007199254740992,1,'adjacent large'),(12,10.0,1,'real edge');
            INSERT INTO categories VALUES(1,NULL,'A',1),(2,'NULL','A',1),(3,7,'A',1),(4,'7','A',1),(5,7,'B',1),(6,7,'A',0),(7,NULL,'A',1);
            INSERT INTO parents VALUES(9007199254740993,X'00FF',NULL);
            INSERT INTO samples VALUES(1,9007199254740993,'failed'),(2,9007199254740993,'failed'),(3,NULL,'ok');
            CREATE TABLE "<img onerror=alert(1)>" ("x''; DROP TABLE samples;--" TEXT);
            INSERT INTO "<img onerror=alert(1)>" VALUES('<script>alert(1)</script>');''')
        data=db.read_bytes(); digest=hashlib.sha256(data).hexdigest()
        manifest={'format_version':1,'purpose':'Review copy only; not approval or promotion','binding':{'protocol_version':1,'retention_id':'ui-fixture','workspace_id':'fixture','approval_digest':'a'*64,'command_digest':'b'*64},'expires_at_ms':'1','total_bytes':str(len(data)),'files':[{'relative_path':'review.sqlite','kind':'RegularFile','size_bytes':str(len(data)),'fingerprint':digest}]}
        cls.archive=EVIDENCE/'fixture.zip'
        with zipfile.ZipFile(cls.archive,'w') as z:
            z.writestr('manifest.json',json.dumps(manifest)); z.writestr('artifacts/review.sqlite',data)
        cls.work=Workbench(str(cls.archive),'review.sqlite'); cls.http=server(cls.work)
        cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True); cls.thread.start()
        cls.base={'session':cls.work.session,'database_sha256':digest}
        cls.records=[]

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown(); cls.thread.join(); cls.http.server_close()
        (EVIDENCE/'http-results.json').write_text(json.dumps(cls.records,indent=2))

    def call(self, body, overrides=None, path='/api', method='POST'):
        conn=http.client.HTTPConnection('127.0.0.1',self.http.server_port,timeout=10)
        headers={'Origin':'http://'+self.http.address,'X-Review-Token':self.work.token,'Content-Type':'application/json'}
        headers.update(overrides or {})
        conn.request(method,path,json.dumps(self.base|body),headers)
        response=conn.getresponse(); raw=response.read(); status=response.status; conn.close()
        self.records.append({'operation':body.get('operation'),'status':status,'response':raw.decode()[:3000]})
        return status,json.loads(raw)

    def test_http_journey_and_refusals(self):
        status, schema=self.call({'operation':'schema'}); self.assertEqual(status,200)
        self.assertEqual(schema['source']['binding']['retention_id'],'ui-fixture')
        request={'operation':'rows','selection':{'table':'samples','where':[{'column':'status','value':{'type':'text','value':'failed'}}],'order_by':[{'column':'id','direction':'desc'}]},'limit':1}
        status, page=self.call(request); self.assertEqual(status,200); self.assertEqual(page['rows'][0]['values'][0]['value'],'2'); self.assertTrue(page['has_more'])
        _, second=self.call(request|{'offset':page['next_offset']}); self.assertEqual(second['rows'][0]['values'][0]['value'],'1')
        relation={'table':'samples','locator':second['rows'][0]['locator'],'foreign_key':0,'database_sha256':self.work.digest}
        _, parent=self.call({'operation':'related','selection':relation}); self.assertEqual(parent['rows'][0]['values'],[{'type':'integer','value':'9007199254740993'},{'type':'blob','value':'AP8='},{'type':'null','value':None}])
        reverse={'table':'parents','locator':parent['rows'][0]['locator'],'foreign_key':0,'child_table':'samples','database_sha256':self.work.digest}
        _, child=self.call({'operation':'referencing','selection':reverse}); self.assertEqual(len(child['rows']),2)
        status, query=self.call({'operation':'query','sql':'SELECT id,payload,missing FROM parents WHERE id=?','parameters':[{'type':'integer','value':'9007199254740993'}]}); self.assertEqual(status,200); self.assertEqual(query['rows'][0],parent['rows'][0]['values'])
        for sql in ['DELETE FROM samples','ATTACH DATABASE ? AS bad','SELECT load_extension(?)','SELECT random()','PRAGMA table_list','SELECT * FROM sqlite_master','SELECT * FROM samples; SELECT 1']:
            self.assertEqual(self.call({'operation':'query','sql':sql,'parameters':[{'type':'text','value':':memory:'}] if '?' in sql else []})[0],400,sql)
        for body in [request|{'limit':1001},request|{'offset':1000001},request|{'session':'old'},request|{'database_sha256':'0'*64},request|{'path':'/etc/passwd'}, {'operation':'query','sql':'SELECT * FROM samples','max_rows':1}, {'operation':'query','sql':'x'*65537}]:
            self.assertEqual(self.call(body)[0],400)
        for headers in [{'Origin':'http://evil.invalid'},{'X-Review-Token':'wrong'},{'Host':'evil.invalid'},{'Content-Length':'200000'}]:
            self.assertIn(self.call({'operation':'schema'},headers)[0],(400,403))
        self.assertEqual(self.call({},path='/etc/passwd',method='GET')[0],404)
        self.assertEqual(self.call({'operation':'rows','selection':{'table':'<img onerror=alert(1)>'}})[1]['rows'][0]['values'][0]['value'],'<script>alert(1)</script>')

    def test_crosstab_typed_members(self):
        selection={'database_sha256':self.work.digest,'table':'categories','row_column':'category','column_column':'channel',
            'where':[{'column':'included','value':{'type':'integer','value':'1'}}]}
        status,result=self.call({'operation':'crosstab','selection':selection})
        self.assertEqual(status,200)
        self.assertEqual(result['selected_row_count'],6)
        self.assertEqual(sum(result['row_totals']),6)
        self.assertEqual(result['column_totals'],[5,1])
        self.assertEqual(len(result['row_keys']),4)
        for key,ids in [({'type':'null','value':None},['1','7']),({'type':'text','value':'NULL'},['2']),
                        ({'type':'integer','value':'7'},['3']),({'type':'text','value':'7'},['4'])]:
            i=result['row_keys'].index(key)
            cell=next(c for c in result['cells'] if c['row_index']==i and c['column_index']==0)
            self.assertEqual([r['values'][0]['value'] for r in cell['rows']],ids)
            self.assertTrue(all(r['values'][3]['value']=='1' for r in cell['rows']))
        self.assertEqual(self.call({'operation':'crosstab','selection':selection|{'column_column':'category'}})[0],400)
        self.assertEqual(self.call({'operation':'crosstab','selection':selection|{'database_sha256':'0'*64}})[0],400)

    def test_production_ui_over_http(self):
        result=subprocess.run(['node',str(ROOT/'scripts/test-sqlite-workbench-ui.cjs'),self.http.address,self.work.token],capture_output=True,text=True,timeout=30)
        (EVIDENCE/'ui.stdout').write_text(result.stdout); (EVIDENCE/'ui.stderr').write_text(result.stderr)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_sql_worksheet_fresh_sessions_and_source_refusals(self):
        before=self.archive.read_bytes()
        with zipfile.ZipFile(self.archive) as archive:
            manifest=json.loads(archive.read('manifest.json'))
            data=archive.read('artifacts/review.sqlite')
        alternate=EVIDENCE/'different-source.zip'
        alternate_manifest=manifest|{'binding':manifest['binding']|{'retention_id':'another-retained-source'}}
        with zipfile.ZipFile(alternate,'w') as archive:
            archive.writestr('manifest.json',json.dumps(alternate_manifest))
            archive.writestr('artifacts/review.sqlite',data)
        changed_db=EVIDENCE/'changed.sqlite';changed_db.write_bytes(data)
        with sqlite3.connect(changed_db) as conn:
            conn.execute("INSERT INTO samples VALUES(4,NULL,'new revision')")
        changed_data=changed_db.read_bytes()
        changed_manifest=manifest|{'total_bytes':str(len(changed_data)),
            'files':[manifest['files'][0]|{'size_bytes':str(len(changed_data)),
                                        'fingerprint':hashlib.sha256(changed_data).hexdigest()}]}
        changed=EVIDENCE/'different-database.zip'
        with zipfile.ZipFile(changed,'w') as archive:
            archive.writestr('manifest.json',json.dumps(changed_manifest))
            archive.writestr('artifacts/review.sqlite',changed_data)
        sessions=[]
        try:
            for path in (self.archive,alternate,changed):
                work=Workbench(str(path),'review.sqlite');http=server(work)
                thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
                sessions.append((work,http,thread))
            command=['node',str(ROOT/'scripts/test-sqlite-worksheet-ui.cjs'),self.http.address,self.work.token]
            for work,http,_ in sessions: command.extend([http.address,work.token])
            result=subprocess.run(command,capture_output=True,text=True,timeout=30)
            (EVIDENCE/'worksheet-ui.stdout').write_text(result.stdout)
            (EVIDENCE/'worksheet-ui.stderr').write_text(result.stderr)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(self.archive.read_bytes(),before)
        finally:
            for _,http,thread in sessions:
                http.shutdown();thread.join(timeout=5);http.server_close()
                self.assertFalse(thread.is_alive())

    def test_histogram_typed_boundaries_and_original_members(self):
        integer=lambda value: {'type':'integer','value':str(value)}
        boundaries=[integer(0),{'type':'real','value':'1.5'},integer(10),integer(9007199254740992),integer(9007199254740993)]
        selection={'database_sha256':self.work.digest,'table':'measurements','column':'latency','boundaries':boundaries,
            'where':[{'column':'included','value':integer(1)}]}
        before=self.archive.read_bytes()
        status,result=self.call({'operation':'histogram','selection':selection})
        self.assertEqual(status,200)
        self.assertEqual(result['selection'],selection)
        self.assertEqual(result['source']['binding']['retention_id'],'ui-fixture')
        self.assertTrue(result['complete_selection_scanned'])
        self.assertEqual(result['selected_row_count'],11)
        self.assertEqual([b['count'] for b in result['bands']],[1,1,1,3,1,1])
        self.assertEqual([result['excluded'][k]['count'] for k in ('null','text','blob')],[1,1,1])
        self.assertEqual(result['bands'][0]['lower_inclusive'],None)
        self.assertEqual(result['bands'][-1]['upper_exclusive'],None)
        for band,ids in zip(result['bands'],[['1'],['2'],['3'],['4','5','12'],['11'],['9']]):
            self.assertEqual([row['values'][0]['value'] for row in band['rows']],ids)
            for row in band['rows']:
                self.assertEqual(row['locator'],[row['values'][0]])
                self.assertEqual(row['values'][2],integer(1))
                self.assertEqual(len(row['values']),4)
                self.assertEqual(row['value'],row['values'][1])
        self.assertEqual(result['bands'][-1]['rows'][0]['value'],integer(9007199254740993))
        for kind,expected in [('null','6'),('text','7'),('blob','8')]:
            row=result['excluded'][kind]['rows'][0]
            self.assertEqual(row['values'][0]['value'],expected)
            self.assertEqual(row['value']['type'],kind)
        empty=selection|{'where':[{'column':'id','value':integer(999)}]}
        status,result=self.call({'operation':'histogram','selection':empty})
        self.assertEqual(status,200); self.assertEqual(result['selected_row_count'],0)
        self.assertTrue(all(b['count']==0 for b in result['bands']))
        for changes in [{'boundaries':[]},{'boundaries':[integer(1)]*33},
                        {'boundaries':[integer(10),integer(0)]},
                        {'boundaries':[integer(1),{'type':'real','value':'1.0'}]},
                        {'boundaries':[{'type':'real','value':'NaN'}]},
                        {'boundaries':[{'type':'text','value':'1'}]},
                        {'boundaries':[integer(9223372036854775808)]},
                        {'column':'missing'},{'database_sha256':'0'*64}]:
            self.assertEqual(self.call({'operation':'histogram','selection':selection|changes})[0],400,changes)
        self.assertEqual(self.call({'operation':'histogram','selection':selection,'limit':1})[0],400)
        self.assertEqual(self.call({'operation':'histogram','selection':selection,'session':'old'})[0],400)
        self.assertEqual(self.archive.read_bytes(),before)

    def test_z_snapshot_pinned_after_path_change(self):
        before=self.archive.read_bytes()
        # Retain the original fixture and alter only a separate named startup copy.
        copy=EVIDENCE/'replaceable.zip'; copy.write_bytes(before)
        pinned=Workbench(str(copy),'review.sqlite'); copy.write_bytes(b'changed after startup')
        answer=pinned.dispatch({'operation':'rows','session':pinned.session,'database_sha256':pinned.digest,'selection':{'table':'parents'}})
        self.assertEqual(answer['rows'][0]['values'][0]['value'],'9007199254740993')
        self.assertEqual(self.archive.read_bytes(),before)
        with self.assertRaises(Exception): Workbench(str(copy),'review.sqlite')

if __name__=='__main__': unittest.main()
