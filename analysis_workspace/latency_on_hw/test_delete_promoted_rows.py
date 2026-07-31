#!/usr/bin/env python3

from __future__ import annotations

import csv
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from analysis_workspace.latency_on_hw.delete_promoted_rows import (
    delete_promoted_rows,
    find_raw_dbs,
    main,
)


FIELDNAMES = ["run_id", "app", "args", "status"]


def write_raw_db(path: Path, rows: list[dict[str, str]], fieldnames=FIELDNAMES) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def read_raw_db(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


class DeletePromotedRowsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_root_selects_only_direct_sub_root_databases(self) -> None:
        first = self.root / "C1" / "raw_db.csv"
        second = self.root / "C2" / "raw_db.csv"
        nested = self.root / "C1" / "runs" / "probe" / "raw_db.csv"
        for path in (first, second, nested):
            write_raw_db(path, [])

        self.assertEqual(find_raw_dbs(self.root), [first, second])
        self.assertEqual(find_raw_dbs(self.root / "C1"), [first])

    def test_dry_run_reports_exact_marker_without_writing(self) -> None:
        raw_db = self.root / "C1" / "raw_db.csv"
        rows = [
            {"run_id": "normal", "app": "silu", "args": "-m 1,-k 32", "status": "pass"},
            {
                "run_id": "interpolation_refine",
                "app": "hadamard",
                "args": "-n 128",
                "status": "pass",
            },
            {"run_id": "interpolation_refine_extra", "app": "rope", "args": "", "status": "pass"},
        ]
        write_raw_db(raw_db, rows)
        original = raw_db.read_bytes()

        results = delete_promoted_rows(self.root / "C1", dry_run=True)

        self.assertEqual(results[0].promoted_rows, 1)
        self.assertIsNone(results[0].backup)
        self.assertEqual(raw_db.read_bytes(), original)
        self.assertEqual(list(raw_db.parent.glob("raw_db.csv.bak.*")), [])

    def test_dry_run_cli_prints_app_and_representative_args(self) -> None:
        raw_db = self.root / "C1" / "raw_db.csv"
        rows = [
            {
                "run_id": "interpolation_refine",
                "app": "hadamard",
                "args": f"-n {size}",
                "status": "pass",
            }
            for size in (128, 256, 512, 1024)
        ]
        write_raw_db(raw_db, rows)
        output = io.StringIO()

        with redirect_stdout(output):
            returncode = main(["--dry-run", str(self.root / "C1")])

        self.assertEqual(returncode, 0)
        report = output.getvalue()
        self.assertIn("hadamard: 4 row(s)", report)
        self.assertIn("args: -n 128", report)
        self.assertIn("... 1 more unique args", report)
        self.assertNotIn("args: -n 1024", report)

    def test_delete_preserves_other_rows_and_creates_backup(self) -> None:
        raw_db = self.root / "C1" / "raw_db.csv"
        rows = [
            {"run_id": "normal", "app": "silu", "args": "-m 1,-k 32", "status": "pass"},
            {"run_id": " interpolation_refine ", "app": "hadamard", "args": "-n 128", "status": "pass"},
        ]
        write_raw_db(raw_db, rows)

        results = delete_promoted_rows(self.root)

        self.assertEqual(results[0].promoted_rows, 1)
        self.assertIsNotNone(results[0].backup)
        assert results[0].backup is not None
        self.assertTrue(results[0].backup.is_file())
        self.assertEqual(read_raw_db(results[0].backup), rows)
        self.assertEqual(read_raw_db(raw_db), rows[:1])

    def test_all_databases_are_validated_before_any_write(self) -> None:
        valid = self.root / "C1" / "raw_db.csv"
        invalid = self.root / "C2" / "raw_db.csv"
        promoted = {"run_id": "interpolation_refine", "app": "silu", "args": "", "status": "pass"}
        write_raw_db(valid, [promoted])
        write_raw_db(invalid, [{"app": "silu"}], fieldnames=["app"])
        original = valid.read_bytes()

        with self.assertRaisesRegex(ValueError, "run_id"):
            delete_promoted_rows(self.root)

        self.assertEqual(valid.read_bytes(), original)
        self.assertEqual(list(valid.parent.glob("raw_db.csv.bak.*")), [])


if __name__ == "__main__":
    unittest.main()
