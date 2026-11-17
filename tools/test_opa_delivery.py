#!/usr/bin/env python3
"""Tests del CLI opa_delivery (make cli-test). Solo librería estándar."""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import opa_delivery  # noqa: E402

REPO_DATA = opa_delivery.DEFAULT_DATA
EXAMPLE_SPEC = os.path.join(opa_delivery.ROOT_DIR, "examples", "changes", "example.json")

# Data fija: los tests de operaciones no dependen del contenido real de
# policies/authz/data.json (que cambia con cada delivery).
FIXTURE = {
    "caller_claim": "role",
    "public_paths": ["/", "/health", "/healthz"],
    "callers": {
        "guest": {
            "description": "fixture",
            "endpoints": [
                {"path": "/api/client/v1", "methods": ["GET", "POST"]},
                {"path": "/api/server/v1", "methods": ["GET", "POST"]},
            ],
        }
    },
}


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.data = os.path.join(self.tmp, "data.json")
        with open(self.data, "w") as fh:
            json.dump(FIXTURE, fh)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = opa_delivery.main(["--data", self.data] + list(args))
        return rc, out.getvalue(), err.getvalue()

    def load(self):
        with open(self.data) as fh:
            return json.load(fh)

    def endpoints(self, caller):
        return {e["path"]: e["methods"] for e in self.load()["callers"][caller]["endpoints"]}


class TestRepoData(CliTestCase):
    def test_repo_data_is_valid(self):
        shutil.copy(REPO_DATA, self.data)
        rc, out, err = self.run_cli("validate")
        self.assertEqual(rc, 0, out + err)

    def test_repo_data_is_normalized(self):
        """data.json del repo debe estar en formato canónico (diffs limpios)."""
        with open(REPO_DATA) as fh:
            raw = fh.read()
        data = opa_delivery.normalize(json.loads(raw))
        expected = json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        self.assertEqual(raw, expected, "ejecuta una operación del CLI para normalizar data.json")


class TestOperations(CliTestCase):
    def test_add_endpoint_creates_caller(self):
        rc, _, _ = self.run_cli("add-endpoint", "--caller", "admin", "--path", "/api/x", "--methods", "get,post")
        self.assertEqual(rc, 0)
        self.assertEqual(self.endpoints("admin"), {"/api/x": ["GET", "POST"]})

    def test_add_endpoint_merges_methods(self):
        self.run_cli("add-endpoint", "--caller", "guest", "--path", "/api/server/v1", "--methods", "DELETE")
        self.assertEqual(self.endpoints("guest")["/api/server/v1"], ["DELETE", "GET", "POST"])

    def test_add_endpoint_is_idempotent(self):
        self.run_cli("add-endpoint", "--caller", "admin", "--path", "/api/x", "--methods", "GET")
        before = self.load()
        rc, out, _ = self.run_cli("add-endpoint", "--caller", "admin", "--path", "/api/x", "--methods", "GET")
        self.assertEqual(rc, 0)
        self.assertIn("Sin cambios", out)
        self.assertEqual(self.load(), before)

    def test_remove_some_methods(self):
        self.run_cli("remove-endpoint", "--caller", "guest", "--path", "/api/server/v1", "--methods", "POST")
        self.assertEqual(self.endpoints("guest")["/api/server/v1"], ["GET"])

    def test_remove_last_method_removes_endpoint(self):
        self.run_cli("remove-endpoint", "--caller", "guest", "--path", "/api/server/v1", "--methods", "GET,POST")
        self.assertNotIn("/api/server/v1", self.endpoints("guest"))

    def test_remove_whole_endpoint(self):
        self.run_cli("remove-endpoint", "--caller", "guest", "--path", "/api/client/v1")
        self.assertNotIn("/api/client/v1", self.endpoints("guest"))

    def test_remove_missing_is_noop(self):
        rc, out, _ = self.run_cli("remove-endpoint", "--caller", "nobody", "--path", "/x")
        self.assertEqual(rc, 0)
        self.assertIn("Sin cambios", out)

    def test_add_and_remove_caller(self):
        self.run_cli("add-caller", "--caller", "ops", "--description", "Operaciones")
        self.assertEqual(self.load()["callers"]["ops"], {"description": "Operaciones", "endpoints": []})
        self.run_cli("remove-caller", "--caller", "ops")
        self.assertNotIn("ops", self.load()["callers"])

    def test_public_paths(self):
        self.run_cli("add-public-path", "--path", "/metrics")
        self.assertIn("/metrics", self.load()["public_paths"])
        self.run_cli("remove-public-path", "--path", "/metrics")
        self.assertNotIn("/metrics", self.load()["public_paths"])

    def test_set_caller_claim(self):
        self.run_cli("set-caller-claim", "--claim", "sub")
        self.assertEqual(self.load()["caller_claim"], "sub")

    def test_apply_spec(self):
        rc, _, _ = self.run_cli("apply", "--spec", EXAMPLE_SPEC)
        self.assertEqual(rc, 0)
        self.assertIn("admin", self.load()["callers"])
        self.assertIn("/api/server/v2/*", self.endpoints("guest"))

    def test_dry_run_does_not_write(self):
        before = self.load()
        rc, out, _ = self.run_cli("--dry-run", "remove-caller", "--caller", "guest")
        self.assertEqual(rc, 0)
        self.assertIn("dry-run", out)
        self.assertEqual(self.load(), before)


class TestValidation(CliTestCase):
    def assert_rejected(self, *args):
        before = self.load()
        rc, _, err = self.run_cli(*args)
        self.assertNotEqual(rc, 0)
        self.assertIn("ERROR", err)
        self.assertEqual(self.load(), before, "no debe escribir si falla")

    def test_path_must_start_with_slash(self):
        self.assert_rejected("add-endpoint", "--caller", "guest", "--path", "api", "--methods", "GET")

    def test_invalid_method(self):
        self.assert_rejected("add-endpoint", "--caller", "guest", "--path", "/x", "--methods", "FOO")

    def test_methods_required_on_add(self):
        self.assert_rejected("add-endpoint", "--caller", "guest", "--path", "/x")

    def test_invalid_caller_name(self):
        self.assert_rejected("add-caller", "--caller", "con espacio")

    def test_invalid_spec(self):
        spec = os.path.join(self.tmp, "bad.json")
        with open(spec, "w") as fh:
            json.dump({"operations": [{"op": "nope"}]}, fh)
        self.assert_rejected("apply", "--spec", spec)

    def test_validate_detects_bad_file(self):
        with open(self.data, "w") as fh:
            json.dump({"caller_claim": "", "public_paths": ["x"], "callers": {
                "a": {"endpoints": [{"path": "/x", "methods": []}, {"path": "/x", "methods": ["GET"]}]}}}, fh)
        rc, _, err = self.run_cli("validate")
        self.assertEqual(rc, 1)
        for fragment in ("caller_claim", "public_paths", "methods debe ser", "duplicado"):
            self.assertIn(fragment, err)


if __name__ == "__main__":
    unittest.main()
