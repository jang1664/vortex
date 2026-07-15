from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import vivado_util


REPORT = """\
| Tool Version : Vivado v.2025.1 (lin64) Build 1
| Date         : Tue Jul 15 00:00:00 2026
| Design       : test_top
| Device       : xcu55c-fsvh2892-2L-e
| Speed File   : -2L
| Command      : report_utilization -file full_util_routed.rpt
| Design State : Routed

1. CLB Logic
------------

+---------------+------+-------+------------+-----------+-------+
| Site Type     | Used | Fixed | Prohibited | Available | Util% |
+---------------+------+-------+------------+-----------+-------+
| CLB LUTs      |  100 |    10 |          0 |      1000 | 10.00 |
| LUT as Logic  |   80 |     8 |          0 |      1000 |  8.00 |
| LUT as Memory |   20 |     2 |          0 |       500 |  4.00 |
| CLB Registers |  200 |    20 |          0 |      2000 | 10.00 |
+---------------+------+-------+------------+-----------+-------+

3. BLOCKRAM
-----------

+----------------+------+-------+------------+-----------+-------+
| Site Type      | Used | Fixed | Prohibited | Available | Util% |
+----------------+------+-------+------------+-----------+-------+
| Block RAM Tile | 40.5 |     0 |          0 |       100 | 40.50 |
| RAMB36/FIFO*   |   39 |     1 |          0 |       100 | 39.00 |
| RAMB18         |    3 |     0 |          0 |       200 |  1.50 |
| URAM           |    8 |     0 |          0 |        80 | 10.00 |
+----------------+------+-------+------------+-----------+-------+

4. ARITHMETIC
-------------

+-----------+------+-------+------------+-----------+-------+
| Site Type | Used | Fixed | Prohibited | Available | Util% |
+-----------+------+-------+------------+-----------+-------+
| DSPs      |   25 |     1 |          0 |       100 | 25.00 |
+-----------+------+-------+------------+-----------+-------+
"""


class VivadoUtilCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.report = Path(self.tmpdir.name) / "full_util_routed.rpt"
        self.report.write_text(REPORT, encoding="utf-8")

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def test_summary_selects_major_resources(self) -> None:
        db = vivado_util.load_database(self.report)

        summary = vivado_util.build_summary(db)

        self.assertEqual(
            summary["Resource"].tolist(),
            [
                "CLB LUTs",
                "LUT as Logic",
                "LUT as Memory",
                "CLB Registers",
                "Block RAM Tile",
                "RAMB36/FIFO*",
                "RAMB18",
                "URAM",
                "DSPs",
            ],
        )
        self.assertEqual(summary.loc[summary["Resource"] == "URAM", "Used"].iloc[0], "8")

    def test_show_filters_first_column(self) -> None:
        db = vivado_util.load_database(self.report)

        table = vivado_util.select_table(db, "blockram", r"RAMB|URAM")

        self.assertEqual(table["Site Type"].tolist(), ["RAMB36/FIFO*", "RAMB18", "URAM"])
        self.assertEqual(table["Used"].tolist(), ["39", "3", "8"])

    def test_summary_command_prints_report_metadata_and_resources(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = vivado_util.main([str(self.report), "summary"])

        output = stdout.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("Design: test_top", output)
        self.assertIn("Block RAM Tile", output)
        self.assertIn("DSPs", output)

    def test_summary_command_exports_filtered_csv(self) -> None:
        output = Path(self.tmpdir.name) / "resources.csv"

        rc = vivado_util.main(
            [
                str(self.report),
                "summary",
                "--filter",
                r"^(CLB LUTs|Block RAM Tile|URAM|DSPs)$",
                "--format",
                "csv",
                "-o",
                str(output),
            ]
        )

        self.assertEqual(rc, 0)
        csv_text = output.read_text(encoding="utf-8")
        self.assertIn("Section,Resource,Used,Fixed,Available,Util%", csv_text)
        self.assertIn("clb_logic,CLB LUTs,100,10,1000,10.00", csv_text)
        self.assertIn("blockram,Block RAM Tile,40.5,0,100,40.50", csv_text)
        self.assertIn("blockram,URAM,8,0,80,10.00", csv_text)
        self.assertIn("arithmetic,DSPs,25,1,100,25.00", csv_text)
        self.assertNotIn("CLB Registers", csv_text)


if __name__ == "__main__":
    unittest.main()
