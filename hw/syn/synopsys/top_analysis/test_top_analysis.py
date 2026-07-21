from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

TOP_ANALYSIS = Path(__file__).resolve().parent
SYNOPSYS = TOP_ANALYSIS.parent
HWEXPLORER = SYNOPSYS.parents[2] / "third_party/hwexplorer"
for path in (str(SYNOPSYS), str(HWEXPLORER)):
    if path not in sys.path:
        sys.path.insert(0, path)

from hwexplorer.automation.hierarchical import (  # noqa: E402
    HierarchicalManifest,
    HierarchySelector,
    SynthesisJob,
)
from hwexplorer.automation.pnr_result import PnRResult  # noqa: E402
from hwexplorer.automation.pnr_search import PnRAreaSearchResult  # noqa: E402
from top_analysis.aggregate import build_estimate  # noqa: E402
from top_analysis.config import load_analysis_config  # noqa: E402
from top_analysis.path_utils import dc_hierarchy_path_candidates  # noqa: E402
from top_analysis.run import _run_pnr_attempts, _validate_nonoverlap  # noqa: E402
import top_analysis.run as run_module  # noqa: E402


def _area_report(
    path: Path,
    *,
    design: str,
    logical: float,
    physical: float,
    core: float,
    utilization: float,
    hierarchy: list[tuple[str, float, str]],
) -> None:
    rows = "\n".join(
        f"{name} {area:.4f} 10.0 0.0 0.0 0.0 {module}"
        for name, area, module in hierarchy
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"""****************************************
Report : area
Design : {design}
****************************************
Total cell area: {logical}
Core Area: {core}
Aspect Ratio: 1.0
Utilization Ratio: {utilization}
Total physical cell area: {physical}
Core area: 0.0, 0.0, {core ** 0.5}, {core ** 0.5}
Hierarchical area distribution
------------------------------
Hierarchical cell Absolute Percent Combi Noncombi Black Design
------------------------------
{rows}
------------------------------
Total 0 0 0
"""
    )


def test_pnr_search_policy_aliases_and_validation(tmp_path: Path) -> None:
    path = tmp_path / "candidates.yaml"
    path.write_text(
        """include:\n  modules:\n    - pattern: xbar\npnr:\n  max_attempts: 4\n  initial_area_margin: 1.1\n  area_margin_multiplier: 1.15\n"""
    )
    config = load_analysis_config(path)
    assert config.pnr.initial_area_scale == 1.1
    assert config.pnr.bracket_factor == 1.15
    assert config.pnr.search_policy().initial_area_scale == 1.1

    path.write_text(
        """include:\n  modules:\n    - pattern: xbar\npnr:\n  relative_area_tolerance: 0\n"""
    )
    with pytest.raises(ValueError, match="relative_area_tolerance"):
        load_analysis_config(path)


@pytest.mark.parametrize(
    "config_name",
    [
        "naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh",
        "improve_th16_tcol32_hwexp_dcache.sh",
    ],
)
def test_driver_accepts_target_config_paths(config_name: str) -> None:
    config_path = SYNOPSYS.parents[2] / "configs" / config_name
    args = run_module._parser().parse_args(["--config", str(config_path)])

    resolved, tag = run_module._resolve_config(args)

    assert resolved == config_path.resolve()
    assert tag == config_path.stem


def test_default_candidates_are_coarse_interconnect_and_gemm_tree() -> None:
    config = load_analysis_config(TOP_ANALYSIS / "candidates.yaml")
    patterns = {rule.pattern for rule in config.include.modules}

    assert patterns == {
        "VX_stream_xbar",
        "axi_xbar",
        "axi_interleaved_xbar",
        "VX_mem_arb",
        "VX_lsu_mem_arb",
        "VX_mem_switch",
        "VX_lmem_switch",
        "VX_tmem_switch",
        "VX_tmem_wide_read_switch",
        "axi_mux",
        "axi_demux",
        "VX_gemm_tree_v1",
    }
    required = {rule.pattern for rule in config.include.modules if rule.required}
    assert required == {"VX_stream_xbar", "VX_gemm_tree_v1"}
    assert patterns.isdisjoint(
        {
            "VX_stream_arb",
            "VX_demux",
            "VX_generic_arbiter",
            "VX_priority_arbiter",
            "VX_rr_arbiter",
        }
    )

    profiles = {profile.name: profile for profile in config.block_constraints}
    assert profiles["gemm_tree_clock_ports"].constraints == {
        "clk_name": "clk_i",
        "reset_name": "resetn_i",
        "reset_type": "active_low",
        "switching_activity": {},
    }
    assert profiles["axi_clock_ports"].match.module_patterns == [
        "axi_xbar",
        "axi_interleaved_xbar",
        "axi_mux",
        "axi_demux",
    ]
    assert profiles["axi_clock_ports"].constraints == {
        "clk_name": "clk_i",
        "reset_name": "rst_ni",
        "reset_type": "active_low",
        "switching_activity": {},
    }


def test_clockless_block_constraint_selects_virtual_clock(tmp_path: Path) -> None:
    path = tmp_path / "candidates.yaml"
    path.write_text(
        """include:
  modules:
    - pattern: combinational_block
block_constraints:
  - name: combinational_virtual_clock
    match:
      module_patterns:
        - combinational_block
    constraints:
      clk_name: ""
      reset_name: ""
      switching_activity: {}
"""
    )

    config = load_analysis_config(path)

    assert config.block_constraints[0].constraints == {
        "clk_name": "",
        "reset_name": "",
        "switching_activity": {},
    }


def test_nested_occurrences_are_rejected() -> None:
    with pytest.raises(ValueError, match="double count"):
        _validate_nonoverlap(["top/xbar", "top/xbar/arb"], allow_nested=False)
    _validate_nonoverlap(["top/xbar", "top/other/arb"], allow_nested=False)


def test_dc_mapped_hierarchy_path_candidates_normalize_generate_arrays() -> None:
    candidates = dc_hierarchy_path_candidates(
        "top", "cluster/g_sockets[0].socket/g_cache.cache/xbar"
    )
    assert "top/cluster/g_sockets_0__socket/g_cache_cache/xbar" in candidates


def test_hybrid_estimate_uses_only_clean_pnr_result(tmp_path: Path) -> None:
    top_report = tmp_path / "top.rpt"
    _area_report(
        top_report,
        design="top",
        logical=1000,
        physical=800,
        core=1600,
        utilization=0.5,
        hierarchy=[("top", 1000, "top"), ("u_xbar", 100, "xbar")],
    )
    worker_dir = tmp_path / "worker"
    worker_report = worker_dir / "reports/14_xbar_job.mapped.area.rpt"
    _area_report(
        worker_report,
        design="xbar_job",
        logical=100,
        physical=80,
        core=160,
        utilization=0.5,
        hierarchy=[("xbar_job", 100, "xbar_job")],
    )
    job = SynthesisJob(
        job_id="xbar_job",
        output_name="xbar_job",
        design_name="xbar_elab",
        template_name="xbar",
        logical_signature="logical",
        constraint_signature="constraints",
        synthesis_key="key",
        run_dir=str(worker_dir),
        instance_paths=["u_xbar"],
        selected_by=[HierarchySelector(kind="module", value="xbar")],
        output_profile="icc2_handoff",
    )
    manifest = HierarchicalManifest(
        top_design="top",
        catalog_path=str(tmp_path / "catalog.tsv"),
        elaborated_ddc_path=str(tmp_path / "top.ddc"),
        constraint_signature="constraints",
        synthesis_jobs=[job],
    )
    manifest_path = tmp_path / "manifest.json"
    manifest.write(manifest_path)
    clean = PnRResult(
        status="clean",
        return_code=0,
        run_dir=str(tmp_path / "pnr"),
        design_name="xbar_job",
        cell_area=100,
        core_area=220,
        signal_routing_drc_errors=0,
    )

    estimate = build_estimate(top_report, manifest_path, {"xbar_job": [clean]})

    assert estimate.modeled_logical_coverage == pytest.approx(0.1)
    assert estimate.adjusted_logical_cell_area == pytest.approx(1025)
    assert estimate.adjusted_physical_cell_area == pytest.approx(820)
    assert estimate.hybrid_core_area == pytest.approx(1660)

    smaller_clean = clean.model_copy(
        update={"attempt": 2, "area_scale": 0.75, "cell_area": 120, "core_area": 180}
    )
    large_clean = clean.model_copy(update={"attempt": 1, "area_scale": 1.0})
    search = PnRAreaSearchResult(
        job_id="xbar_job",
        termination="converged",
        converged=True,
        attempts=[large_clean, smaller_clean],
        best_clean_attempt=2,
        clean_area_scale=0.75,
        failed_area_scale=0.74,
        relative_area_gap=(0.75 - 0.74) / 0.75,
    )
    searched = build_estimate(
        top_report,
        manifest_path,
        {"xbar_job": [large_clean, smaller_clean]},
        search_results={"xbar_job": search},
    )
    assert searched.blocks[0].selected_attempt == 2
    assert searched.blocks[0].search_converged
    assert searched.blocks[0].clean_area_scale == 0.75
    assert searched.adjusted_logical_cell_area == pytest.approx(1050)

    failed = clean.model_copy(update={"status": "drc_failed", "return_code": 3})
    dc_only = build_estimate(top_report, manifest_path, {"xbar_job": [failed]})
    assert dc_only.adjusted_logical_cell_area == 1000
    assert dc_only.hybrid_core_area == 1600

    diagnostic = build_estimate(
        top_report,
        manifest_path,
        {"xbar_job": [clean]},
        diagnostic_job_ids={"xbar_job"},
    )
    assert diagnostic.adjusted_logical_cell_area == 1000
    assert diagnostic.hybrid_core_area == 1600
    assert diagnostic.modeled_logical_coverage == 0
    assert diagnostic.clean_block_count == 0
    assert diagnostic.diagnostic_block_count == 1
    assert diagnostic.blocks[0].growth_factor == pytest.approx(1.25)
    assert diagnostic.blocks[0].aggregation_mode == "diagnostic"


def test_report_only_does_not_build_or_run_synthesis(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    config_file = tmp_path / "config.sh"
    config_file.write_text('CONFIGS="-DNUM_THREADS=1"\nexport CONFIGS\n')
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    (run_dir / "pnr_results.json").write_text("{}")
    reports_dir = run_dir / "reports"

    monkeypatch.setattr(run_module, "_validate_top", lambda _: None)
    monkeypatch.setattr(
        run_module,
        "build_vortex_axi_synth_config",
        lambda *args, **kwargs: pytest.fail("report-only built synthesis config"),
    )
    monkeypatch.setattr(
        run_module, "build_estimate", lambda *args, **kwargs: object()
    )
    monkeypatch.setattr(
        run_module,
        "write_reports",
        lambda estimate, output: Path(output).mkdir(parents=True),
    )

    assert run_module.main(
        [
            "--config",
            str(config_file),
            "--run-dir",
            str(run_dir),
            "--report-only",
        ]
    ) == 0
    assert (reports_dir / "resolved_config.json").is_file()


@pytest.mark.parametrize(
    "termination,statuses,expected_return",
    [
        ("max_attempts", ["drc_failed", "drc_failed"], 0),
        ("converged", ["drc_failed", "clean"], 0),
        ("infrastructure_failed", ["infrastructure_failed"], 2),
    ],
)
def test_top_orchestrator_persists_generic_search_results(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    termination: str,
    statuses: list[str],
    expected_return: int,
) -> None:
    worker_dir = tmp_path / "worker"
    _area_report(
        worker_dir / "reports/14_xbar_job.mapped.area.rpt",
        design="xbar_job",
        logical=100,
        physical=80,
        core=160,
        utilization=0.5,
        hierarchy=[("xbar_job", 100, "xbar")],
    )
    job = SynthesisJob(
        job_id="xbar_job",
        output_name="xbar_job",
        design_name="xbar_elab",
        template_name="xbar",
        logical_signature="logical",
        constraint_signature="constraints",
        synthesis_key="key",
        run_dir=str(worker_dir),
        instance_paths=["u_xbar"],
        output_profile="icc2_handoff",
    )
    manifest = HierarchicalManifest(
        top_design="top",
        catalog_path=str(tmp_path / "catalog.tsv"),
        elaborated_ddc_path=str(tmp_path / "top.ddc"),
        constraint_signature="constraints",
        synthesis_jobs=[job],
    )
    manifest_path = tmp_path / "manifest.json"
    manifest.write(manifest_path)
    config_path = tmp_path / "candidates.yaml"
    config_path.write_text(
        """include:\n  modules:\n    - pattern: xbar\npnr:\n  max_attempts: 2\n  initial_area_margin: 1.1\n  area_margin_multiplier: 1.2\n"""
    )
    config = load_analysis_config(config_path)
    calls = []

    def fake_search(*args, checkpoint, **kwargs):
        calls.append(args[1].job_id)
        attempts = [
            PnRResult(
                status=status,
                return_code={
                    "clean": 0,
                    "drc_failed": 3,
                    "infrastructure_failed": 2,
                }[status],
                run_dir=str(tmp_path / f"attempt_{attempt}"),
                job_id="xbar_job",
                attempt=attempt,
                area_scale=1.0 / attempt,
                cell_area=100 if status == "clean" else None,
                core_area=200 if status == "clean" else None,
            )
            for attempt, status in enumerate(statuses, start=1)
        ]
        checkpoint(attempts)
        return PnRAreaSearchResult(
            job_id="xbar_job",
            termination=termination,
            converged=termination == "converged",
            attempts=attempts,
            best_clean_attempt=next(
                (item.attempt for item in reversed(attempts) if item.status == "clean"),
                None,
            ),
        )

    monkeypatch.setattr(run_module, "run_synthesis_job_pnr_search", fake_search)

    ret = _run_pnr_attempts(
        manifest_path, config, tmp_path, resume=False, only_job_id=None
    )

    assert ret == expected_return
    assert calls == ["xbar_job"]
    persisted = json.loads((tmp_path / "pnr_search_results.json").read_text())
    assert persisted["xbar_job"]["termination"] == termination


def test_resume_reparses_preserved_attempt_before_deciding_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    worker_dir = tmp_path / "worker"
    job = SynthesisJob(
        job_id="xbar_job",
        output_name="xbar_job",
        design_name="xbar_elab",
        template_name="xbar",
        logical_signature="logical",
        constraint_signature="constraints",
        synthesis_key="key",
        run_dir=str(worker_dir),
        instance_paths=["u_xbar"],
        output_profile="icc2_handoff",
    )
    manifest = HierarchicalManifest(
        top_design="top",
        catalog_path=str(tmp_path / "catalog.tsv"),
        elaborated_ddc_path=str(tmp_path / "top.ddc"),
        constraint_signature="constraints",
        synthesis_jobs=[job],
    )
    manifest_path = tmp_path / "manifest.json"
    manifest.write(manifest_path)
    attempt_dir = tmp_path / "attempt_01"
    attempt_dir.mkdir()
    previous = PnRResult(
        status="infrastructure_failed",
        return_code=0,
        run_dir=str(attempt_dir),
        job_id=job.job_id,
        design_name=job.output_name,
        attempt=1,
        area_scale=1.0,
    )
    (tmp_path / "pnr_results.json").write_text(
        json.dumps({job.job_id: [previous.model_dump(mode="json")]})
    )
    config_path = tmp_path / "candidates.yaml"
    config_path.write_text(
        "include:\n  designs:\n    - pattern: xbar_elab\n"
        "pnr:\n  max_attempts: 2\n"
    )
    config = load_analysis_config(config_path)

    def fake_parse(run_dir, **kwargs):
        return PnRResult(
            status="clean",
            return_code=0,
            run_dir=str(run_dir),
            job_id=job.job_id,
            design_name=job.output_name,
            attempt=1,
            area_scale=kwargs["area_scale"],
            signal_routing_drc_errors=0,
            cell_area=100,
            core_area=200,
        )

    def fake_search(*args, existing_attempts, **kwargs):
        assert len(existing_attempts) == 1
        assert existing_attempts[0].status == "clean"
        assert existing_attempts[0].area_scale == 1.0
        return PnRAreaSearchResult(
            job_id=job.job_id,
            termination="max_attempts",
            attempts=existing_attempts,
            best_clean_attempt=1,
            clean_area_scale=1.0,
        )

    monkeypatch.setattr(run_module, "parse_pnr_result", fake_parse)
    monkeypatch.setattr(run_module, "run_synthesis_job_pnr_search", fake_search)

    assert (
        _run_pnr_attempts(
            manifest_path, config, tmp_path, resume=True, only_job_id=None
        )
        == 0
    )
    reloaded = json.loads((tmp_path / "pnr_results.json").read_text())
    assert reloaded[job.job_id][0]["status"] == "clean"
