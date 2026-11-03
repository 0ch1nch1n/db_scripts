"""Execute the shipped compact SQL against SQLite dictionary fixtures.

Small Oracle scalar functions are adapted; this verifies grouping/filtering and
CSV/report integration, not Oracle view availability or SQL*Plus compilation.
"""
import math
import sqlite3
import tempfile
from pathlib import Path
import unittest

from test_workflow import ROOT, fixture, report, write


class CompactSQL(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:')
        self.db.row_factory=sqlite3.Row
        self.db.create_function('NVL',2,lambda a,b: b if a is None else a)
        self.db.create_function('TO_CHAR',2,lambda value,fmt: value)
        self.db.create_function('CEIL',1,lambda n: None if n is None else math.ceil(n))
        self.db.create_function('POWER',2,lambda a,b: float(a)**b)
        self.db.create_function('GREATEST',2,lambda a,b: None if a is None or b is None else max(a,b))
        self.db.executescript('''
CREATE TABLE dba_users(username TEXT,oracle_maintained TEXT);
CREATE TABLE dba_tables(owner TEXT,table_name TEXT,tablespace_name TEXT,partitioned TEXT,
    temporary TEXT,external TEXT,secondary TEXT,nested TEXT,iot_type TEXT,cluster_name TEXT,
    compression TEXT,segment_created TEXT,num_rows INTEGER,avg_row_len INTEGER,pct_free INTEGER);
CREATE TABLE dba_tab_statistics(owner TEXT,table_name TEXT,object_type TEXT,partition_name TEXT,
    subpartition_name TEXT,last_analyzed TEXT,stale_stats TEXT,stattype_locked TEXT,scope TEXT);
CREATE TABLE dba_tablespaces(tablespace_name TEXT,block_size INTEGER);
CREATE TABLE dba_segments(owner TEXT,segment_name TEXT,segment_type TEXT,blocks INTEGER,bytes INTEGER);
CREATE TABLE dba_indexes(owner TEXT,index_name TEXT,index_type TEXT,status TEXT);
CREATE TABLE dba_ind_statistics(owner TEXT,index_name TEXT,table_owner TEXT,table_name TEXT,
    object_type TEXT,partition_name TEXT,subpartition_name TEXT,last_analyzed TEXT,stale_stats TEXT,stattype_locked TEXT,scope TEXT);
CREATE TABLE dba_ind_partitions(index_owner TEXT,index_name TEXT,partition_name TEXT,status TEXT);
CREATE TABLE dba_ind_subpartitions(index_owner TEXT,index_name TEXT,subpartition_name TEXT,status TEXT);
''')
        self.insert('dba_users',username='APP',oracle_maintained='N')
        self.insert('dba_users',username='SYS',oracle_maintained='Y')
        self.insert('dba_tablespaces',tablespace_name='USERS',block_size=8192)

    def tearDown(self):
        self.db.close()

    def insert(self,table,**row):
        cols=','.join('"'+key+'"' for key in row)
        self.db.execute('INSERT INTO '+table+' ('+cols+') VALUES ('+','.join('?' for _ in row)+')',list(row.values()))

    def table(self,name,stats=None,segment=True,blocks=65536,**changes):
        row=dict(owner='APP',table_name=name,tablespace_name='USERS',partitioned='NO',temporary='N',
                 external='NO',secondary='N',nested='NO',iot_type=None,cluster_name=None,
                 compression='DISABLED',segment_created='YES',num_rows=10000,avg_row_len=100,pct_free=10)
        row.update(changes)
        self.insert('dba_tables',**row)
        st=dict(owner=row['owner'],table_name=name,object_type='TABLE',partition_name=None,
                subpartition_name=None,last_analyzed='2026-10-01 00:00:00',stale_stats='NO',stattype_locked=None,scope='SHARED')
        st.update(stats or {})
        self.insert('dba_tab_statistics',**st)
        if segment:
            self.insert('dba_segments',owner=row['owner'],segment_name=name,segment_type='TABLE',blocks=blocks,bytes=blocks*8192)

    def query(self,module,waste_mb=100,waste_pct=30):
        source=(ROOT/'sql'/(module+'.sql')).read_text()
        query=source[source.index('WITH '):source.index(';\nexit success')]
        query=query.replace('&db_label','TEST').replace('&waste_mb',str(waste_mb)).replace('&waste_pct',str(waste_pct))
        result=[]
        for record in self.db.execute(query):
            result.append({key: '' if value is None else str(value) for key,value in dict(record).items()})
        return result

    def test_thousand_healthy_tables_compact_to_one_count(self):
        for n in range(1000):
            self.table('T'+str(n),segment=False)
        self.table('SYSTEM_TABLE',owner='SYS')
        rows=self.query('table_stats')
        self.assertEqual(len(rows),1)
        self.assertEqual((rows[0]['record_type'],rows[0]['object_count'],rows[0]['table_name']),('SUMMARY','1000',''))

    def test_missing_stale_unknown_locked_and_partitions_keep_detail(self):
        self.table('FRESH')
        self.table('MISSING',stats=dict(last_analyzed=None,stale_stats=None))
        self.table('STALE',stats=dict(stale_stats='YES'))
        self.table('UNKNOWN',stats=dict(stale_stats=None))
        self.table('LOCKED',stats=dict(stattype_locked='ALL'))
        self.table('PARTED',partitioned='YES')
        self.insert('dba_tab_statistics',owner='APP',table_name='PARTED',object_type='PARTITION',partition_name='P1',
                    subpartition_name=None,last_analyzed=None,stale_stats=None,stattype_locked=None,scope='SHARED')
        rows=self.query('table_stats')
        details=[r for r in rows if r['record_type']=='DETAIL']
        self.assertEqual({r['table_name'] for r in details},{'MISSING','STALE','UNKNOWN','LOCKED','PARTED'})
        self.assertEqual(sum(int(r['object_count']) for r in rows),7)
        self.assertTrue(any(r['partition_name']=='P1' for r in details))

    def test_temporary_scopes_keep_identity_without_double_counting_tables(self):
        self.table('GTT',temporary='Y')
        self.insert('dba_tab_statistics',owner='APP',table_name='GTT',object_type='TABLE',partition_name=None,
                    subpartition_name=None,last_analyzed='2026-10-01 00:00:00',stale_stats='NO',stattype_locked=None,scope='SESSION')
        stats=self.query('table_stats')
        self.assertEqual(len(stats),2)
        self.assertEqual({r['scope'] for r in stats},{'SHARED','SESSION'})
        self.assertTrue(all(r['object_count']=='1' for r in stats))
        space=self.query('table_waste')
        self.assertEqual(len(space),1)
        self.assertEqual(space[0]['object_count'],'1')

    def test_unusable_partition_and_subpartition_keep_status(self):
        for name,kind,part,sub,status in (
            ('I_OK','INDEX',None,None,'VALID'),
            ('I_BAD','INDEX',None,None,'UNUSABLE'),
            ('I_PART','PARTITION','P1',None,'UNUSABLE'),
            ('I_SUB','SUBPARTITION','P1','SP1','UNUSABLE')):
            self.insert('dba_indexes',owner='APP',index_name=name,index_type='NORMAL',status=status if kind=='INDEX' else 'N/A')
            self.insert('dba_ind_statistics',owner='APP',index_name=name,table_owner='APP',table_name='T',object_type=kind,
                        partition_name=part,subpartition_name=sub,last_analyzed='2026-10-01',stale_stats='NO',stattype_locked=None,scope='SHARED')
            if kind=='PARTITION':
                self.insert('dba_ind_partitions',index_owner='APP',index_name=name,partition_name=part,status=status)
            if kind=='SUBPARTITION':
                self.insert('dba_ind_subpartitions',index_owner='APP',index_name=name,subpartition_name=sub,status=status)
        details=[r for r in self.query('index_stats') if r['record_type']=='DETAIL']
        self.assertEqual({r['index_name'] for r in details},{'I_BAD','I_PART','I_SUB'})
        self.assertTrue(all(r['index_status']=='UNUSABLE' for r in details))

    def test_space_only_fresh_supported_heap_candidates(self):
        self.table('CANDIDATE')
        self.table('STALE',stats=dict(stale_stats='YES'))
        self.table('UNKNOWN',stats=dict(stale_stats=None))
        self.table('COMPRESSED',compression='ENABLED')
        self.table('PARTED',partitioned='YES')
        self.table('TEMPORARY',temporary='Y')
        self.table('NO_SEGMENT',segment=False)
        self.table('SMALL',blocks=128)
        self.table('NO_INPUT',num_rows=None)
        rows=self.query('table_waste')
        self.assertEqual([r['table_name'] for r in rows if r['record_type']=='DETAIL'],['CANDIDATE'])
        self.assertEqual(sum(int(r['object_count']) for r in rows),9)
        counts={r['method_status']:int(r['object_count']) for r in rows if r['record_type']=='SUMMARY'}
        self.assertEqual(counts['UNRELIABLE_STATS'],2)
        self.assertEqual(counts['NO_TABLE_SEGMENT'],1)
        self.assertEqual(counts['ESTIMATED'],1)

    def test_both_thresholds_are_strict_in_actual_sql(self):
        self.table('CANDIDATE')
        row=self.query('table_waste')[0]
        for mb,pct in ((row['estimated_waste_mb'],0),(0,row['estimated_unused_pct'])):
            with self.subTest(mb=mb,pct=pct):
                rows=self.query('table_waste',mb,pct)
                self.assertEqual(rows[0]['record_type'],'SUMMARY')
                self.assertEqual(rows[0]['table_name'],'')

    def test_shipped_sql_output_integrates_with_report(self):
        self.table('CANDIDATE')
        self.table('LOCKED',stats=dict(stattype_locked='ALL'))
        self.table('STALE',stats=dict(stale_stats='YES'))
        with tempfile.TemporaryDirectory() as tmp:
            run=fixture(Path(tmp)/'run')
            for module in ('table_stats','index_stats','table_waste'):
                data=self.query(module)
                write(run/'TEST'/(module+'.csv'),data,tuple(data[0]) if data else sorted(report.REQUIRED[module]))
            current=report.generate(run)
            self.assertEqual(current.errors,[])
            stats=report.rows(run/'statistics_summary.csv')[0]
            self.assertEqual((stats['checked_count'],stats['review_count'],stats['locked_count'],stats['stale_count']),('3','2','1','1'))
            self.assertEqual({r['table_name'] for r in report.rows(run/'table_waste_candidates.csv')},{'CANDIDATE','LOCKED'})
            self.assertEqual(report.rows(run/'monthly_summary.csv')[2]['checked_count'],'2')


if __name__=='__main__':
    unittest.main()
