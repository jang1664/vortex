"""Regression tests for the paper-facing area categories."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import pandas as pd

MODULE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULE_DIR))

import breakdown  # noqa: E402


CORE = (
    "Vortex_axi/vortex/g_clusters_0__cluster/g_sockets_0__socket/"
    "g_cores_0__core"
)
SOCKET = "Vortex_axi/vortex/g_clusters_0__cluster/g_sockets_0__socket"


def baseline_rows() -> list[dict[str, float | str]]:
    """Return a small hierarchy containing every required semantic anchor."""
    return [
        {"full_path": f"{CORE}/gemm_node/u_VX_gemm_unit", "area": 30.0},
        {
            "full_path": (
                f"{CORE}/gemm_node/u_tmem_subsystem/g_bank_0__u_bank"
            ),
            "area": 20.0,
        },
        {
            "full_path": f"{CORE}/gemm_node/u_tmem_subsystem/u_dma_engine",
            "area": 5.0,
        },
        {"full_path": f"{CORE}/gemm_node/u_tmem_dma_ctrl", "area": 2.0},
        {"full_path": f"{CORE}/mem_unit", "area": 40.0},
        {"full_path": f"{CORE}/mem_unit/local_mem", "area": 25.0},
        {"full_path": f"{CORE}/execute/alu_unit", "area": 10.0},
        {"full_path": f"{SOCKET}/dcache", "area": 7.0},
        {"full_path": "Vortex_axi/g_hbm_mux_0__u_axi_mux", "area": 3.0},
    ]


def summarize(
    rows: list[dict[str, float | str]], total_area: float = 117.0
) -> dict[str, float]:
    hdf = pd.DataFrame(rows)
    detail_sums, detail_counts, _ = breakdown.aggregate(hdf)
    return breakdown.summarize_for_paper(
        detail_sums, detail_counts, hdf, total_area
    )


class SummarizeForPaperTest(unittest.TestCase):
    def test_five_category_totals_and_conservation(self) -> None:
        summary = summarize(baseline_rows())

        self.assertEqual(
            set(summary),
            {
                breakdown.SIMT_LABEL,
                breakdown.MEMORY_LABEL,
                breakdown.MXU_LABEL,
                breakdown.DMA_LABEL,
                breakdown.MISC_LABEL,
            },
        )
        self.assertAlmostEqual(summary[breakdown.SIMT_LABEL], 10.0)
        self.assertAlmostEqual(summary[breakdown.MEMORY_LABEL], 52.0)
        self.assertAlmostEqual(summary[breakdown.MXU_LABEL], 30.0)
        self.assertAlmostEqual(summary[breakdown.DMA_LABEL], 7.0)
        self.assertAlmostEqual(summary[breakdown.MISC_LABEL], 18.0)
        self.assertAlmostEqual(sum(summary.values()), 117.0)

    def test_only_local_mem_child_enters_memory(self) -> None:
        summary = summarize(baseline_rows())

        # Memory is local_mem (25) + TMEM bank (20) + cache (7). The
        # remaining 15 of the mem_unit parent is interconnect/control in Misc.
        self.assertAlmostEqual(summary[breakdown.MEMORY_LABEL], 25.0 + 20.0 + 7.0)
        self.assertAlmostEqual(summary[breakdown.MISC_LABEL], 15.0 + 3.0)

    def test_missing_semantic_anchors_fail_loudly(self) -> None:
        removal_cases = {
            "LMEM (mem_unit/local_mem)": lambda path: path.endswith(
                "/mem_unit/local_mem"
            ),
            "MXU (gemm_node/u_VX_gemm_unit)": lambda path: path.endswith(
                "/u_VX_gemm_unit"
            ),
            "TMEM banks": lambda path: "/g_bank_0__u_bank" in path,
            "cache (L1/L2/L3)": lambda path: path.endswith("/dcache"),
            "DMA": lambda path: path.endswith("/u_dma_engine")
            or path.endswith("/u_tmem_dma_ctrl"),
        }

        for expected_anchor, remove in removal_cases.items():
            with self.subTest(anchor=expected_anchor):
                rows = [
                    row
                    for row in baseline_rows()
                    if not remove(str(row["full_path"]))
                ]
                with self.assertRaises(SystemExit) as raised:
                    summarize(rows)
                self.assertIn(
                    "missing required semantic anchors:", str(raised.exception)
                )
                self.assertIn(expected_anchor, str(raised.exception))

    def test_local_mem_area_cannot_exceed_parent(self) -> None:
        rows = baseline_rows()
        for row in rows:
            if str(row["full_path"]).endswith("/mem_unit/local_mem"):
                row["area"] = 41.0

        with self.assertRaisesRegex(
            SystemExit, "local_mem area exceeds its mem_unit parent"
        ):
            summarize(rows)

    def test_assigned_area_cannot_exceed_total(self) -> None:
        with self.assertRaisesRegex(
            SystemExit, "paper categories exceed total cell area"
        ):
            summarize(baseline_rows(), total_area=98.0)


if __name__ == "__main__":
    unittest.main()
