"""Regression tests for the paper-facing area categories."""

from __future__ import annotations

import sys
import tempfile
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
    rows: list[dict[str, float | str]],
    total_area: float = 117.0,
    legend_group: breakdown.LegendGroup | None = None,
) -> dict[str, float]:
    hdf = pd.DataFrame(rows)
    detail_sums, detail_counts, _ = breakdown.aggregate(hdf)
    return breakdown.summarize_for_paper(
        detail_sums,
        detail_counts,
        hdf,
        total_area,
        legend_group=legend_group,
    )


def write_valid_report(path: Path) -> None:
    """Create the minimal content needed by report_is_valid()."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "Total cell area: 1.0\n"
        "Hierarchical area distribution\n"
    )


class ResolveReportTest(unittest.TestCase):
    def test_default_source_is_c4_alias(self) -> None:
        args = breakdown.parse_args([])

        self.assertEqual(args.alias, "C4")
        self.assertIsNone(args.syn_dir)
        self.assertIsNone(args.report)
        self.assertIsNone(args.run)

    def test_alias_resolves_run_syn_vortex_axi_result_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            alias_map = root / "aliases.yaml"
            alias_map.write_text(
                "aliases:\n"
                "  C4:\n"
                "    path: /tmp/fpga-bin\n"
            )
            report = (
                root
                / "results"
                / "Vortex_axi_C4"
                / "syn_topo.lpp"
                / "reports"
                / breakdown.REPORT_NAME
            )
            write_valid_report(report)
            args = breakdown.parse_args([
                "--alias", "C4",
                "--alias-map", str(alias_map),
                "--syn-root", str(root / "results"),
            ])

            self.assertEqual(breakdown.resolve_report(args), report)

    def test_syn_dir_accepts_direct_synthesis_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            syn_dir = Path(temp_dir) / "Vortex_axi_C4" / "syn_topo.lpp"
            report = syn_dir / "reports" / breakdown.REPORT_NAME
            write_valid_report(report)
            args = breakdown.parse_args(["--syn-dir", str(syn_dir)])

            self.assertEqual(breakdown.resolve_report(args), report)

    def test_unknown_alias_reports_available_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            alias_map = root / "aliases.yaml"
            alias_map.write_text(
                "aliases:\n"
                "  C4:\n"
                "    path: /tmp/fpga-bin\n"
            )
            args = breakdown.parse_args([
                "--alias", "missing",
                "--alias-map", str(alias_map),
                "--syn-root", str(root / "results"),
            ])

            with self.assertRaisesRegex(
                SystemExit, "unknown FPGA alias 'missing'.*C4"
            ):
                breakdown.resolve_report(args)


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

    def test_xbar_legend_group_separates_interconnect(self) -> None:
        rows = baseline_rows() + [
            {
                "full_path": (
                    f"{CORE}/gemm_node/u_tmem_subsystem/u_switch_input"
                ),
                "area": 4.0,
            },
            {
                "full_path": f"{SOCKET}/g_mem_bus_if_0__g_i0_mem_arb",
                "area": 6.0,
            },
            {"full_path": "Vortex_axi/u_lsu_demux", "area": 8.0},
        ]

        summary = summarize(
            rows,
            total_area=135.0,
        )
        xbar_summary = summarize(
            rows,
            total_area=135.0,
            legend_group=breakdown.LEGEND_GROUPS[1],
        )

        self.assertAlmostEqual(summary[breakdown.MISC_LABEL], 36.0)
        self.assertEqual(
            list(xbar_summary),
            [
                breakdown.SIMT_NO_XBAR_LABEL,
                breakdown.MEMORY_LABEL,
                breakdown.XBAR_LABEL,
                breakdown.DMA_LABEL,
                breakdown.XBAR_MISC_LABEL,
            ],
        )
        self.assertAlmostEqual(
            xbar_summary[breakdown.SIMT_NO_XBAR_LABEL], 40.0
        )
        self.assertAlmostEqual(xbar_summary[breakdown.MEMORY_LABEL], 52.0)
        self.assertAlmostEqual(xbar_summary[breakdown.XBAR_LABEL], 36.0)
        self.assertAlmostEqual(xbar_summary[breakdown.DMA_LABEL], 7.0)
        self.assertAlmostEqual(xbar_summary[breakdown.XBAR_MISC_LABEL], 0.0)
        self.assertAlmostEqual(sum(xbar_summary.values()), 135.0)

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
