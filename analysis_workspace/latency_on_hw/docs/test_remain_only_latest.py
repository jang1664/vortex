#!/usr/bin/env python3

from __future__ import annotations

import csv
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from analysis_workspace.latency_on_hw.remain_only_latest import (
    find_raw_dbs,
    main,
)


FIELDNAMES = [
    "run_id",
    "timestamp_utc",
    "xclbin_sha256",
    "app",
    "args",
    "fpga_cycle",
]


def write_raw_db(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def read_raw_db(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


class RemainOnlyLatestDryRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.raw_db = self.root / "raw_db.csv"
        self.rows = [
            {
                "run_id": "old-run",
                "timestamp_utc": "2026-07-30T01:00:00+00:00",
                "xclbin_sha256": "sha",
                "app": "silu",
                "args": "-n 128",
                "fpga_cycle": "200",
            },
            {
                "run_id": "new-run",
                "timestamp_utc": "2026-07-31T01:00:00+00:00",
                "xclbin_sha256": "sha",
                "app": "silu",
                "args": "-n 128",
                "fpga_cycle": "100",
            },
            {
                "run_id": "only-run",
                "timestamp_utc": "2026-07-31T02:00:00+00:00",
                "xclbin_sha256": "sha",
                "app": "hadamard",
                "args": "-rows 8 -dim 128 -K 1",
                "fpga_cycle": "300",
            },
        ]
        write_raw_db(self.raw_db, self.rows)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_dry_run_reports_removed_row_without_modifying_files(self) -> None:
        original = self.raw_db.read_bytes()
        output = io.StringIO()

        with redirect_stdout(output):
            returncode = main(["--dry-run", str(self.raw_db)])

        self.assertEqual(returncode, 0)
        self.assertEqual(self.raw_db.read_bytes(), original)
        self.assertEqual(list(self.root.glob("raw_db.csv.bak.*")), [])
        report = output.getvalue()
        self.assertIn("would remove 1 duplicate row(s)", report)
        self.assertIn("silu: 1 row(s)", report)
        self.assertIn("args='-n 128'", report)
        self.assertIn("timestamp=2026-07-30T01:00:00+00:00", report)
        self.assertIn("run_id=old-run", report)
        self.assertNotIn("hadamard: 1 row(s)", report)

    def test_normal_run_keeps_latest_and_creates_backup(self) -> None:
        returncode = main([str(self.raw_db)])

        self.assertEqual(returncode, 0)
        self.assertEqual(read_raw_db(self.raw_db), self.rows[1:])
        backups = list(self.root.glob("raw_db.csv.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(read_raw_db(backups[0]), self.rows)

    def test_output_root_processes_direct_sub_roots_only(self) -> None:
        output_root = self.root / "outputs"
        first = output_root / "C1" / "raw_db.csv"
        second = output_root / "C4_v3" / "raw_db.csv"
        nested = output_root / "C1" / "runs" / "probe" / "raw_db.csv"
        for raw_db in (first, second, nested):
            write_raw_db(raw_db, self.rows)
        nested_original = nested.read_bytes()
        output = io.StringIO()

        self.assertEqual(find_raw_dbs(output_root), [first, second])
        with redirect_stdout(output):
            returncode = main([str(output_root)])

        self.assertEqual(returncode, 0)
        self.assertEqual(read_raw_db(first), self.rows[1:])
        self.assertEqual(read_raw_db(second), self.rows[1:])
        self.assertEqual(nested.read_bytes(), nested_original)
        report = output.getvalue()
        self.assertIn(str(first), report)
        self.assertIn(str(second), report)
        self.assertIn("across 2 raw DB(s)", report)

    def test_output_root_dry_run_does_not_modify_any_sub_root(self) -> None:
        output_root = self.root / "outputs"
        raw_dbs = [
            output_root / "C1" / "raw_db.csv",
            output_root / "C3" / "raw_db.csv",
        ]
        for raw_db in raw_dbs:
            write_raw_db(raw_db, self.rows)
        originals = {raw_db: raw_db.read_bytes() for raw_db in raw_dbs}
        output = io.StringIO()

        with redirect_stdout(output):
            returncode = main(["--dry-run", str(output_root)])

        self.assertEqual(returncode, 0)
        for raw_db in raw_dbs:
            self.assertEqual(raw_db.read_bytes(), originals[raw_db])
            self.assertEqual(list(raw_db.parent.glob("raw_db.csv.bak.*")), [])
        self.assertIn(
            "would remove 2 duplicate row(s) across 2 raw DB(s)",
            output.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
