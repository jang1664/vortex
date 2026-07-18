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


def test_retry_margin_sequence_and_validation(tmp_path: Path) -> None:
    path = tmp_path / "candidates.yaml"
    path.write_text(
        """include:\n  modules:\n    - pattern: xbar\npnr:\n  max_attempts: 4\n  initial_area_margin: 1.1\n  area_margin_multiplier: 1.15\n"""
    )
    config = load_analysis_config(path)
    assert config.pnr.margins() == pytest.approx([1.1, 1.265, 1.45475, 1.6729625])

    path.write_text(
        """include:\n  modules:\n    - pattern: xbar\npnr:\n  max_attempts: 0\n"""
    )
    with pytest.raises(ValueError, match="at least 1"):
        load_analysis_config(path)


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
    "statuses,expected_calls,expected_return",
    [
        (["drc_failed", "drc_failed"], 2, 0),
        (["drc_failed", "clean"], 2, 0),
        (["infrastructure_failed"], 1, 2),
    ],
)
def test_bounded_retry_policy(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    statuses: list[str],
    expected_calls: int,
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

    def fake_run(pnr_config):
        calls.append(pnr_config)
        (Path(pnr_config.design_dir) / pnr_config.pnr_dir).mkdir(
            parents=True, exist_ok=True
        )
        status = statuses[len(calls) - 1]
        return {"clean": 0, "drc_failed": 3, "infrastructure_failed": 2}[status]

    def fake_parse(run_dir, *, return_code, attempt, **kwargs):
        status = statuses[attempt - 1]
        return PnRResult(
            status=status,
            return_code=return_code,
            run_dir=str(run_dir),
            attempt=attempt,
            cell_area=100 if status == "clean" else None,
            core_area=200 if status == "clean" else None,
            signal_routing_drc_errors=0 if status == "clean" else 7,
        )

    monkeypatch.setattr(run_module.PnRConfig, "run", fake_run)
    monkeypatch.setattr(run_module, "parse_pnr_result", fake_parse)

    ret = _run_pnr_attempts(
        manifest_path, config, tmp_path, resume=False, only_job_id=None
    )

    assert ret == expected_return
    assert len(calls) == expected_calls


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
            signal_routing_drc_errors=0,
            cell_area=100,
            core_area=200,
        )

    monkeypatch.setattr(run_module, "parse_pnr_result", fake_parse)
    monkeypatch.setattr(
        run_module.PnRConfig,
        "run",
        lambda *_: pytest.fail("clean preserved attempt must not rerun ICC2"),
    )

    assert (
        _run_pnr_attempts(
            manifest_path, config, tmp_path, resume=True, only_job_id=None
        )
        == 0
    )
    reloaded = json.loads((tmp_path / "pnr_results.json").read_text())
    assert reloaded[job.job_id][0]["status"] == "clean"
