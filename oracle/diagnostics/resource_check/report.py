#!/usr/bin/env python3
"""Oracle resource check v2 reports. Python 3.8+, standard library only.

Reads collected CSVs, never connects to Oracle. Baselines are explicit and never
advanced automatically. All conclusions describe collection-time observations.
"""
import argparse
import csv
import sys
from collections import Counter
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

MODULES = ('metadata', 'tablespace', 'undo', 'table_stats', 'index_stats',
           'table_waste', 'index_space', 'user_accounts')
REQUIRED = {
    'metadata': {'dbid', 'db_unique_name', 'container_name', 'container_dbid', 'database_role'},
    'tablespace': {'tablespace_name', 'tablespace_type', 'review_status'},
    'undo': {'inst_id', 'review_status', 'undo_scope'},
    'table_stats': {'owner', 'table_name', 'review_status', 'last_analyzed', 'stale_stats'},
    'index_stats': {'owner', 'index_name', 'review_status', 'last_analyzed', 'stale_stats'},
    'table_waste': {'owner', 'table_name', 'method_status', 'segment_mb', 'estimated_waste_mb',
                    'estimated_unused_pct', 'stale_stats', 'object_id', 'data_object_id', 'last_ddl_time'},
    'index_space': {'owner', 'index_name', 'partition_name', 'segment_type', 'segment_mb',
                    'stale_stats', 'object_id', 'data_object_id', 'last_ddl_time', 'index_status'},
    'user_accounts': {'username', 'account_status', 'expiry_days_remaining', 'authentication_type'},
}


def rows(path, required=()):
    """Parse SQL*Plus MARKUP CSV, allowing blank records but no malformed widths."""
    with Path(path).open(encoding='utf-8-sig', newline='') as handle:
        records = [r for r in csv.reader(handle) if r and any(v.strip() for v in r)]
    if not records:
        return []  # SQL*Plus may emit no heading for an empty result set.
    header = [v.strip().lower() for v in records[0]]
    if len(set(header)) != len(header) or not set(required).issubset(header):
        raise ValueError('Invalid/missing CSV header: {}'.format(path))
    result = []
    for record in records[1:]:
        if len(record) != len(header):
            raise ValueError('Malformed CSV record: {}'.format(path))
        result.append(dict(zip(header, record)))
    return result


def write_csv(path, data, fields):
    # UTF-8 BOM permits opening the summary directly in Excel.
    with Path(path).open('w', encoding='utf-8-sig', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(data)


def number(value):
    if value is None or value == '':
        return None
    try:
        result = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError('Invalid numeric field: {!r}'.format(value)) from exc
    if not result.is_finite():
        raise ValueError('Non-finite numeric field')
    return result


def fmt(value):
    return '' if value is None else str(value)


def settings(run):
    with (run / 'run_settings.csv').open(encoding='utf-8-sig', newline='') as handle:
        data = dict(csv.reader(handle))
    if data.get('version') != '2.0':
        raise ValueError('Only v2.0 run directories are supported')
    datetime.strptime(data['collected_at_utc'], '%Y-%m-%dT%H:%M:%SZ')
    for key in ('threshold', 'waste_mb', 'waste_pct', 'expiry_days'):
        value = number(data[key])
        if value is None or value < 0:
            raise ValueError('Invalid setting: ' + key)
    return data


class Run:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.settings = settings(self.root)
        self.execution = rows(self.root / 'execution_status.csv', {'database', 'module', 'status'})
        self.databases = sorted({r['database'] for r in self.execution})
        if not self.databases:
            raise ValueError('No database execution records')
        self.data = {}
        self.errors = []
        for db in self.databases:
            if not db or Path(db).name != db or db in ('.', '..'):
                raise ValueError('Unsafe database label in execution CSV')
            for module in MODULES:
                attempts = [r for r in self.execution if r['database'] == db and r['module'] == module]
                if not attempts or attempts[-1]['status'] != 'SUCCESS':
                    self.data[db, module] = None
                    continue
                try:
                    data = rows(self.root / db / (module + '.csv'), REQUIRED[module])
                    if module == 'metadata' and len(data) != 1:
                        raise ValueError('Metadata must contain exactly one row')
                    # Normalize numeric errors into a module failure, not a misleading OK.
                    numeric_fields = {
                        'table_waste': ('segment_mb','estimated_waste_mb','estimated_unused_pct'),
                        'index_space': ('segment_mb','blevel','leaf_blocks','num_rows'),
                        'user_accounts': ('expiry_days_remaining',),
                    }.get(module, ())
                    for row in data:
                        if row.get('database_label') not in (None, db):
                            raise ValueError('Database label mismatch')
                        for field in numeric_fields:
                            number(row.get(field))
                    self.data[db, module] = data
                except (ValueError, OSError, UnicodeError, csv.Error) as exc:
                    self.data[db, module] = None
                    self.errors.append({'database': db, 'module': module, 'error': str(exc)})

    def get(self, db, module):
        return self.data.get((db, module))


def same_database(current, baseline, db):
    a, b = current.get(db, 'metadata'), baseline.get(db, 'metadata')
    if not a or not b:
        return False
    # Stable identity excludes the RAC instance and host, which may legitimately change.
    fields = ('dbid', 'db_unique_name', 'container_name', 'container_dbid')
    return all(a[0].get(k) and a[0][k] == b[0].get(k) for k in fields)


def key_for(module, row):
    if module == 'table_waste':
        return row['owner'], row['table_name']
    return row['owner'], row['index_name'], row['segment_type'], row['partition_name']


def unique_map(module, data):
    result = {}
    for row in data:
        key = key_for(module, row)
        if key in result:
            raise ValueError('Duplicate object key in {}: {}'.format(module, key))
        result[key] = row
    return result


def object_changed(a, b):
    return any(not a.get(k) or not b.get(k) or a[k] != b[k]
               for k in ('object_id', 'data_object_id', 'last_ddl_time'))


def trends(current, baseline, db, module):
    data = current.get(db, module)
    if data is None:
        return []
    identity_ok = baseline is not None and same_database(current, baseline, db)
    previous = baseline.get(db, module) if identity_ok else None
    old = unique_map(module, previous or [])
    now = unique_map(module, data)
    output = []
    for key, row in now.items():
        prior = old.get(key)
        result = {
            'database': db, 'owner': row['owner'],
            'current_collected_at_utc':current.settings['collected_at_utc'],
            'baseline_collected_at_utc':baseline.settings['collected_at_utc'] if baseline else '',
            'object_name': row.get('table_name') if module == 'table_waste' else row['index_name'],
            'segment_type': 'TABLE' if module == 'table_waste' else row['segment_type'],
            'partition_name': row.get('partition_name',''),
            'current_segment_mb': row.get('segment_mb',''),
            'previous_segment_mb': prior.get('segment_mb','') if prior else '',
        }
        if baseline is None:
            state = 'NO_BASELINE'
        elif not identity_ok:
            state = 'DATABASE_IDENTITY_UNVERIFIED_OR_CHANGED'
        elif previous is None:
            state = 'BASELINE_COLLECTION_FAILED'
        elif prior is None:
            state = 'NEW_OR_NEWLY_IN_SCOPE'
        elif module == 'table_waste' and (row['method_status'] != 'ESTIMATED' or prior['method_status'] != 'ESTIMATED'):
            state = 'NOT_ESTIMATED'
        elif object_changed(row, prior):
            state = 'OBJECT_CHANGED_REVIEW'
        elif row['stale_stats'] != 'NO' or prior['stale_stats'] != 'NO':
            state = 'UNRELIABLE_STATS'
        elif module=='index_space' and any(number(source.get(field)) is None
                for source in (row,prior) for field in ('blevel','leaf_blocks','num_rows')):
            state = 'MISSING_STRUCTURE_STATS'
        else:
            a, b = number(row.get('segment_mb')), number(prior.get('segment_mb'))
            result['delta_segment_mb'] = fmt(a-b) if a is not None and b is not None else ''
            if module == 'table_waste':
                fields = ('estimated_waste_mb','estimated_unused_pct')
                values = [number(source.get(f)) for f in fields for source in (row, prior)]
                if any(v is None for v in values):
                    state = 'MISSING_ESTIMATE'
                else:
                    waste_delta, pct_delta = values[0]-values[1], values[2]-values[3]
                    result.update(delta_estimated_waste_mb=fmt(waste_delta), delta_unused_pct_points=fmt(pct_delta))
                    state = 'ESTIMATE_INCREASED_REVIEW' if waste_delta>0 or pct_delta>0 else 'NO_ESTIMATED_INCREASE'
            else:
                changed = False
                for field in ('blevel','leaf_blocks','num_rows'):
                    a,b=number(row.get(field)),number(prior.get(field))
                    result['delta_'+field]=fmt(a-b) if a is not None and b is not None else ''
                    changed = changed or (a is not None and b is not None and a != b)
                delta_size=number(result['delta_segment_mb'])
                state = 'STRUCTURE_OR_SIZE_CHANGED_REVIEW' if changed or (delta_size is not None and delta_size!=0) else 'NO_STRUCTURAL_CHANGE_OBSERVED'
        result['comparison_status'] = state
        output.append(result)
    for key, row in old.items():
        if key not in now:
            output.append({'database': db, 'owner': row['owner'],
                           'current_collected_at_utc':current.settings['collected_at_utc'],
                           'baseline_collected_at_utc':baseline.settings['collected_at_utc'],
                           'object_name': row['table_name'] if module=='table_waste' else row['index_name'],
                           'segment_type': 'TABLE' if module=='table_waste' else row['segment_type'],
                           'partition_name': row.get('partition_name',''),
                           'previous_segment_mb':row.get('segment_mb',''),
                           'comparison_status':'REMOVED_OR_OUT_OF_SCOPE'})
    return output


def account_rules(path, databases):
    rules = {}
    warnings = []
    for row in rows(path, {'database','username','expected_status','expiry_warning_days'}):
        db, user = row['database'].strip(), row['username'].strip()
        if db not in databases or not user or not row['expected_status'].strip():
            raise ValueError('Invalid functional account rule: {!r}'.format(row))
        key = db,user
        if key in rules:
            raise ValueError('Duplicate functional account rule: {}'.format(key))
        days = row['expiry_warning_days'].strip()
        if days and (not days.isascii() or not days.isdigit()):
            raise ValueError('expiry_warning_days must be a non-negative integer')
        row = dict(row)
        row['expected_status'] = row['expected_status'].strip().upper()
        row['expiry_warning_days'] = days
        rules[key] = row
    return rules, warnings


def account_report(current, db, rules):
    data = current.get(db,'user_accounts')
    if data is None:
        return []
    lookup = {}
    for row in data:
        if row['username'] in lookup:
            raise ValueError('Duplicate username: '+row['username'])
        lookup[row['username']] = row
    output = []
    # Include every collected account; only explicitly scoped accounts affect validity summary.
    names = sorted(set(lookup) | {user for database,user in rules if database==db})
    for user in names:
        row = dict(lookup.get(user, {'username':user}))
        rule = rules.get((db,user))
        row.update(database=db, functional_account='YES' if rule else 'UNCLASSIFIED',
                   expected_status=rule['expected_status'] if rule else '')
        if not rule:
            state = 'UNCLASSIFIED'
        elif user not in lookup:
            state = 'EXPECTED_ACCOUNT_NOT_FOUND'
        elif row['account_status'] != rule['expected_status']:
            state = 'UNEXPECTED_STATUS'
        elif rule['expected_status'] != 'OPEN':
            state = 'OK_EXPECTED_STATUS'
        elif row['authentication_type'] not in ('PASSWORD',):
            state = 'AUTHENTICATION_VALIDITY_REVIEW'
        else:
            days = number(row.get('expiry_days_remaining'))
            warn = number(rule['expiry_warning_days'] or current.settings['expiry_days'])
            if days is None:
                state = 'OK_NO_RECORDED_EXPIRY'
            elif days < 0:
                state = 'EXPIRY_DATE_PASSED'
            elif days <= warn:
                state = 'EXPIRING_SOON'
            else:
                state = 'OK'
        row['review_status'] = state
        output.append(row)
    return output


def summarize(current, baseline, db, accounts, table_trend, index_trend):
    result = []
    groups = (
        ('TABLESPACE', ('metadata','tablespace','undo')),
        ('TABLE_AND_INDEX_STATISTICS', ('metadata','table_stats','index_stats')),
        ('TABLE_AND_INDEX_FRAGMENTATION', ('metadata','table_waste','index_space')),
        ('FUNCTIONAL_ACCOUNT_VALIDITY', ('metadata','user_accounts')),
    )
    for category, modules in groups:
        failed = [m for m in modules if current.get(db,m) is None]
        item = dict(database=db, category=category, collected_at_utc=current.settings['collected_at_utc'],
                    execution_status='FAILED' if failed else 'SUCCESS',
                    result='FAILED' if failed else 'REVIEW', checked_count=0, issue_count=0,
                    evidence=';'.join(db+'/'+m+'.csv' for m in modules))
        if failed:
            item['remarks'] = 'Collection/CSV validation failed: '+','.join(failed)
        elif category == 'TABLESPACE':
            space,undo = current.get(db,'tablespace'),current.get(db,'undo')
            checks=[r['review_status'] for r in space if r['tablespace_type']!='UNDO']
            checks += [r['review_status'] for r in undo if r['review_status']!='PDB_NOT_OPEN']
            issues=sum(v!='OK' for v in checks)
            item.update(checked_count=len(checks),issue_count=issues,
                        result='ALERT' if 'ALERT' in checks else ('REVIEW' if issues or not space or not undo or not checks else 'OK'),
                        remarks='Strict > {}%, basis={}; UNDO retained space is reviewed separately; latest UNDO bucket only; configured maximum excludes storage availability; snapshot, not monthly peak.'.format(current.settings['threshold'], current.settings['basis']))
        elif category == 'TABLE_AND_INDEX_STATISTICS':
            data=current.get(db,'table_stats')+current.get(db,'index_stats')
            counts=Counter(r['review_status'] for r in data)
            issues=sum(r['review_status']!='OK' or bool(r.get('stattype_locked')) for r in data)
            item.update(checked_count=len(data),issue_count=issues,result='REVIEW' if issues or not data else 'OK',
                        remarks='Table/index and partition statistics; '+', '.join('{}={}'.format(k,v) for k,v in sorted(counts.items()))+'; old dates alone are not stale; locked stats require policy review.')
            if any(r.get('stattype_locked') for r in data):
                item['result']='REVIEW'
            if not data:
                item['remarks']+=' No eligible statistics records found; confirm application scope.'
        elif category == 'TABLE_AND_INDEX_FRAGMENTATION':
            table=current.get(db,'table_waste'); indexes=current.get(db,'index_space')
            comparable=sum(r['comparison_status'] in ('ESTIMATE_INCREASED_REVIEW','NO_ESTIMATED_INCREASE') for r in table_trend)
            increase=sum(r['comparison_status']=='ESTIMATE_INCREASED_REVIEW' for r in table_trend)
            unsupported=sum(r['method_status']!='ESTIMATED' for r in table)
            invalid=sum(r['index_status']=='UNUSABLE' for r in indexes)
            item.update(checked_count=len(table)+len(indexes),issue_count=increase+invalid,
                        result='NO_BASELINE' if baseline is None else 'REVIEW',
                        remarks='Estimated table waste only; comparable tables={}, increased estimates={}, unsupported tables={}, unusable index segments={}. Index metrics are structural trends, not measured fragmentation. No automatic Yes/No or rebuild recommendation.'.format(comparable,increase,unsupported,invalid))
        else:
            scoped=[r for r in accounts if r['functional_account']=='YES']
            issues=sum(not r['review_status'].startswith('OK') for r in scoped)
            item.update(checked_count=len(scoped),issue_count=issues,
                        result='REVIEW' if not scoped or issues else 'OK',
                        remarks='No functional account list configured for this database.' if not scoped else 'Explicit account list only; unclassified accounts excluded; database account metadata does not prove application login succeeds.')
        meta=current.get(db,'metadata')
        if meta and meta[0]['database_role']!='PRIMARY' and item['result'] not in ('FAILED','NO_BASELINE'):
            item['result']='REVIEW'
            item['remarks']+=' Database role is not PRIMARY.'
        result.append(item)
    return result


def generate(run_dir, baseline_dir=None):
    current=Run(run_dir)
    baseline=Run(baseline_dir) if baseline_dir else None
    if baseline:
        if current.root==baseline.root or baseline.settings['collected_at_utc']>=current.settings['collected_at_utc']:
            raise ValueError('Baseline must be a distinct earlier v2 run')
    rules,_=account_rules(current.root/'functional_accounts.csv',current.databases)
    all_accounts=[];table_trends=[];index_trends=[];candidates=[];summary=[];stats_summary=[]
    for db in current.databases:
        tt=trends(current,baseline,db,'table_waste')
        it=trends(current,baseline,db,'index_space')
        ar=account_report(current,db,rules)
        table_trends.extend(tt);index_trends.extend(it);all_accounts.extend(ar)
        summary.extend(summarize(current,baseline,db,ar,tt,it))
        for row in current.get(db,'table_waste') or []:
            waste,pct=number(row.get('estimated_waste_mb')),number(row.get('estimated_unused_pct'))
            if waste is not None and pct is not None and waste>number(current.settings['waste_mb']) and pct>number(current.settings['waste_pct']):
                copy=dict(row);copy['database']=db
                copy['review_status']='CANDIDATE_REVIEW' if row['stale_stats']=='NO' else 'REFRESH_STATS_REVIEW_FIRST'
                candidates.append(copy)
        for module in ('table_stats','index_stats'):
            counts=Counter((r['owner'],r.get('object_type',''),r['last_analyzed'][:7] or 'NEVER',r['review_status']) for r in (current.get(db,module) or []))
            for (owner,kind,month,status),count in sorted(counts.items()):
                stats_summary.append(dict(database=db,module=module,owner=owner,object_type=kind,last_analyzed_month=month,review_status=status,object_count=count))
    root=current.root
    write_csv(root/'monthly_summary.csv',summary,('database','category','collected_at_utc','execution_status','result','checked_count','issue_count','remarks','evidence'))
    write_csv(root/'table_waste_candidates.csv',candidates,('database','owner','table_name','tablespace_name','segment_mb','estimated_waste_mb','estimated_unused_pct','last_analyzed','stale_stats','review_status'))
    trend_fields=('database','owner','object_name','segment_type','partition_name','previous_segment_mb','current_segment_mb','delta_segment_mb','delta_estimated_waste_mb','delta_unused_pct_points','comparison_status')
    trend_times=('current_collected_at_utc','baseline_collected_at_utc')
    write_csv(root/'table_space_changes.csv',table_trends,trend_times+trend_fields)
    write_csv(root/'index_space_changes.csv',index_trends,trend_times+trend_fields[:8]+('delta_blevel','delta_leaf_blocks','delta_num_rows','comparison_status'))
    account_fields=('database','username','functional_account','expected_status','account_status','expiry_date','expiry_days_remaining','lock_date','profile','authentication_type','common','proxy_only_connect','last_login_utc','review_status')
    write_csv(root/'account_review.csv',all_accounts,account_fields)
    write_csv(root/'statistics_summary.csv',stats_summary,('database','module','owner','object_type','last_analyzed_month','review_status','object_count'))
    write_csv(root/'report_errors.csv',current.errors,('database','module','error'))
    lines=['# Oracle monthly resource check','', 'Collected at (UTC): '+current.settings['collected_at_utc'],
           'Baseline (UTC): '+(baseline.settings['collected_at_utc'] if baseline else 'None — first-run baseline only'),'',
           'Results describe the collection snapshot, not continuous coverage of the month.', '',
           '| Database | Check | Execution | Result | Checked | Issues |',
           '|---|---|---|---|---|---|']
    lines += ['| {database} | {category} | {execution_status} | {result} | {checked_count} | {issue_count} |'.format(**r) for r in summary]
    lines+=['','OK = no issue under the defined check; ALERT = threshold/event observed; REVIEW = policy, coverage or measurement needs review; NO_BASELINE = no comparison; FAILED = not checked successfully.',
            '', 'Fragmentation is not conclusively measured. No automatic maintenance actions are generated.',
            '', 'See monthly_summary.csv for remarks and evidence paths.']
    (root/'monthly_summary.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    return current


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir',type=Path)
    parser.add_argument('--baseline',type=Path)
    args=parser.parse_args()
    try:
        run=generate(args.run_dir,args.baseline)
    except (OSError,ValueError,KeyError,csv.Error,UnicodeError) as exc:
        print('Report failed: '+str(exc),file=sys.stderr)
        return 1
    print('Report saved: '+str(run.root/'monthly_summary.csv'))
    if run.errors or any(run.get(db,m) is None for db in run.databases for m in MODULES):
        return 1
    return 0


if __name__=='__main__':
    sys.exit(main())
