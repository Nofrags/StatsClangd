import csv
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path("scripts/report_diagnostics.py")


class ReportDiagnosticsTests(unittest.TestCase):
    def run_script(self, payload, extra_args=None):
        extra_args = extra_args or []
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            input_file = td_path / "in.json"
            out_simple = td_path / "simple.csv"
            out_detailed = td_path / "detailed.csv"
            input_file.write_text(json.dumps(payload), encoding="utf-8")

            cmd = [
                "python3",
                str(SCRIPT),
                "--input",
                str(input_file),
                "--out-simple",
                str(out_simple),
                "--out-detailed",
                str(out_detailed),
                *extra_args,
            ]
            result = subprocess.run(cmd, check=False, capture_output=True, text=True)

            simple_rows = []
            detailed_rows = []
            if out_simple.exists():
                with out_simple.open("r", encoding="utf-8", newline="") as f:
                    simple_rows = list(csv.reader(f, delimiter=";"))
            if out_detailed.exists():
                with out_detailed.open("r", encoding="utf-8", newline="") as f:
                    detailed_rows = list(csv.reader(f, delimiter=";"))

            return result, simple_rows, detailed_rows

    def test_csv_formula_injection_is_sanitized(self):
        payload = {
            "diagnostics": [
                {
                    "source": "clangd",
                    "message": "=2+2",
                    "file": "@danger.c",
                    "code": "+SUM(A1)",
                }
            ]
        }
        result, simple_rows, detailed_rows = self.run_script(payload)
        self.assertEqual(result.returncode, 0, msg=result.stderr)

        self.assertEqual(simple_rows[1][2], "'@danger.c")
        self.assertEqual(detailed_rows[1][2], "'@danger.c")
        self.assertEqual(detailed_rows[1][5], "'+SUM(A1)")
        self.assertEqual(detailed_rows[1][7], "'=2+2")

    def test_day_and_version_are_present(self):
        payload = {
            "diagnostics": [
                {"source": "clangd", "message": "ok", "file": "a.c", "code": "unused-includes"}
            ]
        }
        result, simple_rows, detailed_rows = self.run_script(
            payload, ["--day", "2026-01-01", "--version", "release-42"]
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(simple_rows[0][:2], ["day", "version"])
        self.assertEqual(simple_rows[1][0:2], ["2026-01-01", "release-42"])
        self.assertEqual(detailed_rows[0][:2], ["day", "version"])
        self.assertEqual(detailed_rows[1][0:2], ["2026-01-01", "release-42"])

    def test_max_items_limits_output(self):
        payload = {
            "diagnostics": [
                {"source": "clangd", "message": "m1", "file": "a.c"},
                {"source": "clangd", "message": "m2", "file": "b.c"},
                {"source": "clangd", "message": "m3", "file": "c.c"},
            ]
        }
        result, _, detailed_rows = self.run_script(payload, ["--max-items", "2"])
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(len(detailed_rows), 3)  # header + 2 rows

    def test_invalid_items_are_skipped(self):
        payload = {
            "diagnostics": [
                {"source": "clangd", "message": "ok", "file": "a.c"},
                {"source": 123, "message": "bad-source", "file": "b.c"},
                {"source": "clangd", "message": None, "file": "c.c"},
            ]
        }
        result, _, detailed_rows = self.run_script(payload)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("ignoré(s)", result.stderr)
        self.assertEqual(len(detailed_rows), 2)  # header + valid row

    def test_malformed_position_values_do_not_crash(self):
        payload = {
            "diagnostics": [
                {
                    "source": "clangd",
                    "message": "bad position",
                    "file": "a.c",
                    "startLineNumber": "abc",
                    "startColumn": "not-an-int",
                },
                {
                    "source": "clangd",
                    "message": "bad range",
                    "file": "b.c",
                    "range": {"start": {"line": "x", "character": "y"}},
                },
            ]
        }
        result, _, detailed_rows = self.run_script(payload)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(len(detailed_rows), 3)  # header + 2 rows
        self.assertEqual(detailed_rows[1][1], "")
        self.assertEqual(detailed_rows[1][2], "")
        self.assertEqual(detailed_rows[2][1], "")
        self.assertEqual(detailed_rows[2][2], "")


if __name__ == "__main__":
    unittest.main()
