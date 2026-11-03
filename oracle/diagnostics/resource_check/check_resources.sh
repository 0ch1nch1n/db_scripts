#!/usr/bin/env bash
# Oracle 19c resource check v2.1. Read-only dictionary collection.
set -euo pipefail
umask 077
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
db_list="$script_dir/db_list.conf"
accounts="$script_dir/functional_accounts.csv"
output_root="$script_dir/output"
threshold=90
basis=CURRENT
waste_mb=100
waste_pct=30
expiry_days=30
collect_only=0
usage() {
    cat <<'EOF'
Usage: bash check_resources.sh [options]
  --db-list FILE         Database config (default: db_list.conf)
  --accounts FILE        Functional account allowlist (default: functional_accounts.csv)
  --output DIR           New run directory will be created beneath DIR
  --threshold NUMBER    Tablespace alert threshold, strict > (default: 90)
  --basis CURRENT|MAX   Alert denominator (default: CURRENT)
  --waste-mb NUMBER     Table estimate candidate threshold, strict > (default: 100)
  --waste-pct NUMBER    Table estimate candidate threshold, strict > (default: 30)
  --expiry-days INTEGER Account expiry warning window (default: 30)
  --collect-only        Collect without Python; generate reports on another machine
  --help
Requires Bash >=4 and Oracle SQL*Plus >=12.2 (19c recommended), oraenv, local OS SYSDBA.
Reporting requires Python >=3.8, standard library only.
Exit: 0=execution complete (may contain review findings); 1=collection/report failure;
      2=configuration/dependency error. Findings are in monthly_summary.csv.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --collect-only) collect_only=1; shift ;;
        --db-list|--accounts|--output|--threshold|--basis|--waste-mb|--waste-pct|--expiry-days)
            (( $# >= 2 )) || die "Missing value for $1"
            case "$1" in
                --db-list) db_list="$2" ;; --accounts) accounts="$2" ;;
                --output) output_root="$2" ;;
                --threshold) threshold="$2" ;; --basis) basis="$2" ;;
                --waste-mb) waste_mb="$2" ;; --waste-pct) waste_pct="$2" ;;
                --expiry-days) expiry_days="$2" ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
(( BASH_VERSINFO[0] >= 4 )) || die 'Bash >=4 is required (run on the Oracle host).'
number='^[0-9]+([.][0-9]+)?$'
for value in "$threshold" "$waste_mb" "$waste_pct"; do
    [[ "$value" =~ $number ]] || die 'Thresholds must be finite non-negative decimals.'
done
[[ "$expiry_days" =~ ^[0-9]+$ ]] || die '--expiry-days must be a non-negative integer.'
awk -v a="$threshold" -v b="$waste_pct" 'BEGIN {exit !(a<=100 && b<=100)}' || die 'Percent thresholds must be <=100.'
[[ "$basis" == CURRENT || "$basis" == MAX ]] || die '--basis must be CURRENT or MAX.'
[[ -f "$db_list" && -f "$accounts" ]] || die 'Database config or accounts CSV not found.'
if (( ! collect_only )); then
    command -v python3 >/dev/null || die 'Python3 missing; use --collect-only and report later on a Mac/other host.'
    python3 -c 'import sys; sys.exit(sys.version_info < (3,8))' || die 'Python >=3.8 required.'
fi
oraenv_path="$(command -v oraenv || true)"
[[ -n "$oraenv_path" ]] || die 'oraenv not found; load the Oracle environment first.'
modules=(metadata tablespace undo table_stats index_stats table_waste user_accounts)
for module in common "${modules[@]}"; do
    [[ -f "$script_dir/sql/$module.sql" ]] || die "Missing SQL: $module.sql"
done

# Validate ALL rows before connecting. Never source configuration as shell code.
declare -a dbs=() sids=() cdbs=() pdbs=() uniques=()
declare -A seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *[[:space:]]* ]] || die 'Spaces are not allowed in db_list.conf.'
    pipes="${line//[^|]/}"
    [[ ${#pipes} -eq 3 || ${#pipes} -eq 4 ]] || die 'Expected 4 or 5 pipe-delimited config fields.'
    IFS='|' read -r db sid_list cdb pdb unique <<< "$line"
    label_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'
    identifier_pattern='^[A-Za-z][A-Za-z0-9_$#]*$'
    [[ "$db" =~ $label_pattern && "$cdb" =~ $identifier_pattern ]] || die 'Invalid database label/DB_NAME.'
    [[ -z "$pdb" || "$pdb" =~ $identifier_pattern ]] || die 'Use an unquoted Oracle PDB identifier.'
    [[ -z "$unique" || "$unique" =~ $identifier_pattern ]] || die 'Invalid DB_UNIQUE_NAME.'
    [[ -n "$sid_list" && "$sid_list" != /* && "$sid_list" != */ && "$sid_list" != *//* ]] || die 'Invalid SID list.'
    IFS='/' read -r -a one_sids <<< "$sid_list"
    for sid in "${one_sids[@]}"; do
        [[ "$sid" =~ $identifier_pattern ]] || die 'Invalid SID.'
    done
    [[ -z "${seen[$db]:-}" ]] || die "Duplicate database label: $db"
    seen[$db]=1
    dbs+=("$db"); sids+=("$sid_list"); cdbs+=("$cdb"); pdbs+=("${pdb:-CDBROOT}"); uniques+=("${unique:-ANY}")
done < "$db_list"
(( ${#dbs[@]} > 0 )) || die 'Database list is empty.'

mkdir -p "$output_root"
output_root="$(cd -- "$output_root" && pwd)"
run_dir="$(mktemp -d "$output_root/run_$(date -u '+%Y%m%dT%H%M%SZ')_XXXXXX")"
cp "$db_list" "$run_dir/db_list.conf"
cp "$accounts" "$run_dir/functional_accounts.csv"
printf 'database,module,sid,status,detail\n' > "$run_dir/execution_status.csv"
printf 'version,2.1\ncollected_at_utc,%s\nthreshold,%s\nbasis,%s\nwaste_mb,%s\nwaste_pct,%s\nexpiry_days,%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$threshold" "$basis" "$waste_mb" "$waste_pct" "$expiry_days" > "$run_dir/run_settings.csv"
failed=0
for (( idx=0; idx<${#dbs[@]}; idx++ )); do
    db="${dbs[$idx]}"
    mkdir -p "$run_dir/$db/logs"
    IFS='/' read -r -a one_sids <<< "${sids[$idx]}"
    printf 'Checking %s (%s)\n' "$db" "${pdbs[$idx]}"
    for module in "${modules[@]}"; do
        ok=0
        for sid in "${one_sids[@]}"; do
            log="$run_dir/$db/logs/${module}_${sid}.log"
            tmp="$run_dir/$db/${module}.tmp"
            mode=TARGET
            [[ "$module" == undo ]] && mode=ROOT
            # A subshell isolates every oraenv invocation. SQL output is published only on success.
            if (
                export ORACLE_SID="$sid" ORAENV_ASK=NO NLS_LANG=AMERICAN_AMERICA.AL32UTF8
                unset TWO_TASK LOCAL
                set +eu
                . "$oraenv_path" >"$log" 2>&1
                env_rc=$?
                set -euo pipefail
                (( env_rc == 0 )) || exit 1
                command -v sqlplus >/dev/null || exit 1
                cd "$script_dir/sql"
                if ! sqlplus -L -s "/ as sysdba" @"$module.sql" \
                    "$db" "${pdbs[$idx]}" "${cdbs[$idx]}" "${uniques[$idx]}" \
                    "$threshold" "$basis" "$expiry_days" "$mode" "$waste_mb" "$waste_pct" >"$tmp" 2>>"$log"; then
                    exit 1
                fi
                # WHENEVER SQLERROR does not catch SQL*Plus SP2 errors.
                ! LC_ALL=C grep -Eq '^[[:space:]]*(ORA|SP2|TNS|LRM)-[0-9]+' "$tmp" "$log"
            ); then
                mv "$tmp" "$run_dir/$db/$module.csv"
                printf '%s,%s,%s,SUCCESS,completed\n' "$db" "$module" "$sid" >> "$run_dir/execution_status.csv"
                ok=1
                break
            else
                if [[ -f "$tmp" ]]; then cat "$tmp" >> "$log"; rm -f "$tmp"; fi
                printf '%s,%s,%s,ATTEMPT_FAILED,see database logs\n' "$db" "$module" "$sid" >> "$run_dir/execution_status.csv"
            fi
        done
        if (( ! ok )); then
            printf '%s,%s,,FAILED,all local SIDs failed\n' "$db" "$module" >> "$run_dir/execution_status.csv"
            failed=1
        fi
    done
done
printf 'Collection saved: %s\n' "$run_dir"
if (( ! collect_only )); then
    args=("$script_dir/report.py" "$run_dir")
    if ! python3 "${args[@]}"; then failed=1; fi
else
    printf 'Report pending: python3 report.py "%s" \n' "$run_dir"
fi
exit "$failed"
