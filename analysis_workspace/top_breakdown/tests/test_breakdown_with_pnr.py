"""Tests for applying selective-PnR corrections to the standard plots."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import pandas as pd

MODULE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULE_DIR))

import breakdown  # noqa: E402
import breakdown_with_pnr  # noqa: E402


CORE = (
    "Vortex_axi/vortex/g_clusters_0__cluster/g_sockets_0__socket/"
    "g_cores_0__core"
)
SOCKET = "Vortex_axi/vortex/g_clusters_0__cluster/g_sockets_0__socket"


def baseline_hierarchy() -> pd.DataFrame:
    return pd.DataFrame(
        [
            {"full_path": f"{CORE}/gemm_node/u_VX_gemm_unit", "area": 30.0},
            {
                "full_path": f"{CORE}/gemm_node/u_tmem_subsystem/g_bank_0__u_bank",
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
    )


def modeled_block(**overrides: object) -> dict[str, object]:
    block: dict[str, object] = {
        "job_id": "VX_stream_xbar__example",
        "template_name": "VX_stream_xbar",
        "instance_count": 2,
        "status": "clean",
        "aggregation_mode": "modeled",
        "hierarchy_logical_area": 10.0,
        "estimated_hierarchy_physical_area": 8.0,
        "dc_physical_area": 8.0,
        "pnr_core_area": 11.25,
        "logical_correction": 12.5,
        "search_converged": True,
        "occurrence_paths": [
            "vortex/g_clusters[0].cluster/g_sockets[0].socket/req_xbar"
        ],
    }
    block.update(overrides)
    return block


class ValidateEstimateTest(unittest.TestCase):
    def test_matching_logical_totals_are_accepted(self) -> None:
        block = modeled_block()
        estimate = {
            "top_logical_cell_area": 1000.0,
            "adjusted_logical_cell_area": 1012.5,
            "blocks": [block],
        }

        self.assertEqual(
            breakdown_with_pnr.validate_estimate(
                estimate, 1000.0, require_converged=True
            ),
            [block],
        )

    def test_top_report_mismatch_is_rejected(self) -> None:
        estimate = {
            "top_logical_cell_area": 1000.0,
            "adjusted_logical_cell_area": 1012.5,
            "blocks": [modeled_block()],
        }

        with self.assertRaisesRegex(SystemExit, "disagree on logical cell area"):
            breakdown_with_pnr.validate_estimate(
                estimate, 999.0, require_converged=False
            )

    def test_adjusted_total_mismatch_is_rejected(self) -> None:
        estimate = {
            "top_logical_cell_area": 1000.0,
            "adjusted_logical_cell_area": 1013.0,
            "blocks": [modeled_block()],
        }

        with self.assertRaisesRegex(
            SystemExit, "do not reproduce adjusted_logical_cell_area"
        ):
            breakdown_with_pnr.validate_estimate(
                estimate, 1000.0, require_converged=False
            )

    def test_unconverged_search_can_be_made_strict(self) -> None:
        estimate = {
            "top_logical_cell_area": 1000.0,
            "adjusted_logical_cell_area": 1012.5,
            "blocks": [modeled_block(search_converged=False)],
        }

        with self.assertRaisesRegex(SystemExit, "searches are not converged"):
            breakdown_with_pnr.validate_estimate(
                estimate, 1000.0, require_converged=True
            )


class PnrCorrectionTest(unittest.TestCase):
    def test_semantic_mapping_is_framework_generic(self) -> None:
        cases = {
            "stream_xbar": "xbar",
            "request_arbiter": "xbar",
            "tensor_core": "mxu",
            "local_dma": "dma",
            "l2_cache": "memory",
            "issue_unit": "simt",
            "custom_datapath": "residual",
        }
        for template_name, expected in cases.items():
            with self.subTest(template_name=template_name):
                self.assertEqual(
                    breakdown_with_pnr.semantic_component(
                        modeled_block(
                            job_id=template_name,
                            template_name=template_name,
                            occurrence_paths=[],
                        )
                    ),
                    expected,
                )

    def test_only_modeled_blocks_contribute_corrections(self) -> None:
        corrections = breakdown_with_pnr.pnr_component_corrections(
            [
                modeled_block(),
                modeled_block(
                    job_id="diagnostic_only",
                    aggregation_mode="diagnostic",
                    pnr_core_area=109.0,
                ),
                modeled_block(
                    job_id="failed",
                    status="drc_failed",
                    pnr_core_area=None,
                ),
            ]
        )

        self.assertEqual(corrections, {"xbar": 12.5})

    def test_floorplan_multiplies_all_equal_parameter_instances(self) -> None:
        block = modeled_block(
            instance_count=3,
            hierarchy_logical_area=20.0,
            estimated_hierarchy_physical_area=16.0,
            dc_physical_area=8.0,
            pnr_core_area=15.0,
        )

        self.assertAlmostEqual(
            breakdown_with_pnr.modeled_floorplan_area(block), 45.0
        )
        self.assertAlmostEqual(
            breakdown_with_pnr.block_floorplan_correction(block), 25.0
        )

    def test_xbar_delta_uses_residual_in_original_legend(self) -> None:
        legend_group = breakdown.LEGEND_GROUPS[0]
        base = {
            breakdown.SIMT_LABEL: 40.0,
            breakdown.MEMORY_LABEL: 30.0,
            breakdown.MXU_LABEL: 20.0,
            breakdown.DMA_LABEL: 5.0,
            breakdown.MISC_LABEL: 5.0,
        }

        adjusted = breakdown_with_pnr.apply_pnr_corrections(
            base, legend_group, {"xbar": 12.5}
        )

        self.assertEqual(list(adjusted), [c.label for c in legend_group.categories])
        self.assertAlmostEqual(adjusted[breakdown.MISC_LABEL], 17.5)
        self.assertAlmostEqual(sum(adjusted.values()), 112.5)

    def test_xbar_delta_uses_xbar_in_xbar_legend(self) -> None:
        legend_group = breakdown.LEGEND_GROUPS[1]
        base = {
            breakdown.SIMT_NO_XBAR_LABEL: 60.0,
            breakdown.MEMORY_LABEL: 30.0,
            breakdown.XBAR_LABEL: 5.0,
            breakdown.DMA_LABEL: 5.0,
            breakdown.XBAR_MISC_LABEL: 0.0,
        }

        adjusted = breakdown_with_pnr.apply_pnr_corrections(
            base, legend_group, {"xbar": 12.5}
        )

        self.assertEqual(list(adjusted), [c.label for c in legend_group.categories])
        self.assertAlmostEqual(adjusted[breakdown.XBAR_LABEL], 17.5)
        self.assertAlmostEqual(adjusted[breakdown.XBAR_MISC_LABEL], 0.0)
        self.assertAlmostEqual(sum(adjusted.values()), 112.5)

    def test_base_summary_matches_dc_only_script(self) -> None:
        hdf = baseline_hierarchy()
        detail_sums, detail_counts, _ = breakdown.aggregate(hdf)
        components = breakdown_with_pnr.base_components(detail_sums, hdf)

        for legend_group in breakdown.LEGEND_GROUPS:
            with self.subTest(legend_group=legend_group.name):
                expected = breakdown.summarize_for_paper(
                    detail_sums,
                    detail_counts,
                    hdf,
                    117.0,
                    legend_group=legend_group,
                )
                actual = breakdown_with_pnr.summarize_base(
                    components, 117.0, legend_group
                )
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
