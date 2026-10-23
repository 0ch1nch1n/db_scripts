import os
import pathlib
import subprocess
import tempfile

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'health_check_v3_1.sh'
CORE = '''HC|IDENTITY|DBID|12345
HC|IDENTITY|DB_NAME|ORCL
HC|IDENTITY|DB_UNIQUE_NAME|ORCL
HC|IDENTITY|CDB|NO
HC|IDENTITY|INSTANCE_NAME|ORCL
HC|IDENTITY|HOST_NAME|test-host
HC|STATE|OPEN_MODE|READ WRITE
HC|STATE|DATABASE_ROLE|PRIMARY
HC|STATE|VERSION_FULL|19.20.0.0.0
HC|STATE|INSTANCE_STATUS|OPEN
HC|STATE|DATABASE_STATUS|ACTIVE
HC|STATE|LOGINS|ALLOWED
HC|STATE|ACTIVE_STATE|NORMAL
HC|STATE|ORACLE_HOME|/mock/home
HC|CONTEXT|NONCDB|NONCDB|READ WRITE
HC|INFO|STARTUP_TIME|2026-10-18 01:00:00
HC|DONE|CORE
'''
DICT = 'HC|COVERAGE|NONCDB|FULL\nHC|DONE|DICT|NONCDB\n'
BASE = CORE + DICT
passed = []

def invoke(args, expected, contains='', env=None):
    p = subprocess.run(['bash', str(SCRIPT), *map(str, args)], text=True,
                       capture_output=True, env=env, timeout=20)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    assert contains in p.stdout + p.stderr, (args, contains, p.stdout, p.stderr)
    return p

with tempfile.TemporaryDirectory(prefix='oracle-health-check-test-') as tmp:
    root = pathlib.Path(tmp)
    before, after = root / 'before.dat', root / 'after.dat'
    def compare(name, baseline, current, expected, contains, phase='after'):
        before.write_text(baseline)
        after.write_text(current)
        invoke(['--compare', before, after, phase], expected, contains)
        passed.append(name)

    subprocess.run(['bash', '-n', str(SCRIPT)], check=True)
    passed.append('bash syntax')
    invoke(['--help'], 0, 'Usage:')
    passed.append('help')
    compare('unchanged snapshot', BASE, BASE, 0, 'RESULT: NO_DIFFERENCES')
    compare('startup time excluded', BASE, BASE.replace('2026-10-18', '2026-10-19'), 0, 'RESULT: NO_DIFFERENCES')
    invalid = 'HC|INVALID|NONCDB|APP|BROKEN_VIEW|VIEW||\n'
    compare('new invalid object', BASE, BASE + invalid, 1, '[NEW INVALID]')
    compare('existing invalid object retained', BASE + invalid, BASE + invalid, 0, '[EXISTING]')
    compare('invalid object recovered', BASE + invalid, BASE, 0, 'RESULT: NO_NEW_ISSUES')
    compare('identity mismatch', BASE, BASE.replace('DBID|12345', 'DBID|54321'), 2, 'identity mismatch')
    compare('state change', BASE, BASE.replace('LOGINS|ALLOWED', 'LOGINS|RESTRICTED'), 1, '[FAIL] State changed')
    compare('service change', BASE, BASE + 'HC|SERVICE|app|app|NONCDB|NO\n', 1, 'Service appeared')
    skipped = CORE + 'HC|COVERAGE|NONCDB|SKIPPED:MOUNTED\n'
    compare('coverage skipped after', BASE, skipped, 1, 'Dictionary checks skipped')
    compare('coverage skipped before review', skipped, skipped, 1, 'RESULT: BASELINE COLLECTED', 'before')
    compare('incomplete snapshot', BASE, BASE.replace('HC|DONE|CORE\n', ''), 2, 'incomplete or malformed')
    compare('duplicate identity', BASE, BASE + 'HC|IDENTITY|DBID|12345\n', 2, 'incomplete or malformed')
    compare('malformed record', BASE, BASE + 'garbage\n', 2, 'incomplete or malformed')
    compare('new PDB error', BASE, BASE + 'HC|VIOLATION|2026-10-19|PDB1|SQL Patch|123|message|PENDING|action\n', 1, '[NEW PDB ERROR]')
    component = 'HC|COMPONENT|NONCDB|CATPROC|PL/SQL|19.0|INVALID|SYS\n'
    compare('existing nonvalid component retained', BASE + component, BASE + component, 0, 'current non-VALID components=1')
    patch = 'HC|PATCH|NONCDB|1|2|RU|APPLY|SUCCESS|2026-10-19|desc|19.0|19.1|source|target\n'
    compare('patch history change', BASE, BASE + patch, 1, '[PATCH CHANGE]')

    home = root / 'oracle-home'
    (home / 'bin').mkdir(parents=True)
    mock = home / 'bin' / 'sqlplus'
    mock.write_text('#!/usr/bin/env python3\nimport os,sys,time\n' +
        'sql=sys.stdin.read()\nvariant=os.environ.get("MOCK_VARIANT", "")\n' +
        'if variant=="fail":\n print("ORA-01034: ORACLE not available"); sys.exit(1)\n' +
        'if variant=="timeout": time.sleep(6)\n' +
        'if "v$database" in sql:\n print(' + repr(CORE.replace('HC|STATE|ORACLE_HOME|/mock/home\n', '')) + ',end="")\n' +
        'else:\n print("HC|DONE|DICT|NONCDB")\n' +
        ' if variant=="invalid": print(' + repr(invalid.strip()) + ')\n')
    mock.chmod(0o755)
    db_list = root / 'db_list.txt'
    db_list.write_text('ORCL ' + str(home) + '\n')
    env = dict(os.environ, DB_LIST=str(db_list), HEALTH_LOG_ROOT=str(root / 'logs'))
    invoke(['before', 'TEST001'], 0, 'BASELINE READY', env)
    passed.append('mock full before')
    assert (root / 'logs/TEST001/before/complete').is_file()
    invoke(['before', 'TEST001'], 2, 'Baseline already exists', env)
    passed.append('baseline overwrite refused')
    invoke(['after', 'TEST001'], 0, 'OVERALL: NO_DIFFERENCES', env)
    passed.append('mock full after unchanged')
    env['MOCK_VARIANT'] = 'invalid'
    invoke(['after', 'TEST001'], 1, 'OVERALL: REVIEW_REQUIRED', env)
    passed.append('mock full after invalid object')
    env['MOCK_VARIANT'] = 'fail'
    invoke(['after', 'TEST001'], 2, 'OVERALL: INCOMPLETE', env)
    passed.append('mock failed collection')
    env['MOCK_VARIANT'] = 'timeout'
    env['SQLPLUS_TIMEOUT'] = '1'
    invoke(['after', 'TEST001'], 2, 'OVERALL: INCOMPLETE', env)
    assert list((root / 'logs/TEST001').glob('after_*/ORCL/core.log.timeout'))
    passed.append('mock SQLPlus timeout')
    invoke(['after', 'MISSING'], 2, 'Baseline is missing/incomplete', env)
    passed.append('missing baseline refused')
    invoke(['before', '../invalid'], 2, 'CHANGE_ID must contain', env)
    passed.append('unsafe change id refused')

print('\n'.join('PASS ' + name for name in passed))
print(f'{len(passed)} checks passed; Oracle integration not tested.')
