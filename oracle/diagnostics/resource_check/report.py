#!/usr/bin/env python3
"""Oracle resource check v2.1 compact reports. Python 3.8+, standard library only.

Reads compact collected CSVs, never connects to Oracle. Healthy statistics are
counts; only review items and table waste candidates retain object detail.
"""
import argparse
import csv
import sys
from collections import defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

MODULES = ('metadata', 'tablespace', 'undo', 'table_stats', 'index_stats',
           'table_waste', 'user_accounts')
REQUIRED = {
    'metadata': {'dbid', 'db_unique_name', 'container_name', 'container_dbid', 'database_role'},
    'tablespace': {'tablespace_name', 'tablespace_type', 'review_status'},
    'undo': {'inst_id', 'review_status', 'undo_scope'},
    'table_stats': {'owner','object_type','record_type','object_count','table_name',
                    'partition_name','subpartition_name','review_status','last_analyzed','stale_stats','stattype_locked','scope'},
    'index_stats': {'owner','object_type','record_type','object_count','index_name',
                    'partition_name','subpartition_name','review_status','last_analyzed','stale_stats','stattype_locked','scope','index_status'},
    'table_waste': {'owner','record_type','object_count','table_name','method_status',
                    'segment_mb','estimated_waste_mb','estimated_unused_pct','last_analyzed','stale_stats'},
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


def settings(run):
    with (run / 'run_settings.csv').open(encoding='utf-8-sig', newline='') as handle:
        data = dict(csv.reader(handle))
    if data.get('version') != '2.1':
        raise ValueError('Only v2.1 compact run directories are supported; use the v2.0 report for old runs')
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
                        'user_accounts': ('expiry_days_remaining',),
                    }.get(module, ())
                    for row in data:
                        if row.get('database_label') not in (None, db):
                            raise ValueError('Database label mismatch')
                        for field in numeric_fields:
                            number(row.get(field))
                    if module in ('table_stats','index_stats','table_waste'):
                        validate_compact(module, data, self.settings)
                    self.data[db, module] = data
                except (ValueError, OSError, UnicodeError, csv.Error) as exc:
                    self.data[db, module] = None
                    self.errors.append({'database': db, 'module': module, 'error': str(exc)})

    def get(self, db, module):
        return self.data.get((db, module))


def validate_compact(module, data, run_settings):
    """Reject inconsistent compact records rather than silently losing coverage."""
    seen = set()
    for row in data:
        count = number(row['object_count'])
        if count is None or count < 1 or count != count.to_integral_value():
            raise ValueError('object_count must be a positive integer')
        kind = row['record_type']
        if kind not in ('SUMMARY', 'DETAIL') or (kind == 'DETAIL' and count != 1):
            raise ValueError('Invalid compact record type/count')
        if not row['owner']:
            raise ValueError('Missing schema')
        name = row.get('index_name', row.get('table_name', ''))
        if (kind == 'SUMMARY' and name) or (kind == 'DETAIL' and not name):
            raise ValueError('Object identity does not match compact record type')
        if module == 'table_waste':
            method = row['method_status']
            if method not in ('ESTIMATED','UNSUPPORTED_PARTITIONED','UNSUPPORTED_TABLE_TYPE',
                              'UNSUPPORTED_COMPRESSED','NO_TABLE_SEGMENT','UNRELIABLE_STATS','MISSING_INPUT_STATS'):
                raise ValueError('Unknown space estimate coverage status')
            key = row['owner'], method, kind, name
            if kind == 'DETAIL':
                waste, pct, size = (number(row[f]) for f in
                                    ('estimated_waste_mb','estimated_unused_pct','segment_mb'))
                if (method != 'ESTIMATED' or row['stale_stats'] != 'NO' or not row['last_analyzed']
                        or waste is None or pct is None or size is None or size <= 0
                        or waste > size or pct > 100
                        or waste <= number(run_settings['waste_mb']) or pct <= number(run_settings['waste_pct'])):
                    raise ValueError('Unreliable or below-threshold table waste candidate')
        else:
            if not row['object_type'] or not row['review_status']:
                raise ValueError('Missing statistics object type/status')
            key = row['owner'], row['object_type'], kind, name, row['partition_name'], row['subpartition_name'], row['scope']
            if kind == 'SUMMARY' and (row['review_status'] != 'OK' or row['stattype_locked']):
                raise ValueError('Unhealthy statistics cannot be hidden in a summary')
            if kind == 'DETAIL' and row['review_status'] == 'OK' and not row['stattype_locked']:
                raise ValueError('Healthy statistics must be aggregated')
        if key in seen:
            raise ValueError('Duplicate compact record')
        seen.add(key)


def statistics_report(current, db):
    summaries = []
    details = []
    for module in ('table_stats', 'index_stats'):
        counts = defaultdict(lambda: dict(checked_count=0,review_count=0,missing_count=0,
                    stale_count=0,locked_count=0,unknown_count=0,unusable_count=0))
        for row in current.get(db, module) or []:
            item = counts[row['owner'], row['object_type']]
            item['checked_count'] += int(number(row['object_count']))
            if row['record_type'] == 'DETAIL':
                item['review_count'] += 1
                item['missing_count'] += not bool(row['last_analyzed'])
                item['stale_count'] += row['stale_stats'] == 'YES'
                item['locked_count'] += bool(row['stattype_locked'])
                item['unknown_count'] += row['stale_stats'] not in ('YES','NO')
                item['unusable_count'] += row.get('index_status') == 'UNUSABLE'
                details.append(dict(row, database=db, module=module,
                         object_name=row.get('index_name',row.get('table_name',''))))
        for (owner,kind),values in sorted(counts.items()):
            summaries.append(dict(database=db,module=module,owner=owner,object_type=kind,**values))
    return summaries, details


def space_report(current, db):
    counts = defaultdict(lambda: dict(object_count=0,candidate_count=0))
    candidates = []
    for row in current.get(db,'table_waste') or []:
        item = counts[row['owner'],row['method_status']]
        item['object_count'] += int(number(row['object_count']))
        if row['record_type'] == 'DETAIL':
            item['candidate_count'] += 1
            candidates.append(dict(row,database=db,review_status='CANDIDATE_REVIEW'))
    summary = [dict(database=db,owner=owner,method_status=method,**values)
               for (owner,method),values in sorted(counts.items())]
    return summary,candidates


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


def summarize(current, db, accounts):
    result = []
    groups = (
        ('TABLESPACE', ('metadata','tablespace','undo')),
        ('TABLE_AND_INDEX_STATISTICS', ('metadata','table_stats','index_stats')),
        ('SPACE_WASTE_CANDIDATES', ('metadata','table_waste')),
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
            checked=sum(int(number(r['object_count'])) for r in data)
            issues=sum(r['record_type']=='DETAIL' for r in data)
            item.update(checked_count=checked,issue_count=issues,result='REVIEW' if issues or not checked else 'OK',
                        remarks='Schema/type counts plus review items only; partitions count separately. Missing/stale/locked/unknown counts may overlap. UNUSABLE indexes are included. Old dates alone are not stale.')
        elif category == 'SPACE_WASTE_CANDIDATES':
            data=current.get(db,'table_waste')
            estimated=sum(int(number(r['object_count'])) for r in data if r['method_status']=='ESTIMATED')
            skipped=sum(int(number(r['object_count'])) for r in data if r['method_status']!='ESTIMATED')
            issues=sum(r['record_type']=='DETAIL' for r in data)
            item.update(checked_count=estimated,issue_count=issues,
                        result='REVIEW' if issues or skipped or not estimated else 'OK',
                        remarks='Reliable ordinary heap estimates only; candidates require > {} MB AND > {}%; skipped tables={}. See table_waste_summary.csv. Estimates are not measured fragmentation or reclaimable space. No history or index structure collection.'.format(current.settings['waste_mb'],current.settings['waste_pct'],skipped))
        else:
            scoped=[r for r in accounts if r['functional_account']=='YES']
            issues=sum(not r['review_status'].startswith('OK') for r in scoped)
            item.update(checked_count=len(scoped),issue_count=issues,
                        result='REVIEW' if not scoped or issues else 'OK',
                        remarks='No functional account list configured for this database.' if not scoped else 'Explicit account list only; unclassified accounts excluded; database account metadata does not prove application login succeeds.')
        meta=current.get(db,'metadata')
        if meta and meta[0]['database_role']!='PRIMARY' and item['result'] != 'FAILED':
            item['result']='REVIEW'
            item['remarks']+=' Database role is not PRIMARY.'
        result.append(item)
    return result


def generate(run_dir):
    current=Run(run_dir)
    rules,_=account_rules(current.root/'functional_accounts.csv',current.databases)
    all_accounts=[];candidates=[];summary=[];stats_summary=[];stats_details=[];space_summary=[]
    for db in current.databases:
        ar=account_report(current,db,rules)
        all_accounts.extend(ar)
        summary.extend(summarize(current,db,ar))
        totals,details=statistics_report(current,db)
        stats_summary.extend(totals);stats_details.extend(details)
        totals,details=space_report(current,db)
        space_summary.extend(totals);candidates.extend(details)
    root=current.root
    write_csv(root/'monthly_summary.csv',summary,('database','category','collected_at_utc','execution_status','result','checked_count','issue_count','remarks','evidence'))
    write_csv(root/'table_waste_candidates.csv',candidates,('database','owner','table_name','tablespace_name','segment_mb','estimated_waste_mb','estimated_unused_pct','last_analyzed','stale_stats','review_status'))
    write_csv(root/'table_waste_summary.csv',space_summary,('database','owner','method_status','object_count','candidate_count'))
    account_fields=('database','username','functional_account','expected_status','account_status','expiry_date','expiry_days_remaining','lock_date','profile','authentication_type','common','proxy_only_connect','last_login_utc','review_status')
    write_csv(root/'account_review.csv',all_accounts,account_fields)
    write_csv(root/'statistics_summary.csv',stats_summary,('database','module','owner','object_type','checked_count','review_count','missing_count','stale_count','locked_count','unknown_count','unusable_count'))
    write_csv(root/'statistics_review.csv',stats_details,('database','module','owner','object_type','object_name','partition_name','subpartition_name','last_analyzed','stale_stats','stattype_locked','scope','index_status','review_status'))
    write_csv(root/'report_errors.csv',current.errors,('database','module','error'))
    lines=['# Oracle monthly resource check v2.1','', 'Collected at (UTC): '+current.settings['collected_at_utc'],
           'Results describe a collection snapshot, not continuous coverage of the month.', '',
           '| Database | Check | Execution | Result | Checked | Issues |',
           '|---|---|---|---|---|---|']
    lines += ['| {database} | {category} | {execution_status} | {result} | {checked_count} | {issue_count} |'.format(**r) for r in summary]
    lines+=['','OK = no issue under the defined scope; ALERT = threshold/event observed; REVIEW = issue or incomplete coverage; FAILED = not checked successfully.',
            '', 'Space waste candidates are estimates, not confirmed fragmentation. No automatic maintenance actions are generated.',
            '', 'See monthly_summary.csv for coverage remarks and evidence paths.']
    (root/'monthly_summary.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    return current


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir',type=Path)
    args=parser.parse_args()
    try:
        run=generate(args.run_dir)
    except (OSError,ValueError,KeyError,csv.Error,UnicodeError) as exc:
        print('Report failed: '+str(exc),file=sys.stderr)
        return 1
    print('Report saved: '+str(run.root/'monthly_summary.csv'))
    if run.errors or any(run.get(db,m) is None for db in run.databases for m in MODULES):
        return 1
    return 0


if __name__=='__main__':
    sys.exit(main())
