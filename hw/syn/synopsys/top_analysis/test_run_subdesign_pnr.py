from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
for path in (ROOT / "hw/syn/synopsys", ROOT / "third_party/hwexplorer"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from hwexplorer.automation.hierarchical import ElaboratedDesign
from top_analysis import run_subdesign_pnr as driver


MATCH_CONFIG = driver._load_match_config(driver.DEFAULT_MATCH_CONFIG)


def _catalog() -> list[ElaboratedDesign]:
    return [
        ElaboratedDesign(
            design_name="VX_stream_xbar_W32",
            template_name="VX_stream_xbar",
            instance_paths=["vortex/u_stream_xbar"],
        ),
        ElaboratedDesign(
            design_name="VX_gemm_unit_W32",
            template_name="VX_gemm_unit",
            instance_paths=["vortex/gemm_node/u_gemm_unit"],
        ),
        ElaboratedDesign(
            design_name="VX_dma_node_W32",
            template_name="VX_dma_node",
            instance_paths=["vortex/core/u_VX_dma_node"],
        ),
        ElaboratedDesign(
            design_name="VX_dma_engine_W32",
            template_name="VX_dma_engine",
            instance_paths=["vortex/gemm_node/u_dma_engine"],
        ),
        ElaboratedDesign(
            design_name="VX_dma_unit_W32",
            template_name="VX_dma_unit",
            instance_paths=["vortex/gemm_node/u_dma_engine/u_dma_unit"],
        ),
        ElaboratedDesign(
            design_name="VX_lmem_dma_misal_W32",
            template_name="VX_lmem_dma_misal",
            instance_paths=["vortex/gemm_node/u_ldma_0"],
        ),
        ElaboratedDesign(
            design_name="VX_gemm_tmem_dma_ctrl_W32",
            template_name="VX_gemm_tmem_dma_ctrl",
            instance_paths=["vortex/gemm_node/u_tmem_dma_ctrl"],
        ),
    ]


def test_family_inference_supports_c3_and_c4() -> None:
    assert driver._resolve_family(MATCH_CONFIG, None, "C3", Path("ignored")) == "C3"
    assert driver._resolve_family(
        MATCH_CONFIG, None, None, Path("improve_th16_tcol32_hwexp_dcache.sh")
    ) == "C4"


@pytest.mark.parametrize("family", ["C3", "C4"])
def test_selection_includes_dma_wrappers_without_internal_dma_unit(family: str) -> None:
    selectors, matches = driver._select_targets(_catalog(), MATCH_CONFIG, family)
    selected = {selector.value for selector in selectors}
    assert "VX_stream_xbar_W32" in selected
    assert "VX_gemm_unit_W32" in selected
    assert "VX_dma_node_W32" in selected
    assert "VX_dma_engine_W32" in selected
    assert "VX_lmem_dma_misal_W32" in selected
    assert "VX_gemm_tmem_dma_ctrl_W32" in selected
    assert "VX_dma_unit_W32" not in selected
    assert any(item["name"] == "hbm_dma_engine" and item["matched"] == 1 for item in matches)


def test_gemm_unit_is_synthesized_but_skipped_by_pnr() -> None:
    skipped = driver._select_pnr_skips(_catalog(), MATCH_CONFIG, "C4")
    assert skipped == {"VX_gemm_unit_W32"}


def test_seed_resolution_accepts_results_root(tmp_path: Path) -> None:
    seed = tmp_path / "top"
    (seed / "results").mkdir(parents=True)
    (seed / "results/design_catalog.tsv").write_text("design_name\ttemplate_name\nX\tX\n")
    (seed / "results/Vortex_axi.elab.ddc").write_text("ddc")
    result = driver._resolve_seed_run_dir(str(seed), Path("config.sh"), "C4", tmp_path / "out")
    assert result["root"] == seed.resolve()


def test_seed_resolution_accepts_explicit_ddc_path(tmp_path: Path) -> None:
    seed = tmp_path / "top"
    (seed / "results").mkdir(parents=True)
    (seed / "results/design_catalog.tsv").write_text("design_name\ttemplate_name\nX\tX\n")
    ddc = seed / "results/Vortex_axi.elab.ddc"
    ddc.write_text("ddc")
    result = driver._resolve_seed_run_dir(str(ddc), Path("config.sh"), "C4", tmp_path / "out")
    assert result["root"] == seed.resolve()
    assert result["ddc"] == ddc.resolve()


def test_stage_order_is_synthesis_then_pnr() -> None:
    assert driver._parse_stages("synth,pnr") == ["synth", "pnr"]
    with pytest.raises(SystemExit, match="synthesis must precede"):
        driver._parse_stages("pnr,synth")
