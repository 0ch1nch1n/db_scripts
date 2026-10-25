import contextlib
import csv
import io
import json
import tempfile
import unittest
from pathlib import Path

import export_redshift_permissions as audit


class FakeCursor:
    def __init__(self, datasets, fail):
        self.datasets, self.fail = datasets, fail
        self.description = None
        self.rows = []

    def execute(self, sql):
        name = next(name for name, query in audit.QUERIES if query == sql)
        if name == self.fail:
            raise RuntimeError("test permission denied")
        columns, rows = self.datasets[name]
        self.description = [(column,) for column in columns]
        self.rows = list(rows)

    def fetchmany(self, count):
        result, self.rows = self.rows[:count], self.rows[count:]
        return result

    def close(self):
        pass


class FakeConnection:
    def __init__(self, superuser=True, fail=None):
        self.fail = fail
        self.datasets = {}
        for name, _ in audit.QUERIES:
            self.datasets[name] = (["identity_name", "identity_type", "privilege_type"], [])
        self.datasets.update({
            "00_context": (["database_name", "is_superuser"], [["redshiftdb", superuser]]),
            "10_roles": (["role_name"], [["reader"], ["writer"], ["empty"]]),
            "11_users": (["user_id", "user_name", "is_superuser"],
                         [[1, "alice", False], [2, "no_role", True]]),
            "20_user_role_grants": (["user_name", "role_name", "admin_option"], [["alice", "writer", False]]),
            "21_role_role_grants": (["role_name", "granted_role_name"], [["writer", "reader"]]),
            "33_relation_privileges": (["identity_name", "identity_type", "privilege_type", "namespace_name", "relation_name"],
                [["reader", "role", "SELECT", "业务", 'table,"x"'],
                 ["alice", "user", "INSERT", "public", "t"],
                 ["public", "public", "SELECT", "public", "t"]]),
            "36_default_privileges": (["grantee_name", "grantee_type", "privilege_type", "owner_name", "object_type"],
                                     [["reader", "role", "SELECT", "owner", "RELATION"]]),
        })

    def cursor(self):
        return FakeCursor(self.datasets, self.fail)


class ExportTests(unittest.TestCase):
    def test_csv_roundtrip_and_empty_header(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.csv"
            self.assertEqual(audit.write_csv(path, ["name", "detail"], [["中文", 'a,"b"\nc']]), 1)
            self.assertEqual(list(audit.read_csv(path)), [{"name": "中文", "detail": 'a,"b"\nc'}])
            self.assertTrue(path.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertEqual(audit.write_csv(path, ["name"], []), 0)
            self.assertEqual(path.read_text(encoding="utf-8-sig").strip(), "name")

    def test_partial_csv_is_not_published(self):
        def broken():
            yield ["first"]
            raise RuntimeError("network interrupted")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.csv"
            with self.assertRaises(RuntimeError):
                audit.write_csv(path, ["name"], broken())
            self.assertFalse(path.exists())
            self.assertTrue(path.with_suffix(".csv.part").exists())

    def test_direction_shortest_path_and_cycle(self):
        graph = {"admin": {"writer", "reader"}, "writer": {"reader"}, "reader": {"admin"}}
        self.assertEqual(audit.role_closure("admin", graph), {"admin": 0, "reader": 1, "writer": 1})
        self.assertEqual(audit.role_closure("reader", {"writer": {"reader"}}), {"reader": 0})

    def run_export(self, output, connection):
        manifest = {"database": "redshiftdb"}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = audit.run_audit(connection, output, manifest)
        return status, json.loads((output / "manifest.json").read_text())

    def test_full_mock_export_including_inheritance_and_all_identity_types(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            status, manifest = self.run_export(output, FakeConnection())
            self.assertEqual(status, 0)
            self.assertEqual(manifest["status"], "complete")
            direct = list(audit.read_csv(output / "user_roles_direct.csv"))
            self.assertEqual(direct[1]["role_name"], "")
            expanded = list(audit.read_csv(output / "user_roles_expanded.csv"))
            self.assertTrue(any(r["user_name"] == "alice" and r["role_name"] == "reader"
                                and r["inheritance_depth"] == "1" for r in expanded))
            self.assertTrue(any(r["assignment_type"] == "NO_EXPLICIT_ROLE" for r in expanded))
            permissions = list(audit.read_csv(output / "role_permissions.csv"))
            self.assertEqual(len(permissions), 4)
            self.assertTrue(any(r["role_name"] == "writer" and r["source_role_name"] == "reader"
                                and r["inheritance_depth"] == "1" for r in permissions))
            self.assertFalse(any(r["source_role_name"] in ("alice", "public") for r in permissions))
            self.assertEqual(len(list(audit.read_csv(output / "33_relation_privileges.csv"))), 3)
            self.assertEqual(len(list(audit.read_csv(output / "role_permissions_direct.csv"))), 2)
            self.assertTrue(all(e["status"] == "success" for e in manifest["exports"]))
            self.assertTrue((output / "export_status.csv").exists())

    def test_failed_module_does_not_look_like_zero_rows_or_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            status, manifest = self.run_export(output, FakeConnection(fail="33_relation_privileges"))
            self.assertEqual(status, 2)
            self.assertFalse((output / "33_relation_privileges.csv").exists())
            failed = next(e for e in manifest["exports"] if e["file"] == "33_relation_privileges.csv")
            self.assertIsNone(failed["rows"])
            self.assertEqual(failed["status"], "failed")
            self.assertTrue((output / "40_ml_model_privileges.csv").exists())

    def test_no_expansion_when_membership_source_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            status, _ = self.run_export(output, FakeConnection(fail="21_role_role_grants"))
            self.assertEqual(status, 2)
            self.assertFalse((output / "role_permissions.csv").exists())
            self.assertFalse((output / "user_roles_expanded.csv").exists())

    def test_normal_user_visibility_is_unverified_even_when_queries_succeed(self):
        with tempfile.TemporaryDirectory() as directory:
            status, manifest = self.run_export(Path(directory), FakeConnection(superuser=False))
            self.assertEqual(status, 2)
            self.assertTrue(manifest["warnings"])

    def test_cluster_grant_is_not_mislabeled_as_database_specific(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            connection = FakeConnection()
            connection.datasets["30_system_privileges"] = (
                ["identity_name", "identity_type", "system_privilege"],
                [["writer", "role", "CREATE USER"]])
            self.run_export(output, connection)
            permissions = list(audit.read_csv(output / "role_permissions.csv"))
            system = next(row for row in permissions if row["permission_category"] == "system_privileges")
            self.assertEqual(system["database_name"], "")
            table = next(row for row in permissions if row["permission_category"] == "relation_privileges")
            self.assertEqual(table["database_name"], "redshiftdb")

    def test_queries_are_select_only_and_print_requires_no_connection(self):
        self.assertTrue(all(sql.strip().upper().startswith("SELECT ") for _, sql in audit.QUERIES))
        result = io.StringIO()
        with contextlib.redirect_stdout(result):
            self.assertEqual(audit.main(["--print-sql"]), 0)
        self.assertIn("svv_role_grants", result.getvalue())


if __name__ == "__main__":
    unittest.main()
