#!/usr/bin/env python3
"""Read-only Redshift grant inventory. Python 3.9+; AWS redshift_connector."""

import argparse
import csv
import getpass
import json
import os
import sys
from collections import defaultdict, deque
from datetime import datetime, timezone
from pathlib import Path


# Only SELECT statements are sent to Redshift. Inheritance is expanded locally.
QUERIES = [
    ("00_context", """SELECT current_database() AS database_name,
        current_user AS database_user, GETDATE() AS server_time,
        version() AS engine_version, u.usesuper AS is_superuser
        FROM pg_user u WHERE u.usename = current_user"""),
    ("10_roles", "SELECT * FROM svv_roles ORDER BY role_name"),
    ("11_users", """SELECT usesysid AS user_id, usename AS user_name,
        usesuper AS is_superuser, usecreatedb AS can_create_database
        FROM pg_user ORDER BY usename"""),
    ("20_user_role_grants", "SELECT * FROM svv_user_grants ORDER BY user_name, role_name"),
    ("21_role_role_grants", "SELECT * FROM svv_role_grants ORDER BY role_name, granted_role_name"),
    ("30_system_privileges", "SELECT * FROM svv_system_privileges"),
    ("31_database_privileges", "SELECT * FROM svv_database_privileges"),
    ("32_schema_privileges", "SELECT * FROM svv_schema_privileges"),
    ("33_relation_privileges", "SELECT * FROM svv_relation_privileges"),
    ("34_column_privileges", "SELECT * FROM svv_column_privileges"),
    ("35_function_privileges", "SELECT * FROM svv_function_privileges"),
    ("36_default_privileges", "SELECT * FROM svv_default_privileges"),
    ("37_iam_privileges", "SELECT * FROM svv_iam_privileges"),
    ("38_language_privileges", "SELECT * FROM svv_language_privileges"),
    ("39_datashare_privileges", "SELECT * FROM svv_datashare_privileges"),
    ("40_ml_model_privileges", "SELECT * FROM svv_ml_model_privileges"),
]

PERMISSION_COLUMNS = [
    "role_name", "source_role_name", "inheritance_depth", "permission_category",
    "database_name", "schema_name", "object_name", "column_name",
    "privilege_type", "privilege_scope", "admin_option", "owner_name",
    "source_csv", "details_json",
]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sql_text():
    return "\n\n".join("-- " + name + ".csv\n" + sql.strip() + ";" for name, sql in QUERIES) + "\n"


def read_csv(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        yield from csv.DictReader(stream)


def write_csv(path, columns, rows):
    """Publish a CSV only after writing it completely; retain .part on failure."""
    path = Path(path)
    partial = path.with_suffix(path.suffix + ".part")
    count = 0
    with partial.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(columns)
        for row in rows:
            writer.writerow(row)
            count += 1
    partial.replace(path)
    return count


def export_query(connection, sql, path):
    cursor = connection.cursor()
    try:
        cursor.execute(sql)
        columns = [str(item[0]).lower() for item in cursor.description]

        def rows():
            while True:
                batch = cursor.fetchmany(1000)
                if not batch:
                    break
                yield from batch

        return write_csv(path, columns, rows())
    finally:
        cursor.close()


def role_closure(start, graph):
    """A role inherits granted_role_name. Return shortest distance, including self."""
    distances = {start: 0}
    queue = deque([start])
    while queue:
        current = queue.popleft()
        for inherited in sorted(graph.get(current, ())):
            if inherited not in distances:
                distances[inherited] = distances[current] + 1
                queue.append(inherited)
    return distances


def build_memberships(output):
    users = list(read_csv(output / "11_users.csv"))
    roles = {r["role_name"] for r in read_csv(output / "10_roles.csv")}
    grants = list(read_csv(output / "20_user_role_grants.csv"))
    graph = defaultdict(set)
    by_user = defaultdict(list)
    for row in read_csv(output / "21_role_role_grants.csv"):
        graph[row["role_name"]].add(row["granted_role_name"])
        roles.update((row["role_name"], row["granted_role_name"]))
    for row in grants:
        by_user[row["user_name"]].append(row)
        roles.add(row["role_name"])

    def direct_rows():
        # Preserve even users with no explicitly granted role.
        for user in users:
            for grant in by_user.get(user["user_name"], [None]):
                yield [user["user_name"], user["is_superuser"],
                       grant["role_name"] if grant else "",
                       grant["admin_option"] if grant else ""]

    direct_count = write_csv(output / "user_roles_direct.csv",
                             ["user_name", "is_superuser", "role_name", "admin_option"], direct_rows())

    def expanded_rows():
        for user in users:
            if user["user_name"] not in by_user:
                yield [user["user_name"], user["is_superuser"], "", "", "", "NO_EXPLICIT_ROLE"]
            for grant in by_user.get(user["user_name"], []):
                direct = grant["role_name"]
                for role, depth in sorted(role_closure(direct, graph).items()):
                    yield [user["user_name"], user["is_superuser"], direct, role, depth,
                           "DIRECT" if depth == 0 else "INHERITED"]

    expanded_count = write_csv(output / "user_roles_expanded.csv",
        ["user_name", "is_superuser", "direct_role_name", "role_name", "inheritance_depth", "assignment_type"],
        expanded_rows())
    return roles, graph, direct_count, expanded_count


def permission_rows(output, modules, database, recipients=None):
    local_object_modules = {
        "32_schema_privileges", "33_relation_privileges", "34_column_privileges",
        "35_function_privileges", "36_default_privileges", "38_language_privileges",
        "40_ml_model_privileges",
    }
    for module in modules:
        for row in read_csv(output / (module + ".csv")):
            if row.get("identity_type", row.get("grantee_type", "")).lower() != "role":
                continue
            source = row.get("identity_name", row.get("grantee_name", ""))
            if not source:
                raise ValueError("Role grant has no identity/grantee name in " + module)
            targets = recipients.get(source, [(source, 0)]) if recipients is not None else [(source, 0)]
            for target, depth in targets:
                yield [target, source, depth, module[3:],
                       row.get("database_name", database if module in local_object_modules else ""),
                       row.get("namespace_name", row.get("schema_name", "")),
                       row.get("relation_name", row.get("function_name", row.get("model_name",
                           row.get("datashare_name", row.get("iam_arn", row.get("language_name", "")))))),
                       row.get("column_name", ""),
                       row.get("privilege_type", row.get("system_privilege", row.get("command_type", ""))),
                       row.get("privilege_scope", ""), row.get("admin_option", ""),
                       row.get("owner_name", ""), module + ".csv",
                       json.dumps(row, ensure_ascii=False, sort_keys=True)]


def write_manifest(output, manifest):
    partial = output / "manifest.json.part"
    partial.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    partial.replace(output / "manifest.json")


def run_audit(connection, output, manifest, redact=lambda value: value):
    manifest["status"] = "running"
    manifest["exports"] = []
    manifest["warnings"] = []
    write_manifest(output, manifest)
    successful = set()
    for name, sql in QUERIES:
        entry = {"file": name + ".csv", "started_at_utc": utc_now()}
        try:
            count = export_query(connection, sql, output / entry["file"])
            entry.update(status="success", rows=count)
            successful.add(name)
            print("OK    {:34s} {:>8d} rows".format(entry["file"], count), flush=True)
        except Exception as error:
            entry.update(status="failed", rows=None, error=redact(str(error)))
            print("FAIL  {}: {}".format(entry["file"], entry["error"]), file=sys.stderr, flush=True)
        entry["finished_at_utc"] = utc_now()
        manifest["exports"].append(entry)
        write_manifest(output, manifest)

    superuser = False
    if "00_context" in successful:
        context = list(read_csv(output / "00_context.csv"))
        manifest["context"] = context
        superuser = bool(context and context[0].get("is_superuser", "").lower() in ("true", "t", "1"))
    if not superuser:
        manifest["warnings"].append(
            "Superuser visibility was not verified. Successful queries or zero rows do not prove complete visibility.")

    membership_sources = {"10_roles", "11_users", "20_user_role_grants", "21_role_role_grants"}
    permission_modules = [name for name, _ in QUERIES if name[:2].isdigit() and int(name[:2]) >= 30]
    available_permissions = [name for name in permission_modules if name in successful]
    try:
        direct_count = write_csv(output / "role_permissions_direct.csv", PERMISSION_COLUMNS,
            permission_rows(output, available_permissions, manifest["database"]))
        manifest["exports"].append({"file": "role_permissions_direct.csv", "status": "success",
                                    "rows": direct_count, "coverage": "available successful permission modules"})
        if membership_sources <= successful:
            roles, graph, direct, expanded = build_memberships(output)
            recipients = defaultdict(list)
            for role in sorted(roles):
                for source, depth in role_closure(role, graph).items():
                    recipients[source].append((role, depth))
            count = write_csv(output / "role_permissions.csv", PERMISSION_COLUMNS,
                permission_rows(output, available_permissions, manifest["database"], recipients))
            for name, rows in [("user_roles_direct.csv", direct), ("user_roles_expanded.csv", expanded),
                               ("role_permissions.csv", count)]:
                manifest["exports"].append({"file": name, "status": "success", "rows": rows})
        else:
            manifest["warnings"].append("Membership source exports failed; expanded membership/permissions were not generated.")
    except Exception as error:
        manifest["exports"].append({"file": "derived_reports", "status": "failed", "error": redact(str(error))})

    failures = [e for e in manifest["exports"] if e["status"] == "failed"]
    if failures:
        manifest["warnings"].append("Combined permission CSVs cover only successful source exports; inspect failed modules.")
    manifest["status"] = "complete" if not failures and superuser else "partial_or_visibility_unverified"
    manifest["finished_at_utc"] = utc_now()
    write_csv(output / "export_status.csv", ["file", "status", "rows", "error"],
              ([e["file"], e["status"], e.get("rows", ""), e.get("error", "")] for e in manifest["exports"]))
    write_manifest(output, manifest)
    for warning in manifest["warnings"]:
        print("WARNING: " + warning, file=sys.stderr)
    print("\nStatus: {}\nOutput: {}".format(manifest["status"], output))
    return 0 if manifest["status"] == "complete" else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export Redshift roles/grants to CSV using read-only SELECT queries.")
    parser.add_argument("--host", help="Redshift endpoint, without https:// or port")
    parser.add_argument("--port", type=int, default=5439)
    parser.add_argument("--database", default="redshiftdb")
    parser.add_argument("--user", help="Database user")
    parser.add_argument("--out", type=Path, help="New output directory (must not already exist)")
    parser.add_argument("--connect-timeout", type=int, default=20)
    parser.add_argument("--print-sql", action="store_true", help="Print collection SQL without connecting or requiring the driver")
    args = parser.parse_args(argv)
    if args.print_sql:
        print(sql_text(), end="")
        return 0
    if not args.host or not args.user:
        parser.error("--host and --user are required, unless using --print-sql")
    if not 1 <= args.port <= 65535 or args.connect_timeout <= 0:
        parser.error("port must be 1..65535 and connect-timeout must be positive")
    try:
        import redshift_connector
    except ImportError:
        print("Missing AWS driver. Install: python -m pip install -r requirements.txt", file=sys.stderr)
        return 1
    if args.out and args.out.exists():
        parser.error("--out already exists. Choose a new directory to preserve earlier exports.")
    password = os.environ.get("REDSHIFT_PASSWORD")
    if password is None:
        if not sys.stdin.isatty():
            parser.error("No interactive terminal. Set REDSHIFT_PASSWORD through your secret-management environment.")
        password = getpass.getpass("Redshift password (hidden): ")
    if not password:
        parser.error("Password must not be empty")

    output = (args.out or Path(__file__).resolve().parent / "exports" /
              datetime.now(timezone.utc).strftime("audit_%Y%m%dT%H%M%S_%fZ")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "queries.sql").write_text(sql_text(), encoding="utf-8")
    manifest = {
        "started_at_utc": utc_now(), "host": args.host, "port": args.port,
        "database": args.database, "requested_user": args.user,
        "status": "connecting", "sslmode": "verify-full", "encoding": "UTF-8 with BOM",
        "scope": "Explicit grants plus role inheritance; local object views cover the connected database.",
        "limits": ["Sequential queries, not an atomic snapshot; concurrent grant changes can affect consistency.",
                   "Does not evaluate implicit superuser/owner access, legacy group membership, RLS/DDM policies or ephemeral federated session membership.",
                   "Raw permission CSVs include all visible identity types; combined role CSVs include roles only.",
                   "Default privileges are future-object rules, not permissions on existing objects.",
                   "No explicit grants does not mean no effective access; PUBLIC and user grants are in raw files."],
    }
    write_manifest(output, manifest)
    connection = None

    def redact(value):
        return value.replace(password, "[REDACTED]")

    try:
        connection = redshift_connector.connect(
            host=args.host, port=args.port, database=args.database, user=args.user,
            password=password, ssl=True, sslmode="verify-full", timeout=args.connect_timeout,
            application_name="redshift_permission_audit")
        connection.autocommit = True
        return run_audit(connection, output, manifest, redact)
    except KeyboardInterrupt:
        manifest.update(status="interrupted", finished_at_utc=utc_now())
        write_manifest(output, manifest)
        print("\nInterrupted. Partial results: " + str(output), file=sys.stderr)
        return 130
    except Exception as error:
        manifest.update(status="failed", error=redact(str(error)), finished_at_utc=utc_now())
        write_manifest(output, manifest)
        print("Failed: {}\nDetails: {}".format(manifest["error"], output / "manifest.json"), file=sys.stderr)
        return 1
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    sys.exit(main())
