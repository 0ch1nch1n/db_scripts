"""Offline tests. No database, network, or real Oracle executables are used."""
import csv
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('resource_report',ROOT/'report.py')
report=importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def write(path,data,fields=None):
    path.parent.mkdir(parents=True,exist_ok=True)
    report.write_csv(path,data,fields or tuple(data[0]))


def fixture(path,date='2026-11-03T12:00:00Z',waste='200',pct='40'):
    path.mkdir(parents=True,exist_ok=True)
    (path/'run_settings.csv').write_text('version,2.1\ncollected_at_utc,'+date+'\nthreshold,90\nbasis,CURRENT\nwaste_mb,100\nwaste_pct,30\nexpiry_days,30\n')
    write(path/'execution_status.csv',[dict(database='TEST',module=m,sid='GOOD',status='SUCCESS',detail='completed') for m in report.MODULES])
    (path/'functional_accounts.csv').write_text('database,username,expected_status,expiry_warning_days\n')
    data={
        'metadata':[dict(dbid='11',db_unique_name='DBPROD',container_name='PDB1',container_dbid='22',database_role='PRIMARY')],
        'tablespace':[dict(tablespace_name='USERS',tablespace_type='PERMANENT',review_status='OK')],
        'undo':[dict(inst_id='1',review_status='OK',undo_scope='LOCAL_CONTAINER')],
        'table_stats':[dict(owner='APP',table_name='',partition_name='',subpartition_name='',object_type='TABLE',record_type='SUMMARY',object_count='1000',review_status='OK',last_analyzed='',stale_stats='',stattype_locked='',scope='')],
        'index_stats':[dict(owner='APP',index_name='',partition_name='',subpartition_name='',object_type='INDEX',record_type='SUMMARY',object_count='2000',review_status='OK',last_analyzed='',stale_stats='',stattype_locked='',scope='',index_status='')],
        'table_waste':[dict(owner='APP',table_name='T1',method_status='ESTIMATED',record_type='DETAIL',object_count='1',last_analyzed='2026-10-01 00:00:00',segment_mb='500',estimated_waste_mb=waste,estimated_unused_pct=pct,stale_stats='NO',object_id='100',data_object_id='100',last_ddl_time='2026-09-01 00:00:00')],
        'user_accounts':[dict(username='SERVICE',account_status='OPEN',expiry_days_remaining='20',authentication_type='PASSWORD')],
    }
    for module,records in data.items():
        write(path/'TEST'/(module+'.csv'),records)
    return path


def update(path,module,**changes):
    p=path/'TEST'/(module+'.csv')
    data=report.rows(p)
    data[0].update(changes)
    write(p,data)


class Reports(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.now=fixture(self.root/'now')
        self.old=fixture(self.root/'old','2026-10-03T12:00:00Z','100','20')

    def tearDown(self):
        self.temp.cleanup()

    def test_compact_normal_counts_and_no_history(self):
        report.generate(self.now)
        summary={r['category']:r for r in report.rows(self.now/'monthly_summary.csv')}
        self.assertEqual(summary['TABLE_AND_INDEX_STATISTICS']['checked_count'],'3000')
        self.assertEqual(summary['TABLE_AND_INDEX_STATISTICS']['result'],'OK')
        self.assertEqual(summary['SPACE_WASTE_CANDIDATES']['result'],'REVIEW')
        self.assertEqual(summary['FUNCTIONAL_ACCOUNT_VALIDITY']['result'],'REVIEW')
        self.assertEqual(report.rows(self.now/'statistics_review.csv'),[])
        for name in ('table_space_changes.csv','index_space_changes.csv'):
            self.assertFalse((self.now/name).exists())

    def test_statistics_anomalies_preserve_identity_and_counts(self):
        data=report.rows(self.now/'TEST'/'table_stats.csv')
        data.append(dict(data[0],record_type='DETAIL',object_count='1',table_name='T_STALE',
                         last_analyzed='2026-01-01',stale_stats='YES',stattype_locked='ALL',review_status='STALE_STATS'))
        write(self.now/'TEST'/'table_stats.csv',data)
        report.generate(self.now)
        row=report.rows(self.now/'statistics_summary.csv')[0]
        self.assertEqual((row['checked_count'],row['review_count'],row['stale_count'],row['locked_count']),('1001','1','1','1'))
        self.assertEqual(report.rows(self.now/'statistics_review.csv')[0]['object_name'],'T_STALE')
        self.assertEqual(report.rows(self.now/'monthly_summary.csv')[1]['issue_count'],'1')

    def test_skipped_space_coverage_does_not_claim_ok(self):
        write(self.now/'TEST'/'table_waste.csv',[
            dict(owner='APP',record_type='SUMMARY',object_count='200',table_name='',
                 method_status='UNSUPPORTED_PARTITIONED',segment_mb='',estimated_waste_mb='',
                 estimated_unused_pct='',last_analyzed='',stale_stats='')])
        report.generate(self.now)
        row=report.rows(self.now/'monthly_summary.csv')[2]
        self.assertEqual((row['result'],row['checked_count'],row['issue_count']),('REVIEW','0','0'))
        self.assertIn('skipped tables=200',row['remarks'])
        self.assertEqual(report.rows(self.now/'table_waste_candidates.csv'),[])
        self.assertEqual(report.rows(self.now/'table_waste_summary.csv')[0]['object_count'],'200')

    def test_no_space_candidate_has_scoped_ok(self):
        update(self.now,'table_waste',record_type='SUMMARY',object_count='700',table_name='',
               segment_mb='',estimated_waste_mb='',estimated_unused_pct='',last_analyzed='',stale_stats='')
        report.generate(self.now)
        row=report.rows(self.now/'monthly_summary.csv')[2]
        self.assertEqual((row['result'],row['checked_count']),('OK','700'))

    def test_unreliable_or_below_threshold_candidate_fails_validation(self):
        for changes in (dict(stale_stats='YES'),dict(estimated_waste_mb='100'),dict(estimated_unused_pct='30'),dict(method_status='UNSUPPORTED_PARTITIONED')):
            with self.subTest(changes=changes):
                fixture(self.now)
                update(self.now,'table_waste',**changes)
                run=report.generate(self.now)
                self.assertIsNone(run.get('TEST','table_waste'))
                self.assertEqual(report.rows(self.now/'monthly_summary.csv')[2]['result'],'FAILED')

    def test_unusable_index_is_in_statistics_review(self):
        update(self.now,'index_stats',record_type='DETAIL',object_count='1',index_name='I_BROKEN',
               last_analyzed='2026-01-01',stale_stats='NO',review_status='INDEX_UNUSABLE',index_status='UNUSABLE')
        report.generate(self.now)
        rows=report.rows(self.now/'statistics_summary.csv')
        self.assertEqual(next(r for r in rows if r['module']=='index_stats')['unusable_count'],'1')
        self.assertEqual(report.rows(self.now/'statistics_review.csv')[0]['index_status'],'UNUSABLE')

    def test_empty_scope_is_review(self):
        for module in ('table_stats','index_stats','table_waste'):
            write(self.now/'TEST'/(module+'.csv'),[],tuple(report.REQUIRED[module]))
        report.generate(self.now)
        summary=report.rows(self.now/'monthly_summary.csv')
        self.assertEqual(summary[1]['result'],'REVIEW')
        self.assertEqual(summary[2]['result'],'REVIEW')

    def test_old_run_format_rejected(self):
        p=self.now/'run_settings.csv'
        p.write_text(p.read_text().replace('version,2.1','version,2.0'))
        with self.assertRaisesRegex(ValueError,'v2.1'):
            report.generate(self.now)

    def test_invalid_compact_counts_or_hidden_anomaly_rejected(self):
        for changes in (dict(object_count='0'),dict(object_count='1.5'),dict(object_count='NaN'),dict(stattype_locked='ALL'),dict(record_type='OTHER')):
            with self.subTest(changes=changes):
                fixture(self.now)
                update(self.now,'table_stats',**changes)
                run=report.generate(self.now)
                self.assertIsNone(run.get('TEST','table_stats'))

    def test_duplicate_compact_record_rejected(self):
        p=self.now/'TEST'/'table_stats.csv'
        data=report.rows(p)
        write(p,data+data)
        run=report.generate(self.now)
        self.assertIsNone(run.get('TEST','table_stats'))

    def test_expected_locked_account_and_expiring_service(self):
        (self.now/'functional_accounts.csv').write_text('database,username,expected_status,expiry_warning_days\nTEST,SERVICE,OPEN,30\nTEST,ARCHIVE,LOCKED,30\nTEST,MISSING,OPEN,30\n')
        data=report.rows(self.now/'TEST'/'user_accounts.csv')
        data.append(dict(username='ARCHIVE',account_status='LOCKED',expiry_days_remaining='',authentication_type='PASSWORD'))
        write(self.now/'TEST'/'user_accounts.csv',data)
        report.generate(self.now)
        result={r['username']:r['review_status'] for r in report.rows(self.now/'account_review.csv')}
        self.assertEqual(result,{'ARCHIVE':'OK_EXPECTED_STATUS','MISSING':'EXPECTED_ACCOUNT_NOT_FOUND','SERVICE':'EXPIRING_SOON'})

    def test_failed_module_not_marked_ok(self):
        p=self.now/'execution_status.csv'
        data=report.rows(p)
        for r in data:
            if r['module']=='index_stats': r['status']='FAILED'
        write(p,data)
        run=report.generate(self.now)
        self.assertIsNone(run.get('TEST','index_stats'))
        self.assertEqual(report.rows(self.now/'monthly_summary.csv')[1]['result'],'FAILED')

    def test_bad_csv_is_failure(self):
        (self.now/'TEST'/'table_stats.csv').write_text('ORA-00942: missing view\n')
        run=report.generate(self.now)
        self.assertEqual(len(run.errors),1)
        self.assertEqual(report.rows(self.now/'monthly_summary.csv')[1]['execution_status'],'FAILED')

    def test_locked_statistics_are_reviewed(self):
        update(self.now,'table_stats',record_type='DETAIL',object_count='1',table_name='T_LOCK',
               last_analyzed='2026-01-01',stale_stats='NO',stattype_locked='ALL')
        report.generate(self.now)
        row=report.rows(self.now/'monthly_summary.csv')[1]
        self.assertEqual((row['result'],row['issue_count']),('REVIEW','1'))

    def test_candidate_csv_escaping(self):
        update(self.now,'table_waste',table_name='T,comma"quote')
        report.generate(self.now)
        self.assertEqual(report.rows(self.now/'table_waste_candidates.csv')[0]['table_name'],'T,comma"quote')



class Collector(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.fixture=fixture(self.root/'fixture')
        self.bin=self.root/'bin';self.bin.mkdir()
        (self.bin/'oraenv').write_text('#!/usr/bin/env bash\nreturn 0\n')
        fake='''#!/usr/bin/env python3
import os,sys
from pathlib import Path
module=Path(next(a[1:] for a in sys.argv if a.startswith('@'))).stem
assert len(sys.argv)==15, sys.argv
if module=='table_waste':
    assert sys.argv[-2:]==[os.environ.get('EXPECTED_WASTE_MB','100'),os.environ.get('EXPECTED_WASTE_PCT','30')],sys.argv
if module==os.environ.get('FAKE_FAIL_MODULE'):
    sys.exit(1)  # Deliberately silent nonzero return: must not be treated as success.
if module==os.environ.get('FAKE_STDERR_MODULE'):
    print('SP2-0310: simulated stderr error',file=sys.stderr)
    sys.exit(0)
if os.environ.get('ORACLE_SID')=='BAD':
    print('SP2-0310: simulated SQLPlus include failure')
    sys.exit(0)  # Deliberately zero return: must still be detected.
sys.stdout.write((Path(os.environ['FAKE_FIXTURE'])/'TEST'/(module+'.csv')).read_text(encoding='utf-8-sig'))
'''
        (self.bin/'sqlplus').write_text(fake)
        for p in self.bin.iterdir(): p.chmod(0o755)
        self.conf=self.root/'db_list.conf'
        self.conf.write_text('TEST|BAD/GOOD|DB|PDB1|DBPROD\n')
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],FAKE_FIXTURE=str(self.fixture))

    def tearDown(self): self.temp.cleanup()

    def invoke(self,extra=()):
        cmd=['bash',str(ROOT/'check_resources.sh'),'--db-list',str(self.conf),'--accounts',str(self.fixture/'functional_accounts.csv'),'--output',str(self.root/'output')]+list(extra)
        return subprocess.run(cmd,env=self.env,capture_output=True,text=True)

    def test_sp2_retry_and_successful_complete_report(self):
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        run=next((self.root/'output').glob('run_*'))
        status=report.rows(run/'execution_status.csv')
        self.assertEqual(sum(r['status']=='SUCCESS' for r in status),7)
        self.assertEqual(sum(r['status']=='ATTEMPT_FAILED' for r in status),7)
        self.assertEqual(len(report.rows(run/'monthly_summary.csv')),4)
        self.assertFalse(list(run.rglob('*.tmp')))
        self.assertNotIn('index_space',{r['module'] for r in status})

    def test_waste_thresholds_forwarded_to_sql(self):
        self.env.update(EXPECTED_WASTE_MB='123.5',EXPECTED_WASTE_PCT='35')
        result=self.invoke(('--waste-mb','123.5','--waste-pct','35'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        run=next((self.root/'output').glob('run_*'))
        args=report.rows(run/'TEST'/'table_waste.csv')
        self.assertEqual(len(args),1)
        # The fake executable asserts argv[-2:] below, so this checks collector wiring.

    def test_baseline_flag_rejected_before_collection(self):
        result=self.invoke(('--baseline',str(self.root)))
        self.assertEqual(result.returncode,2)
        self.assertFalse((self.root/'output').exists())

    def test_silent_nonzero_exit_and_other_modules_continue(self):
        self.env['FAKE_FAIL_MODULE']='index_stats'
        result=self.invoke()
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        run=next((self.root/'output').glob('run_*'))
        self.assertFalse((run/'TEST'/'index_stats.csv').exists())
        self.assertTrue((run/'TEST'/'user_accounts.csv').exists())
        self.assertEqual(report.rows(run/'monthly_summary.csv')[1]['result'],'FAILED')

    def test_collect_only_never_runs_report(self):
        result=self.invoke(('--collect-only',))
        self.assertEqual(result.returncode,0,result.stderr)
        run=next((self.root/'output').glob('run_*'))
        self.assertFalse((run/'monthly_summary.csv').exists())

    def test_stderr_error_with_zero_exit_is_failure(self):
        self.env['FAKE_STDERR_MODULE']='user_accounts'
        result=self.invoke()
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        run=next((self.root/'output').glob('run_*'))
        self.assertEqual(report.rows(run/'monthly_summary.csv')[3]['result'],'FAILED')

    def test_relative_output_directory(self):
        relative=os.path.relpath(self.root/'relative_output',Path.cwd())
        result=self.invoke(('--output',relative))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(len(list((self.root/'relative_output').glob('run_*/monthly_summary.csv'))),1)

    def test_config_injection_and_duplicate_label_rejected_before_collection(self):
        for text in ('TEST|GOOD|DB|PDB1;evil\n','TEST|GOOD|DB|\nTEST|GOOD|DB|\n'):
            self.conf.write_text(text)
            result=self.invoke()
            self.assertEqual(result.returncode,2)
            self.assertFalse((self.root/'output').exists())


if __name__=='__main__': unittest.main()
