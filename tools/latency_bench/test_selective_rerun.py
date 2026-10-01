from __future__ import annotations

import csv
from dataclasses import replace
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

from .kernel_variants import parse_variants, source_identity, variant_environment
from .raw_db import RAW_DB_COLUMNS
from .selective_rerun import merge_successful_rows, selected_suite, pending_suite, publish_staged
from .suite import BenchCase, BenchDefaults, BenchSuite


def write_rows(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        writer.writerows([{key: row.get(key, "") for key in RAW_DB_COLUMNS} for row in rows])


class SelectiveRerunTests(unittest.TestCase):
    def test_merge_preserves_failed_and_unselected_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = [dict(app=app, args="-n 16", fpga_bin_label="C4", xclbin_sha256="sha",
                        exec_key=app, status="pass", avg_us="100", run_id="old")
                   for app in ("softmax", "quant", "rope")]
            new = [dict(old[0], avg_us="75", run_id="new"), dict(old[1], status="fail", run_id="new")]
            write_rows(root / "main.csv", old)
            write_rows(root / "staged.csv", new)
            summary = merge_successful_rows(root / "staged.csv", root / "main.csv", "new")
            with (root / "main.csv").open(newline="") as source:
                actual = {row["app"]: row for row in csv.DictReader(source)}
            self.assertEqual("75", actual["softmax"]["avg_us"])
            self.assertEqual("old", actual["quant"]["run_id"])
            self.assertEqual("old", actual["rope"]["run_id"])
            self.assertEqual(1, summary["failed"])
            self.assertEqual(2, summary["preserved"])

    def test_selection_includes_historical_probe_once_and_routes_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "raw_db.csv"
            app = "softmax_layout_fused"
            rows = [dict(app=app, args=args, exec_key=str(i), fpga_bin_label="C4", xclbin_sha256="sha")
                    for i, args in enumerate(("-seqq 16 -seqk 16", "-seqq 1 -seqk 31", "-seqq 1 -seqk 31"))]
            write_rows(db, rows)
            suite = BenchSuite("test", BenchDefaults(), [
                BenchCase("base", app, "-seqq 16 -seqk 16", stage="prefill"),
                BenchCase("other", "rope", "-n 16", stage="prefill")],
                experiment={"candidates": {"C4": {"xclbin_sha256": "sha"}}})
            selected = selected_suite(suite, db, ("app=~softmax*",), "C4", "prefill")
            self.assertEqual(1, len(selected.cases))
            generation = replace(suite, cases=[])
            selected = selected_suite(generation, db, ("app=~softmax*",), "C4", "generation")
            self.assertEqual(1, len(selected.cases))
            self.assertEqual("historical_raw_db", selected.cases[0].source)

    def test_rerun_promotes_historical_probe_even_when_suite_interpolates_it(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "raw_db.csv"
            app, args = "softmax_layout_fused", "-seqq 1 -seqk 1040"
            write_rows(db, [dict(app=app, args=args, exec_key="probe", fpga_bin_label="C4", xclbin_sha256="sha")])
            suite = BenchSuite("test", BenchDefaults(), [BenchCase("estimate", app, args,
                stage="generation", measurement_kind="interpolated")],
                experiment={"candidates": {"C4": {"xclbin_sha256": "sha"}}})
            selected = selected_suite(suite, db, ("app=softmax_layout_fused",), "C4", "generation")
            self.assertEqual(1, sum(c.measurement_kind == "measured" for c in selected.cases))

    def test_resume_uses_strict_coverage_instead_of_status_alone(self):
        from .runner import MeasurementCoverage, MeasurementEvidence, MeasurementReuseState
        suite = BenchSuite("test", BenchDefaults(), [BenchCase("a", "softmax", "-n 16"),
            BenchCase("b", "quant", "-n 16")], experiment={"candidates": {"C4": {"xclbin_sha256": "sha"}}})
        coverage = MeasurementCoverage((MeasurementEvidence(suite.cases[0].exec_key,
            MeasurementReuseState.REUSE, ()), MeasurementEvidence(suite.cases[1].exec_key,
            MeasurementReuseState.PENDING, ("source changed",))))
        with mock.patch("tools.latency_bench.runner.strict_measurement_policy"), \
             mock.patch("tools.latency_bench.runner.evaluate_measurement_coverage", return_value=coverage):
            pending, reused = pending_suite(suite, Path("raw_db.csv"), SimpleNamespace(fpga_bin_label="C4"))
        self.assertEqual(1, reused)
        self.assertEqual(["quant"], [c.app for c in pending.cases])

    def test_interrupted_publication_preserves_other_apps_and_rebases_evidence(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory); staging = out / "staging"
            run = staging / "runs" / "new"; run.mkdir(parents=True)
            (run / "kernel_variants.json").write_text(json.dumps({"apps": {"softmax": {"selected_variant": "v"}}}))
            write_rows(out / "raw_db.csv", [dict(app="quant", args="-n 16", fpga_bin_label="C4",
                xclbin_sha256="sha", status="pass", run_id="old", exec_key="quant")])
            write_rows(staging / "raw_db.csv", [dict(app=app, args="-n 16", fpga_bin_label="C4",
                xclbin_sha256="sha", status="pass", run_id="new", exec_key=app, raw_csv=str(run / "raw.csv"))
                for app in ("softmax", "quant")])
            result = publish_staged(staging, out, {"softmax"})
            self.assertEqual(1, result["successful"])
            with (out / "raw_db.csv").open(newline="") as f:
                rows = {row["app"]: row for row in csv.DictReader(f)}
            self.assertEqual("old", rows["quant"]["run_id"])
            self.assertEqual(str(out / "runs/new/raw.csv"), rows["softmax"]["raw_csv"])
            self.assertTrue((out / "runs/new/kernel_variants.json").is_file())

    def test_reuse_policy_resolves_profile_alias_to_actual_variant(self):
        from .runner import RunOptions, strict_measurement_policy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = "kv_cache_quant_w4a16"
            makefile = root / "tests/regression" / app / "Makefile"
            makefile.parent.mkdir(parents=True); makefile.write_text("fixture")
            config = root / "config.sh"; config.write_text("export CONFIGS='-DEXT_ZFH_ENABLE'\n")
            suite = BenchSuite("test", BenchDefaults(), [BenchCase("case", app, "-n 16")])
            options = RunOptions(root, root, root, "u55c", configs=config, fpga_bin_label="C4",
                provenance={"fpga_period_s": 1e-8}, application_source_identity="id",
                kernel_variants=(app + "=groupwise",))
            with mock.patch("tools.latency_bench.kernel_variants.query_selection",
                            return_value=("groupwise", "groupwise_fp16", [])):
                policy = strict_measurement_policy(suite, options, xclbin_sha256="sha")
            self.assertEqual("groupwise", policy.kernel_variants[app])
            self.assertEqual("groupwise_fp16", policy.resolved_kernel_variants[app])

    def test_default_variant_capture_records_actual_selection_and_binary(self):
        import json
        from .kernel_variants import capture
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = "softmax_layout_fused"
            binary = root / "tests/regression" / app / "kernel.vxbin"
            binary.parent.mkdir(parents=True); binary.write_bytes(b"compiled")
            out = root / "out"; out.mkdir(); (out / "manifest.json").write_text("{}")
            with mock.patch("tools.latency_bench.kernel_variants.query_selection",
                            return_value=("rev2_shuffle_grouped", "rev2_shuffle_grouped", ["kernel.cpp"])), \
                 mock.patch.dict("os.environ", {}, clear=True):
                record = capture(root, out, app)
            self.assertEqual("makefile_default", record["selection"])
            self.assertEqual("rev2_shuffle_grouped", record["selected"])
            self.assertEqual(64, len(record["kernel_vxbin_sha256"]))
            self.assertEqual(record, json.loads((out / "manifest.json").read_text())["kernel_variants"][app])

    def test_refinement_cache_changes_when_variant_changes_without_anchor_change(self):
        from .interpolation import _recovery_identity
        suite = BenchSuite("test", BenchDefaults(), [BenchCase("a", "softmax", "-n 16")])
        args = SimpleNamespace(metric="fpga_cycle", sampling_strategy="midpoint", seed=0,
            validation_samples=3, measure_command="bench --kernel-variant softmax=a --application-source-identity source")
        before = _recovery_identity(suite, args, ["softmax"])
        args.measure_command = "bench --kernel-variant softmax=b --application-source-identity source"
        self.assertNotEqual(before, _recovery_identity(suite, args, ["softmax"]))

    def test_refinement_filter_omits_invariant_kernel_without_candidates(self):
        from analysis_workspace.latency_on_hw import pipeline
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = pipeline.PipelineSettings(tag="test", workspace=root, state_base=root, models=("llama2",),
                candidates=("C4",), case_filters=("app=~*",))
            suite = BenchSuite("test", BenchDefaults(), [
                BenchCase("quant", "kv_cache_quant_layout_fused_w4a16", "-k 1", backend="quant",
                          measurement_kind="invariant_reused"),
                BenchCase("soft", "softmax_layout_fused", "-seqq 1", backend="soft",
                          measurement_kind="interpolated")])
            with mock.patch.object(pipeline, "_suite_for", return_value=root / "suite.pkl"), \
                 mock.patch("tools.latency_bench.suite.load_suite", return_value=suite):
                tasks = pipeline._refine_tasks(settings)
            self.assertEqual(1, len(tasks))
            values = [tasks[0].command[i+1] for i,token in enumerate(tasks[0].command[:-1])
                      if token == "--kernel-type"]
            self.assertEqual(["softmax_layout_fused|soft"], values)

    def test_variant_validation_and_app_scoped_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            app = repo / "tests/regression/softmax"
            app.mkdir(parents=True)
            (app / "Makefile").write_text("SOFTMAX_VARIANT ?= a\nSOFTMAX_VARIANTS := a b\n")
            (app / "kernel.a.cpp").write_text("void kernel() {}\n")
            parsed = parse_variants(["softmax=b"], repo)
            self.assertEqual({"SOFTMAX_VARIANT": "b"}, variant_environment(repo, parsed))
            before = source_identity(repo, "softmax")
            (repo / "unrelated.cpp").write_text("unrelated\n")
            self.assertEqual(before, source_identity(repo, "softmax"))
            (app / "kernel.a.cpp").write_text("void kernel() { int a = 1; }\n")
            self.assertNotEqual(before, source_identity(repo, "softmax"))
            for value in ("softmax=missing", "softmax=a;bad", "missing=a"):
                with self.assertRaises(ValueError):
                    parse_variants([value], repo)

    def test_forced_pipeline_run_bypasses_complete_measurement_adoption(self):
        from analysis_workspace.latency_on_hw import pipeline
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = pipeline.PipelineSettings(tag="test", workspace=root, state_base=root,
                                                  models=("llama2",), candidates=("C4",))
            task = pipeline.TaskSpec(key="run:fixture", stage="run",
                inputs={"suite": pipeline.json_identity({"fixture": True})},
                effective_parameters={}, outputs=(pipeline.OutputSpec(root / "marker"),),
                resources=(root,), command=("false",),
                metadata={"suite": "fixture", "raw_db": str(root / "raw_db.csv"), "marker": str(root / "marker")})
            coverage = SimpleNamespace(complete=True, blocked_exec_keys=(), evidence=())
            with mock.patch.object(pipeline, "build_stage_tasks", return_value=(task,)), \
                 mock.patch.object(pipeline, "_legacy_writer", return_value=None), \
                 mock.patch.object(pipeline, "_full_input_problems", return_value=[]), \
                 mock.patch.object(pipeline, "_validate_excluded_prerequisites", return_value=[]), \
                 mock.patch.object(pipeline, "_strict_coverage_for_run_task", return_value=coverage), \
                 mock.patch.object(pipeline, "_adopt_run_task") as adopt, \
                 mock.patch.object(pipeline, "_execute_task") as execute:
                code, summary = pipeline.run_pipeline(settings, first="run", last="run", rerun="run")
            self.assertEqual(0, code)
            self.assertEqual([task.key], summary["executed"])
            adopt.assert_not_called()
            execute.assert_called_once()


if __name__ == "__main__":
    unittest.main()
