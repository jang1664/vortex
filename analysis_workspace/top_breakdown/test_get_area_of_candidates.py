"""Tests for the provisional C1--C4 area estimator."""

from __future__ import annotations

from pathlib import Path

import pandas as pd
import pytest

from analysis_workspace.top_breakdown.get_area_of_candidates import (
    DEFAULT_C3_REPORT,
    DEFAULT_C4_REPORT,
    DEFAULT_MEMORY_ROOT,
    DEFAULT_NAIVE_ACC_REPORT,
    DEFAULT_TCU_REPORT,
    MACRO_FAMILIES,
    AreaReport,
    CandidateOptions,
    MacroMapping,
    MacroTile,
    SramGroup,
    choose_depth_tiles,
    default_candidate_options,
    get_top_areas,
    replace_sram_macro,
)


def _write_lef(root: Path, macro_name: str, width: float, height: float) -> None:
    macro_dir = root / macro_name
    macro_dir.mkdir(parents=True)
    (macro_dir / f"{macro_name}.lef").write_text(
        f"MACRO {macro_name}\n  SIZE {width} BY {height} ;\nEND {macro_name}\n"
    )


def _synthetic_report(*, blackbox_area: float) -> AreaReport:
    root = "Top/u_mem/g_compiled_u_compiled"
    rows = [
        {
            "full_path": "Top",
            "parent_path": "",
            "module_name": "Top",
            "area": 200.0,
            "percent": 100.0,
            "comb_area": 10.0,
            "non_comb_area": 0.0,
            "blackbox_area": 0.0,
        },
        {
            "full_path": "Top/u_mem",
            "parent_path": "Top",
            "module_name": "Mem",
            "area": 100.0,
            "percent": 50.0,
            "comb_area": 5.0,
            "non_comb_area": 0.0,
            "blackbox_area": 0.0,
        },
        {
            "full_path": root,
            "parent_path": "Top/u_mem",
            "module_name": "VX_sp_ram_compiled_test",
            "area": 80.0,
            "percent": 40.0,
            "comb_area": 20.0 if blackbox_area == 0.0 else 5.0,
            "non_comb_area": 60.0 if blackbox_area == 0.0 else 0.0,
            "blackbox_area": blackbox_area,
        },
        {
            "full_path": root + "/register_array",
            "parent_path": root,
            "module_name": "RegisterArray",
            "area": 60.0,
            "percent": 30.0,
            "comb_area": 0.0,
            "non_comb_area": 60.0,
            "blackbox_area": 0.0,
        },
    ]
    return AreaReport("synthetic", Path("synthetic.rpt"), pd.DataFrame(rows), 200.0)


def _synthetic_group(macro_name: str) -> SramGroup:
    return SramGroup(
        "TEST",
        ("/u_mem/",),
        1,
        {"HS": MacroMapping(macro_name, 2)},
    )


def test_depth_tiling_minimizes_lef_area(tmp_path: Path) -> None:
    _write_lef(tmp_path, "depth4096", 10.0, 10.0)
    _write_lef(tmp_path, "depth2048", 8.0, 10.0)
    _write_lef(tmp_path, "depth1024", 3.0, 10.0)
    family = (
        MacroTile(4096, 64, "depth4096"),
        MacroTile(2048, 64, "depth2048"),
        MacroTile(1024, 64, "depth1024"),
    )

    tiles = choose_depth_tiles(6144, family, tmp_path)

    assert [tile.depth for tile in tiles] == [4096, 1024, 1024]


@pytest.mark.skipif(
    not DEFAULT_MEMORY_ROOT.is_dir(),
    reason="memory compiler LEFs are unavailable",
)
def test_hd_1536_kib_lmem_uses_area_optimal_depth_tiles() -> None:
    tiles = choose_depth_tiles(
        6144,
        MACRO_FAMILIES[("LMEM", "HD")],
        DEFAULT_MEMORY_ROOT,
    )

    assert [tile.depth for tile in tiles] == [4096, 1024, 1024]


def test_replace_register_fallback_removes_implementation(tmp_path: Path) -> None:
    macro_name = "test_macro"
    _write_lef(tmp_path, macro_name, 5.0, 4.0)
    report = _synthetic_report(blackbox_area=0.0)

    audit = replace_sram_macro(report, _synthetic_group(macro_name), "HS", tmp_path)

    root = report.hierarchy.loc[
        report.hierarchy["full_path"].eq("Top/u_mem/g_compiled_u_compiled")
    ].iloc[0]
    assert root["area"] == pytest.approx(40.0)
    assert root["blackbox_area"] == pytest.approx(40.0)
    assert root["comb_area"] == pytest.approx(0.0)
    assert root["non_comb_area"] == pytest.approx(0.0)
    assert not report.hierarchy["full_path"].str.contains("register_array").any()
    assert report.total_area == pytest.approx(160.0)
    assert report.hierarchy.loc[report.hierarchy["full_path"].eq("Top"), "area"].iloc[0] == pytest.approx(160.0)
    assert audit["fallback_roots"] == 1
    assert audit["delta_area_um2"] == pytest.approx(-40.0)


def test_replace_macro_preserves_wrapper_glue(tmp_path: Path) -> None:
    macro_name = "test_macro"
    _write_lef(tmp_path, macro_name, 5.0, 4.0)
    report = _synthetic_report(blackbox_area=70.0)

    audit = replace_sram_macro(report, _synthetic_group(macro_name), "HS", tmp_path)

    root = report.hierarchy.loc[
        report.hierarchy["full_path"].eq("Top/u_mem/g_compiled_u_compiled")
    ].iloc[0]
    assert root["area"] == pytest.approx(50.0)
    assert root["blackbox_area"] == pytest.approx(40.0)
    assert root["comb_area"] == pytest.approx(5.0)
    assert audit["preserved_wrapper_area_um2"] == pytest.approx(10.0)
    assert report.total_area == pytest.approx(170.0)


@pytest.mark.skipif(
    not all(
        path.is_file()
        for path in (DEFAULT_C3_REPORT, DEFAULT_C4_REPORT, DEFAULT_TCU_REPORT)
    )
    or not DEFAULT_MEMORY_ROOT.is_dir(),
    reason="local synthesis reports or memory compiler LEFs are unavailable",
)
def test_current_reports_match_provisional_reference_values() -> None:
    summary, components, audit = get_top_areas()
    expected_mm2 = {
        ("HS", "C1"): 9.234678,
        ("HS", "C2"): 10.561196,
        ("HS", "C3"): 10.014085,
        ("HS", "C4"): 10.698940,
        ("HD", "C1"): 8.726160,
        ("HD", "C2"): 10.052678,
        ("HD", "C3"): 9.505567,
        ("HD", "C4"): 10.373978,
    }
    actual = {
        (row.sram_type, row.candidate): row.total_area_mm2
        for row in summary.itertuples()
    }
    assert actual == pytest.approx(expected_mm2, abs=1e-6)
    assert len(components) == 42
    assert len(audit) == 16

    for sram_type in ("HS", "HD"):
        typed = summary.loc[summary["sram_type"].eq(sram_type)].set_index("candidate")
        assert typed.at["C2", "total_area_um2"] - typed.at["C3", "total_area_um2"] == pytest.approx(
            547111.533916
        )
        dma_components = components.loc[
            components["sram_type"].eq(sram_type)
            & components["component"].eq("C3 naive DMA node")
        ]
        assert set(dma_components["candidate"]) == {"C2", "C3"}
        assert dma_components["area_um2"].tolist() == pytest.approx(
            [259615.1571, 259615.1571]
        )


@pytest.mark.skipif(
    not all(
        path.is_file()
        for path in (
            DEFAULT_C3_REPORT,
            DEFAULT_C4_REPORT,
            DEFAULT_TCU_REPORT,
            DEFAULT_NAIVE_ACC_REPORT,
        )
    )
    or not DEFAULT_MEMORY_ROOT.is_dir(),
    reason="local synthesis reports or memory compiler LEFs are unavailable",
)
def test_naive_acc_with_768_kib_lmem_hs_profile() -> None:
    options = default_candidate_options(naive_acc=True)
    options["C2"] = CandidateOptions(lmem_kib=768, acc_kib=256)
    options["C3"] = CandidateOptions(lmem_kib=768, acc_kib=256)

    summary, components, audit = get_top_areas(
        sram_types=("HS",),
        candidate_options=options,
        naive_acc=True,
    )
    actual = summary.set_index("candidate")["total_area_mm2"].to_dict()
    assert actual == pytest.approx(
        {
            "C1": 9.23467757889,
            "C2": 11.198677000454,
            "C3": 10.651565466538,
            "C4": 10.698940113282,
        },
        abs=1e-9,
    )
    naive_components = components.loc[
        components["component"].eq("Previous naive GEMM logic")
    ]
    assert set(naive_components["candidate"]) == {"C2", "C3"}
    c3_lmem = audit.loc[
        audit["candidate"].eq("C3") & audit["group"].eq("LMEM")
    ].iloc[0]
    assert c3_lmem["logical_depth"] == 3072
    assert c3_lmem["physical_depth"] == 3072
    assert c3_lmem["total_macros"] == 64


@pytest.mark.skipif(
    not all(
        path.is_file()
        for path in (DEFAULT_C3_REPORT, DEFAULT_C4_REPORT, DEFAULT_TCU_REPORT)
    )
    or not DEFAULT_MEMORY_ROOT.is_dir(),
    reason="local synthesis reports or memory compiler LEFs are unavailable",
)
def test_candidate_can_exclude_memory_and_common() -> None:
    options = default_candidate_options()
    options["C3"] = CandidateOptions(
        lmem_kib=1024,
        include_memory=False,
        include_common=False,
    )

    summary, components, audit = get_top_areas(
        sram_types=("HS",), candidate_options=options
    )
    c3_summary = summary.loc[summary["candidate"].eq("C3")].iloc[0]
    c3_components = components.loc[components["candidate"].eq("C3")]
    assert not c3_summary["include_memory"]
    assert not c3_summary["include_common"]
    assert not c3_components["component"].str.contains("common backbone").any()
    assert not c3_components["component"].str.contains("SRAM").any()
    c3_lmem = audit.loc[
        audit["candidate"].eq("C3") & audit["group"].eq("LMEM")
    ].iloc[0]
    assert not c3_lmem["included"]
    assert c3_lmem["included_area_um2"] == 0.0
