#!/usr/bin/env bash
# Version 3.1: upload this ONE file. Oracle 19c, Bash 3.2+; no Python required.
# Usage: bash health_check_v3_1.sh before CHANGE_ID
#        bash health_check_v3_1.sh after  CHANGE_ID
# Default output: health_logs_v3/CHANGE_ID next to this script.
# Auto-discovery and OS authentication are local to the current server.
set -euo pipefail
umask 077
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
SELF="$SCRIPT_DIR/$(basename "$0")"

# Optional SID / Oracle Home overrides. Normally leave empty and use oratab.
# Put actual entries BETWEEN the single quotes, one "SID /real/OracleHome" per line.
# Example only: PSFPERCDV1 /u01/app/oracle/product/19c/dbhome_1
ORACLE_HOME_OVERRIDES=''

emit_core_sql() {
  cat <<'HC_V3_CORE_SQL'
whenever oserror exit failure rollback
whenever sqlerror exit failure rollback
set echo off verify off feedback off heading off pagesize 0 linesize 32767 trimspool on tab off
set serveroutput on size unlimited format wrapped
declare
  errors_cursor sys_refcursor;
  v_time timestamp;
  v_name varchar2(128);
  v_cause varchar2(64);
  v_type varchar2(16);
  v_error number;
  v_message varchar2(4000);
  v_status varchar2(16);
  v_action varchar2(4000);
  function e(s varchar2) return varchar2 is
  begin
    return replace(replace(replace(replace(nvl(s, ''), '\', '\\'), '|', '\p'), chr(10), '\n'), chr(13), '\r');
  end;
begin
  for d in (select dbid, name, db_unique_name, cdb, open_mode, database_role from v$database) loop
    dbms_output.put_line('HC|IDENTITY|DBID|' || d.dbid);
    dbms_output.put_line('HC|IDENTITY|DB_NAME|' || e(d.name));
    dbms_output.put_line('HC|IDENTITY|DB_UNIQUE_NAME|' || e(d.db_unique_name));
    dbms_output.put_line('HC|IDENTITY|CDB|' || d.cdb);
    dbms_output.put_line('HC|STATE|OPEN_MODE|' || d.open_mode);
    dbms_output.put_line('HC|STATE|DATABASE_ROLE|' || d.database_role);
    if d.cdb = 'YES' then
      dbms_output.put_line('HC|CONTEXT|ROOT|CDB$ROOT|' || d.open_mode);
      for p in (select name, rawtohex(guid) gid, open_mode, restricted from v$pdbs order by con_id) loop
        dbms_output.put_line('HC|PDB|' || p.gid || '|' || e(p.name) || '|' || p.open_mode || '|' || nvl(p.restricted, 'UNKNOWN'));
        dbms_output.put_line('HC|CONTEXT|' || p.gid || '|' || e(p.name) || '|' || p.open_mode);
      end loop;
      if d.open_mode like 'READ%' then
        -- Defer dictionary access until the root is open; MOUNTED standby is valid.
        open errors_cursor for 'select time, name, cause, type, error_number, message, status, action from pdb_plug_in_violations where type = ''ERROR'' and nvl(status, ''PENDING'') = ''PENDING''';
        loop
          fetch errors_cursor into v_time, v_name, v_cause, v_type, v_error, v_message, v_status, v_action;
          exit when errors_cursor%notfound;
          dbms_output.put_line('HC|VIOLATION|' || to_char(v_time, 'YYYY-MM-DD HH24:MI:SS.FF6') || '|' || e(v_name) || '|' || e(v_cause) || '|' || v_error || '|' || e(v_message) || '|' || e(v_status) || '|' || e(v_action));
        end loop;
        close errors_cursor;
      end if;
    else
      dbms_output.put_line('HC|CONTEXT|NONCDB|NONCDB|' || d.open_mode);
    end if;
  end loop;
  for i in (select instance_name, host_name, version_full, startup_time, status, database_status, logins, active_state from v$instance) loop
    dbms_output.put_line('HC|IDENTITY|INSTANCE_NAME|' || e(i.instance_name));
    dbms_output.put_line('HC|IDENTITY|HOST_NAME|' || e(i.host_name));
    dbms_output.put_line('HC|STATE|VERSION_FULL|' || e(i.version_full));
    dbms_output.put_line('HC|STATE|INSTANCE_STATUS|' || i.status);
    dbms_output.put_line('HC|STATE|DATABASE_STATUS|' || i.database_status);
    dbms_output.put_line('HC|STATE|LOGINS|' || i.logins);
    dbms_output.put_line('HC|STATE|ACTIVE_STATE|' || i.active_state);
    dbms_output.put_line('HC|INFO|STARTUP_TIME|' || to_char(i.startup_time, 'YYYY-MM-DD HH24:MI:SS'));
  end loop;
  for s in (select name, network_name, con_name, blocked from v$active_services where name not in ('SYS$BACKGROUND', 'SYS$USERS')) loop
    dbms_output.put_line('HC|SERVICE|' || e(s.name) || '|' || e(s.network_name) || '|' || e(s.con_name) || '|' || e(s.blocked));
  end loop;
  dbms_output.put_line('HC|DONE|CORE');
end;
/
exit success rollback
HC_V3_CORE_SQL
}

emit_dictionary_sql() {
  cat <<'HC_V3_DICTIONARY_SQL'
whenever oserror exit failure rollback
whenever sqlerror exit failure rollback
set echo off verify off feedback off heading off pagesize 0 linesize 32767 trimspool on tab off
set serveroutput on size unlimited format wrapped
declare
  function e(s varchar2) return varchar2 is
  begin
    return replace(replace(replace(replace(nvl(s, ''), '\', '\\'), '|', '\p'), chr(10), '\n'), chr(13), '\r');
  end;
begin
  for o in (select owner, object_name, subobject_name, object_type, edition_name from dba_objects where status = 'INVALID') loop
    dbms_output.put_line('HC|INVALID|&hc_context|' || e(o.owner) || '|' || e(o.object_name) || '|' || e(o.object_type) || '|' || e(o.subobject_name) || '|' || e(o.edition_name));
  end loop;
  for c in (select comp_id, comp_name, version, status, schema from dba_registry) loop
    dbms_output.put_line('HC|COMPONENT|&hc_context|' || e(c.comp_id) || '|' || e(c.comp_name) || '|' || e(c.version) || '|' || e(c.status) || '|' || e(c.schema));
  end loop;
  for p in (select patch_id, patch_uid, patch_type, action, status, action_time, description, source_version, target_version, source_build_description, target_build_description from dba_registry_sqlpatch) loop
    dbms_output.put_line('HC|PATCH|&hc_context|' || p.patch_id || '|' || p.patch_uid || '|' || e(p.patch_type) || '|' || e(p.action) || '|' || e(p.status) || '|' || to_char(p.action_time, 'YYYY-MM-DD HH24:MI:SS.FF6') || '|' || e(p.description) || '|' || e(p.source_version) || '|' || e(p.target_version) || '|' || e(p.source_build_description) || '|' || e(p.target_build_description));
  end loop;
  dbms_output.put_line('HC|DONE|DICT|&hc_context');
end;
/
exit success rollback
HC_V3_DICTIONARY_SQL
}

compare_snapshots() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'ERROR: Comparison requires baseline and after snapshot paths.\n' >&2
    return 2
  fi
  local program
  program=$(cat <<'HC_V3_COMPARISON_AWK'
# Portable awk. Exit 0: no new issues, 1: differences/limited coverage, 2: invalid snapshots.
BEGIN { FS="|"; max_detail=20 }
function note(level, text) {
  print "[" level "] " text
  if (level == "FAIL") failures++
  if (level == "WARN") warnings++
}
function label(ctx) { return (ctx in names) ? names[ctx] : ctx }
function comparable(ctx, b, a) {
  split(values["b" SUBSEP "COVERAGE|" ctx],b,"|")
  split(values["a" SUBSEP "COVERAGE|" ctx],a,"|")
  return b[4]=="FULL" && a[4]=="FULL"
}
function invalid_text(row, a) {
  split(row,a,"|"); return label(a[3]) " / " a[4] "." a[5] " (" a[6] ", subobject=" a[7] ", edition=" a[8] ")"
}
function fields_valid(t,n) {
  return ((t=="IDENTITY" || t=="STATE" || t=="INFO" || t=="COVERAGE") && n==4) ||
         (t=="PDB" && n==6) || (t=="CONTEXT" && n==5) ||
         (t=="SERVICE" && n==6) || (t=="VIOLATION" && n==9) ||
         (t=="INVALID" && n==8) || (t=="COMPONENT" && n==8) ||
         (t=="PATCH" && n==14) || (t=="DONE" && (n==3 || n==4))
}
{
  side=(FILENAME==ARGV[1] ? "b" : "a")
  if ($1!="HC" || !fields_valid($2,NF)) { malformed=1; next }
  if ($2=="INFO") { info[side SUBSEP $3]=$4; next }
  if ($2=="DONE") { done[side SUBSEP $3 SUBSEP $4]++; next }
  if ($2=="CONTEXT") { contexts[side SUBSEP $3]=1; names[$3]=$4; next }
  if ($2=="IDENTITY" || $2=="STATE" || $2=="PDB" || $2=="COVERAGE") {
    key=$2 "|" $3
    if ((side SUBSEP key) in values) malformed=1
    values[side SUBSEP key]=$0; keys[key]=1
    next
  }
  if ($2=="COMPONENT") {
    key=$2 "|" $3 "|" $4
    if ((side SUBSEP key) in values) malformed=1
    values[side SUBSEP key]=$0; keys[key]=1
    if (side=="a" && $7!="VALID") bad_components++
    next
  }
  sets[side SUBSEP $0]=1; rows[$0]=$2
}
END {
  required="DBID DB_NAME DB_UNIQUE_NAME CDB INSTANCE_NAME HOST_NAME"
  n=split(required,req," ")
  for(s=1;s<=2;s++) {
    side=(s==1 ? "b" : "a")
    if (done[side SUBSEP "CORE" SUBSEP ""]!=1) malformed=1
    for(i=1;i<=n;i++) if (!((side SUBSEP "IDENTITY|" req[i]) in values)) malformed=1
    nstate=split("OPEN_MODE DATABASE_ROLE VERSION_FULL INSTANCE_STATUS DATABASE_STATUS LOGINS ACTIVE_STATE",state_req," ")
    for(i=1;i<=nstate;i++) if (!((side SUBSEP "STATE|" state_req[i]) in values)) malformed=1
    context_count=0
    for(k in contexts) {
      split(k,parts,SUBSEP)
      if(parts[1]!=side) continue
      context_count++
      coverage=values[side SUBSEP "COVERAGE|" parts[2]]
      if(coverage=="") malformed=1
      split(coverage,c,"|")
      if(c[4]=="FULL") {
        if(done[side SUBSEP "DICT" SUBSEP parts[2]]!=1) malformed=1
      } else if(c[4] !~ /^SKIPPED:/) malformed=1
    }
    if(!context_count) malformed=1
  }
  if(malformed) { note("UNKNOWN","Snapshot is incomplete or malformed; recovery cannot be confirmed."); exit 2 }
  for(key in keys) if (key ~ /^IDENTITY\|/ && values["b" SUBSEP key]!=values["a" SUBSEP key]) {
    note("UNKNOWN","Database/instance identity mismatch: " key)
    print "  before: " values["b" SUBSEP key]; print "  after : " values["a" SUBSEP key]
    identity_bad=1
  }
  if(identity_bad) exit 2
  for(key in keys) {
    b=values["b" SUBSEP key]; a=values["a" SUBSEP key]
    split(a,ar,"|"); split(b,br,"|")
    if(key ~ /^COVERAGE\|/ && ar[4]!="FULL") note("WARN","Dictionary checks skipped for " label(ar[3]) ": " ar[4])
    if(a==b || key ~ /^IDENTITY\|/) continue
    if(key ~ /^COMPONENT\|/ && !comparable(ar[3]!="" ? ar[3] : br[3])) continue
    if(key ~ /^COVERAGE\|/) {
      note("WARN","Collection coverage changed: " label(ar[3]!="" ? ar[3] : br[3]))
    } else if(key ~ /^COMPONENT\|/) {
      note("WARN","Component changed: " label(ar[3]!="" ? ar[3] : br[3]) " / " (ar[4]!="" ? ar[4] : br[4]))
    } else {
      note("FAIL","State changed: " key " (container=" label(ar[3]!="" ? ar[3] : br[3]) ")")
    }
    print "  before: " (b!="" ? b : "<missing>")
    print "  after : " (a!="" ? a : "<missing>")
  }
  for(row in rows) {
    t=rows[row]; b=(("b" SUBSEP row) in sets); a=(("a" SUBSEP row) in sets)
    split(row,record_fields,"|")
    if(t=="INVALID" && a) invalid_after++
    # A closed/unreadable container has no dictionary sample, not recovered objects.
    if((t=="INVALID" || t=="COMPONENT" || t=="PATCH") && !comparable(record_fields[3])) continue
    if(t=="INVALID") {
      if(a && b) invalid_existing++
      if(a && !b) {invalid_new++; if(invalid_new<=max_detail) print "[NEW INVALID] " invalid_text(row)}
      if(b && !a) {invalid_gone++; if(invalid_gone<=max_detail) print "[RECOVERED INVALID] " invalid_text(row)}
    } else if(t=="VIOLATION") {
      if(a && b) violations_existing++
      if(a && !b) {violations_new++; if(violations_new<=max_detail) print "[NEW PDB ERROR] " row}
      if(b && !a) {violations_gone++; if(violations_gone<=max_detail) print "[RESOLVED PDB ERROR] " row}
    } else if(t=="SERVICE") {
      if(a!=b) {
        service_changes++
        note("WARN",(a ? "Service appeared/changed locally: " : "Service missing/changed locally (check RAC placement if applicable): ") row)
      } else if(a && record_fields[6]!="NO") note("EXISTING","Service blocked/unknown state preserved: " row)
    } else if(t=="PATCH" && a!=b) {
      patch_changes++
      if(patch_changes<=max_detail) print "[PATCH CHANGE] " (a ? "added: " : "removed: ") row
    }
  }
  if(invalid_new) note("FAIL",invalid_new " newly invalid objects (up to 20 listed; all in differences.diff).")
  if(violations_new) note("FAIL",violations_new " new pending PDB errors.")
  if(patch_changes) note("WARN",patch_changes " patch history rows changed.")
  print "[INFO] Current invalid objects in collected containers: " invalid_after+0
  if(invalid_existing || violations_existing || bad_components)
    note("EXISTING","Invalid objects=" invalid_existing+0 ", pending PDB errors=" violations_existing+0 ", current non-VALID components=" bad_components+0)
  if(invalid_gone || violations_gone)
    note("RECOVERED","Invalid objects=" invalid_gone+0 ", pending PDB errors=" violations_gone+0)
  # Abnormal states preserved across reboot remain visible, including intentional restricted configurations.
  for(key in keys) if(key ~ /^STATE\|/ && values["b" SUBSEP key]==values["a" SUBSEP key]) {
    split(values["a" SUBSEP key],ar,"|")
    if ((ar[3]=="INSTANCE_STATUS" && ar[4]!="OPEN") ||
        (ar[3]=="DATABASE_STATUS" && ar[4]!="ACTIVE") ||
        (ar[3]=="LOGINS" && ar[4]!="ALLOWED") ||
        (ar[3]=="ACTIVE_STATE" && ar[4]!="NORMAL")) note("EXISTING","Preserved state: " ar[3] "=" ar[4])
  }
  for(key in keys) if(key ~ /^PDB\|/ && values["b" SUBSEP key]==values["a" SUBSEP key]) {
    split(values["a" SUBSEP key],ar,"|")
    if(ar[6]!="NO") note("EXISTING","PDB restriction preserved: " ar[4] "=" ar[6])
  }
  if(phase=="before") {
    print "[INFO] Captured startup time: " info["a" SUBSEP "STARTUP_TIME"]
  } else {
    print "[INFO] Startup time: " info["b" SUBSEP "STARTUP_TIME"] " -> " info["a" SUBSEP "STARTUP_TIME"] " (excluded from comparison)"
    if(info["b" SUBSEP "STARTUP_TIME"]==info["a" SUBSEP "STARTUP_TIME"])
      print "[INFO] Instance startup time is unchanged; a restart is not evidenced by these snapshots."
  }
  if(phase=="before") {
    print "RESULT: BASELINE COLLECTED - review any EXISTING/WARN items above."
    print "Scope: local database state only; listener/client connectivity and application recovery are not tested."
    exit (warnings ? 1 : 0)
  }
  if(failures) { print "RESULT: FAIL - differences requiring investigation."; exit 1 }
  if(warnings) { print "RESULT: REVIEW - changes or limited coverage require review."; exit 1 }
  if(invalid_gone || violations_gone) {
    print "RESULT: NO_NEW_ISSUES - baseline issues have decreased; review RECOVERED/EXISTING items above."
  } else {
    print "RESULT: NO_DIFFERENCES - compared state is unchanged; existing baseline issues remain where listed."
  }
  print "Scope: local database state only; listener/client connectivity and application recovery are not tested."
  exit 0
}
HC_V3_COMPARISON_AWK
  ) || return 2
  awk -v phase="${3:-after}" "$program" "$1" "$2"
}

collect_database() {
# Oracle 19c, Bash 3.2+. Local OS authentication; no persistent database changes.
set -euo pipefail
umask 077
export LC_ALL=C
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  fail "Internal collection requires SID NEW_OUTPUT_DIRECTORY [ORACLE_HOME]"
fi
sid=$1
out=$2
case "$sid" in ''|*[!A-Za-z0-9_\$#]*) fail "Invalid SID: $sid";; esac
case "$out" in /*) ;; *) out="$PWD/$out";; esac
mkdir "$out" || fail "Cannot create output directory (must not already exist): $out"
printf 'FAILED\n' > "$out/status"
trap 'printf "FAILED\n" > "$out/status"; exit 2' HUP INT TERM
home=${3:-}
if [ -z "$home" ]; then
  oratab=${ORATAB:-/etc/oratab}
  if [ ! -r "$oratab" ] && [ -z "${ORATAB:-}" ]; then oratab=/var/opt/oracle/oratab; fi
  [ -r "$oratab" ] || fail "Cannot read oratab; set ORATAB or configure ORACLE_HOME_OVERRIDES at the top of health_check_v3_1.sh"
  home=$(awk -F: -v sid="$sid" '$0 !~ /^[[:space:]]*#/ && $1 == sid {print $2}' "$oratab")
fi
case "$home" in ''|*$'\n'*|*$'\r'*) fail "SID $sid must resolve to exactly one Oracle Home";; esac
[ -x "$home/bin/sqlplus" ] || fail "sqlplus not executable: $home/bin/sqlplus"
timeout_seconds=${SQLPLUS_TIMEOUT:-180}
case "$timeout_seconds" in ''|*[!0-9]*) fail "SQLPLUS_TIMEOUT must be a positive integer";; esac
[ "$timeout_seconds" -gt 0 ] || fail "SQLPLUS_TIMEOUT must be positive"
export ORACLE_SID="$sid" ORACLE_HOME="$home"
export PATH="$home/bin:$PATH"
export LD_LIBRARY_PATH="$home/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBPATH="$home/lib${LIBPATH:+:$LIBPATH}"
unset ORACLE_PDB_SID TWO_TASK LOCAL
{
  printf 'schema=1\nsid=%s\nhost=%s\nos_user=%s\noracle_home=%s\ncollected_at=%s\n' "$sid" "$(hostname)" "$(id -un)" "$home" "$(date '+%Y-%m-%d %H:%M:%S %z')"
} > "$out/metadata.txt"

# Each call is bounded, including SQL*Plus startup/login. Keep original errors.
run_sql() {
  sql_file=$1
  log_file=$2
  expected=$3
  "$home/bin/sqlplus" -L -s '/ as sysdba' < "$sql_file" > "$log_file" 2>&1 &
  sql_pid=$!
  (
    sleep "$timeout_seconds" &
    sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
    wait "$sleeper"
    if kill -0 "$sql_pid" 2>/dev/null; then
      printf 'SQLPLUS_TIMEOUT after %s seconds\n' "$timeout_seconds" > "$log_file.timeout"
      kill -TERM "$sql_pid" 2>/dev/null
      sleep 2
      kill -KILL "$sql_pid" 2>/dev/null
    fi
  ) &
  watchdog=$!
  trap 'kill "$sql_pid" "$watchdog" 2>/dev/null; wait "$sql_pid" "$watchdog" 2>/dev/null; exit 2' HUP INT TERM
  if wait "$sql_pid"; then sql_rc=0; else sql_rc=$?; fi
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  trap 'printf "FAILED\n" > "$out/status"; exit 2' HUP INT TERM
  if [ "$sql_rc" -ne 0 ] || [ -f "$log_file.timeout" ] ||
     awk '/^[[:space:]]*(ORA|SP2|TNS)-[0-9]+/ {bad=1} END {exit !bad}' "$log_file" ||
     ! awk -v expected="$expected" '$0 == expected {found++} END {exit found != 1}' "$log_file"; then
    printf 'ERROR: %s collection failed; see %s\n' "$sid" "$log_file" >&2
    return 2
  fi
  awk '/^HC\|/ {print}' "$log_file" >> "$out/records.tmp" || return 2
}
: > "$out/records.tmp"
encoded_home=$(printf '%s\n' "$home" | awk '{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="\\") printf "%s","\\\\"; else if(c=="|") printf "%s","\\p"; else printf "%s",c;} print ""}')
printf 'HC|STATE|ORACLE_HOME|%s\n' "$encoded_home" >> "$out/records.tmp"
emit_core_sql > "$out/core.sql"
run_sql "$out/core.sql" "$out/core.log" 'HC|DONE|CORE' || exit 2
# Decode only our four field escapes; record separators never occur inside fields.
decode() {
  printf '%s\n' "$1" | awk '{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="\\"){i++; c=substr($0,i,1); if(c=="p") c="|"; else if(c=="n") c="\n"; else if(c=="r") c="\r";} printf "%s",c}}'
}
awk -F'|' '$2 == "CONTEXT" {print $3 "|" $4 "|" $5}' "$out/records.tmp" > "$out/contexts.txt"
while IFS='|' read -r context container mode; do
  case "$context" in ROOT|NONCDB) ;; *[!A-F0-9]*|'') fail "Invalid container identity";; esac
  case "$mode" in
    'READ WRITE'|'READ ONLY'|'READ ONLY WITH APPLY') ;;
    *) printf 'HC|COVERAGE|%s|SKIPPED:%s\n' "$context" "$mode" >> "$out/records.tmp"; continue;;
  esac
  input="$out/dictionary_${context}.sql"
  {
    printf 'whenever oserror exit failure rollback\nwhenever sqlerror exit failure rollback\nset define off\n'
    if [ "$context" != ROOT ] && [ "$context" != NONCDB ]; then
      pdb_name=$(decode "$container")
      case "$pdb_name" in *$'\n'*|*$'\r'*) fail "Unsupported newline in PDB name";; esac
      pdb_sql_name=${pdb_name//\"/\"\"}
      printf 'alter session set container = "%s";\n' "$pdb_sql_name"
    fi
    printf 'set define on\ndefine hc_context = %s\n' "$context"
    emit_dictionary_sql
  } > "$input"
  run_sql "$input" "$out/dictionary_${context}.log" "HC|DONE|DICT|$context" || exit 2
  printf 'HC|COVERAGE|%s|FULL\n' "$context" >> "$out/records.tmp"
done < "$out/contexts.txt"
sort "$out/records.tmp" > "$out/snapshot.dat" || exit 2
rm -f "$out/records.tmp"
printf 'OK\n' > "$out/status"
printf 'Collected %s: %s\n' "$sid" "$out"
exit 0
}

# Internal modes run in a fresh Bash process, isolating SID/Home/environment and traps.
# Do not use the collector helper directly; normal usage is before/after below.
if [ "${1:-}" = --collect ]; then
  shift
  collect_database "$@"
  exit 2
fi
if [ "${1:-}" = --compare ]; then
  shift
  compare_snapshots "$@"
  exit 0
fi

# Save a baseline, then compare a fresh snapshot after OS maintenance.
set -euo pipefail
umask 077
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  bash health_check_v3_1.sh before CHANGE_ID
  bash health_check_v3_1.sh after  CHANGE_ID
Optional environment:
  HEALTH_LOG_ROOT=/path/health_logs  ORACLE_HOME_MAP=/path/home_map.txt
  DB_LIST=/path/db_list.txt   (explicit manual list for before only)
  ORATAB=/path/oratab        SQLPLUS_TIMEOUT=180
  Home overrides can also be configured in this script: ORACLE_HOME_OVERRIDES
Default before: auto-discover ora_pmon_SID. After: always check frozen baseline SIDs.
Progress and every database result are printed to stdout and saved in report.txt.
Exit: 0=baseline collected/no new issues; 1=differences/review; 2=incomplete/error.
EOF
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
phase=$1
change=$2
case "$phase" in before|after) ;; *) die "Phase must be before or after";; esac
case "$change" in ''|.|..|*[!A-Za-z0-9_.-]*) die "CHANGE_ID must contain letters, digits, underscore, dot or hyphen";; esac
printf '[START] Version 3.1 | phase=%s | change=%s | host=%s\n' "$phase" "$change" "$(hostname)"
root=${HEALTH_LOG_ROOT:-$SCRIPT_DIR/health_logs_v3}
mkdir -p "$root" || die "Cannot create log root"
root=$(cd "$root" && pwd) || exit 2
job="$root/$change"
mkdir -p "$job" || die "Cannot create job directory"
# One collector/comparator at a time for this change. Never silently replace baseline.
lock="$job/.lock"
mkdir "$lock" 2>/dev/null || die "Job is in use; if interrupted, verify no collector is running before removing $lock"
trap 'rmdir "$lock" 2>/dev/null' EXIT
trap 'exit 2' HUP INT TERM
if [ "$phase" = before ]; then
  [ ! -e "$job/before" ] || die "Baseline already exists. Use a new CHANGE_ID; never overwrite the original baseline."
else
  [ -f "$job/before/complete" ] || die "Baseline is missing/incomplete; recovery cannot be confirmed. Use the original successful before run."
  [ "$(cat "$job/before/host")" = "$(hostname)" ] || die "Host differs from baseline. Run this check on the original node."
fi
if [ "$phase" = before ]; then dest="$job/before"; else
  # mkdir below prevents collisions even for two calls in the same second.
  dest="$job/after_$(date '+%Y%m%d_%H%M%S')_$$"
fi
mkdir "$dest" || die "Cannot create snapshot directory"
printf '%s\n' "$(hostname)" > "$dest/host"
# Format: SID [ORACLE_HOME]. Blank lines and full-line comments allowed; CRLF accepted.
parse_list() {
  awk -v allow_empty="${2:-0}" '
  {sub(/\r$/,""); if($0 ~ /^[[:space:]]*(#|$)/) next
   if(NF<1 || NF>2 || $1 ~ /[^A-Za-z0-9_$#]/ || $2 ~ /\|/ || seen[$1]++) {bad=1; print "Invalid/duplicate DB list line " NR > "/dev/stderr"; next}
   print $1 "|" (NF==2 ? $2 : ""); count++}
  END {if(bad || (!count && !allow_empty)) exit 2}
  ' "$1"
}
discover_pmon() {
  # Explicit args format keeps grep/awk/shell command text out of the process-name field.
  # Retain only PMON candidates as evidence, not unrelated process command lines.
  if ! COLUMNS=4096 ps -e -o args= 2> "$dest/pmon_discovery.error" |
      awk '$1 ~ /^ora_pmon_/ || $1 ~ /^\[ora_pmon_/ {print}' > "$dest/pmon_processes.raw"; then
    return 2
  fi
  if ! awk '
    /<defunct>|\(defunct\)/ {next}
    {name=$1; if(name ~ /^\[.*\]$/) {sub(/^\[/,"",name); sub(/\]$/,"",name)}
     if(name !~ /^ora_pmon_/) next
     sub(/^ora_pmon_/,"",name)
     if(name=="" || name ~ /[^A-Za-z0-9_$#]/) {bad=1; print "Invalid PMON SID: " name > "/dev/stderr"; next}
     print name}
    END {if(bad) exit 2}
  ' "$dest/pmon_processes.raw" > "$dest/pmon_sids.tmp" 2>> "$dest/pmon_discovery.error"; then return 2; fi
  sort -u "$dest/pmon_sids.tmp" > "$dest/pmon_sids.txt" || return 2
  rm -f "$dest/pmon_sids.tmp"
}
discovery_failed=0
if [ "$phase" = before ]; then
  if [ -n "${DB_LIST:-}" ]; then
    [ -r "$DB_LIST" ] || die "Cannot read DB list: $DB_LIST"
    cp "$DB_LIST" "$dest/db_list.source.txt"
    parse_list "$dest/db_list.source.txt" > "$dest/manifest.txt" || die "DB list validation failed; see $dest"
    printf 'manual\n' > "$dest/list_mode.txt"
  else
    discover_pmon || die "PMON discovery failed; see $dest/pmon_discovery.error and pmon_processes.raw. An explicit DB_LIST can be used for manual scope."
    [ -s "$dest/pmon_sids.txt" ] || die "No ora_pmon_SID was discovered. No valid baseline was created."
    cp "$dest/pmon_sids.txt" "$dest/db_list.source.txt"
    if [ -n "${ORACLE_HOME_MAP:-}" ]; then
      [ -r "$ORACLE_HOME_MAP" ] || die "Cannot read Oracle Home map: $ORACLE_HOME_MAP"
      cp "$ORACLE_HOME_MAP" "$dest/home_map.source.txt"
    else
      printf '%s\n' "$ORACLE_HOME_OVERRIDES" > "$dest/home_map.source.txt"
    fi
    parse_list "$dest/home_map.source.txt" 1 > "$dest/home_map.manifest" || die "Oracle Home map validation failed; see $dest"
    awk -F'|' 'FILENAME==ARGV[1] {homes[$1]=$2; next} {print $1 "|" homes[$1]}' "$dest/home_map.manifest" "$dest/pmon_sids.txt" > "$dest/manifest.txt"
    printf 'auto\n' > "$dest/list_mode.txt"
  fi
else
  # Discovery after reboot must never shrink the expected set: stopped instances stay in scope.
  [ -r "$job/before/manifest.txt" ] || die "Missing baseline manifest"
  cp "$job/before/manifest.txt" "$dest/manifest.txt"
  cp "$job/before/db_list.source.txt" "$dest/db_list.source.txt"
  if [ -f "$job/before/list_mode.txt" ]; then cp "$job/before/list_mode.txt" "$dest/list_mode.txt"; else printf 'manual\n' > "$dest/list_mode.txt"; fi
  if [ "$(cat "$dest/list_mode.txt")" = auto ]; then
    if discover_pmon; then
      awk -F'|' '{print $1}' "$dest/manifest.txt" | sort > "$dest/before_sids"
      awk 'FILENAME==ARGV[1] {seen[$0]=1; next} !($0 in seen) {print}' "$dest/pmon_sids.txt" "$dest/before_sids" > "$dest/pmon_missing.txt"
      awk 'FILENAME==ARGV[1] {seen[$0]=1; next} !($0 in seen) {print}' "$dest/before_sids" "$dest/pmon_sids.txt" > "$dest/pmon_added.txt"
    else discovery_failed=1; fi
  fi
fi
awk -F'|' '
  NF!=2 || $1=="" || $1 ~ /[^A-Za-z0-9_$#]/ || $2 ~ /[[:space:]]/ || seen[$1]++ {bad=1}
  END {if(bad || NR==0) exit 2}
' "$dest/manifest.txt" || die "Invalid/empty frozen SID manifest; cannot confirm recovery."
report="$dest/report.txt"
{
  printf 'Version: 3.1 (single file)\nChange: %s\nPhase: %s\nHost: %s\nTime: %s\nSID source: %s\n\n' "$change" "$phase" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(cat "$dest/list_mode.txt")"
  printf 'Scope: local Oracle instance/PDB/service state. No restart, compile, patch, or persistent DB configuration changes.\n\n'
} | tee "$report"
result=0
db_total=$(awk 'END {print NR}' "$dest/manifest.txt")
db_done=0
baseline_ok=0
no_change=0
improved=0
needs_review=0
unknown=0
if [ "$discovery_failed" -eq 1 ]; then
  printf '[UNKNOWN] Current PMON discovery failed; baseline SIDs will still be checked. See pmon_discovery.error.\n' | tee -a "$report"
  result=2
fi
if [ -f "$dest/pmon_missing.txt" ] && [ -s "$dest/pmon_missing.txt" ]; then
  while IFS= read -r sid; do printf '[FAIL] Baseline SID has no PMON in the current process snapshot: %s\n' "$sid" | tee -a "$report"; done < "$dest/pmon_missing.txt"
  result=1
fi
if [ -f "$dest/pmon_added.txt" ] && [ -s "$dest/pmon_added.txt" ]; then
  while IFS= read -r sid; do printf '[WARN] New SID discovered after reboot, outside the baseline: %s\n' "$sid" | tee -a "$report"; done < "$dest/pmon_added.txt"
  if [ "$result" -eq 0 ]; then result=1; fi
fi
while IFS='|' read -r sid home; do
  db_done=$((db_done + 1))
  printf '\n[%s/%s] Collecting %s ...\n' "$db_done" "$db_total" "$sid" | tee -a "$report"
  if bash "$SELF" --collect "$sid" "$dest/$sid" "$home" > "$dest/${sid}.collector.log" 2>&1; then
    collected=1
  else
    collected=0
  fi
  printf '\n--- %s ---\n' "$sid" | tee -a "$report"
  if [ "$collected" -eq 0 ] || [ ! -f "$dest/$sid/status" ] || [ "$(cat "$dest/$sid/status")" != OK ]; then
    printf '[UNKNOWN] %s: collection failed. Recovery cannot be confirmed. See %s.collector.log and %s/*.log\n' "$sid" "$sid" "$sid" | tee -a "$report"
    unknown=$((unknown + 1))
    result=2
    continue
  fi
  if [ "$phase" = before ]; then
    # Distinct filenames let portable awk distinguish baseline and comparison input.
    cp "$dest/$sid/snapshot.dat" "$dest/$sid/validation.dat" || die "Cannot validate baseline"
    if compare_snapshots "$dest/$sid/snapshot.dat" "$dest/$sid/validation.dat" before > "$dest/$sid/baseline_review.txt"; then compare_rc=0; else compare_rc=$?; fi
    cat "$dest/$sid/baseline_review.txt" | tee -a "$report"
    rm -f "$dest/$sid/validation.dat"
    if [ "$compare_rc" -gt 1 ]; then
      unknown=$((unknown + 1)); result=2
    else
      baseline_ok=$((baseline_ok + 1))
      printf '[BASELINE] %s: captured successfully; review any existing issues above.\n' "$sid" | tee -a "$report"
    fi
  else
    if [ ! -f "$job/before/$sid/status" ] || [ "$(cat "$job/before/$sid/status")" != OK ]; then
      printf '[UNKNOWN] Baseline collection failed for %s.\n' "$sid" | tee -a "$report"
      unknown=$((unknown + 1)); result=2; continue
    fi
    if diff -u "$job/before/$sid/snapshot.dat" "$dest/$sid/snapshot.dat" > "$dest/$sid/differences.diff"; then diff_rc=0; else diff_rc=$?; fi
    if [ "$diff_rc" -gt 1 ]; then
      printf '[UNKNOWN] %s: cannot generate difference evidence.\n' "$sid" | tee -a "$report"
      unknown=$((unknown + 1)); result=2; continue
    fi
    # Capture the comparison exit code before printing it; tee must not mask errors.
    if compare_snapshots "$job/before/$sid/snapshot.dat" "$dest/$sid/snapshot.dat" after > "$dest/$sid/comparison.txt"; then compare_rc=0; else compare_rc=$?; fi
    cat "$dest/$sid/comparison.txt" | tee -a "$report"
    if [ "$compare_rc" -gt 1 ]; then
      unknown=$((unknown + 1)); result=2
      printf '[UNKNOWN] %s: comparison could not be completed.\n' "$sid" | tee -a "$report"
    elif [ "$compare_rc" -ne 0 ]; then
      needs_review=$((needs_review + 1))
      if [ "$result" -eq 0 ]; then result=1; fi
      printf '[REVIEW] %s: differences or limited checks require review.\n' "$sid" | tee -a "$report"
    elif awk '/^RESULT: NO_DIFFERENCES / {found=1} END {exit !found}' "$dest/$sid/comparison.txt"; then
      no_change=$((no_change + 1))
      printf '[NO DIFFERENCES] %s: compared state unchanged (existing issues may remain).\n' "$sid" | tee -a "$report"
    else
      improved=$((improved + 1))
      printf '[NO NEW ISSUES] %s: baseline issues have decreased; see details above.\n' "$sid" | tee -a "$report"
    fi
  fi
done < "$dest/manifest.txt"
if [ "$result" -ne 2 ]; then printf 'complete\n' > "$dest/complete" || die "Cannot finalize snapshot"; fi
{
  printf '\n========== OVERALL RESULT ==========\n'
  if [ "$phase" = before ]; then
    printf 'Databases: total=%s, captured=%s, unknown=%s\n' "$db_total" "$baseline_ok" "$unknown"
    if [ "$result" -eq 0 ]; then printf 'BASELINE READY. Review EXISTING/WARN items before maintenance.\n'; fi
  else
    printf 'Databases: total=%s, no_differences=%s, improved=%s, review=%s, unknown=%s\n' "$db_total" "$no_change" "$improved" "$needs_review" "$unknown"
    if [ "$result" -eq 0 ]; then
      if [ "$no_change" -eq "$db_total" ]; then
        printf 'OVERALL: NO_DIFFERENCES - all compared database states match the baseline.\n'
      else
        printf 'OVERALL: NO_NEW_ISSUES - some baseline issues have decreased.\n'
      fi
      printf 'Existing issues may remain. This comparison does not verify an OS reboot.\n'
    elif [ "$result" -eq 1 ]; then
      printf 'OVERALL: REVIEW_REQUIRED - see differences, coverage, or PMON changes above.\n'
    fi
  fi
  if [ "$result" -eq 2 ]; then printf 'OVERALL: INCOMPLETE - do not treat this run as confirmation of recovery.\n'; fi
  printf 'Overall exit code: %s\n' "$result"
  printf 'Report: %s\n' "$report"
} | tee -a "$report"
exit "$result"
