from __future__ import annotations

import json
import os
import pickle
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import pandas as pd

from tools.latency_bench.candidate_map import resolve_candidate_map, validate_run_selection, validate_snapshot, parse_execution_candidates
from tools.latency_bench.compose import ComposeOptions, compose_latency
from tools.latency_bench.generate_suites import GenerateSuitesOptions, generate_suites
from tools.latency_bench.merge_suites import MergeSuitesOptions, merge_suites
from tools.latency_bench.runner import write_suite_snapshots
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite, SuiteMatrixOverrides, apply_case_filters, load_suite, resolve_case_fpga_bin, suite_to_expanded_yaml
from tools.latency_bench.suite_io import indexed_suites, read_suite_payload, write_suite_payload
from tools.latency_bench.yaml_io import safe_dump


class CandidateWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        aliases = {}
        for label in ("C1", "C2", "C3", "C4"):
            image = self.root / label
            binary = image / "bin"
            binary.mkdir(parents=True)
            (binary / "vortex_afu.xclbin").write_text(label)
            (binary / "vortex_afu.xclbin.info").write_text("Name: ulp_ucs_aclk_kernel_00\nAchieved Freq: 80 MHz\n")
            (image / "manifest.json").write_text("{}")
            config = image / "config.sh"
            config.write_text("export CONFIGS='-DNUM_THREADS=16'\n")
            aliases[f"new_{label}"] = {"path": str(binary), "configs": str(config)}
        alias_map = self.root / "aliases.yaml"
        alias_map.write_text(safe_dump({"aliases": aliases}))
        env = patch.dict(os.environ, {"VORTEX_FPGA_BIN_ALIAS_MAP": str(alias_map)})
        env.start()
        self.addCleanup(env.stop)
        self.mapping = self.root / "candidates.yaml"
        self.mapping.write_text(safe_dump({"schema_version": 1, "candidates": {c: f"new_{c}" for c in ("C1", "C2", "C3", "C4")}}))
        self.snapshot = resolve_candidate_map(self.mapping)

    def _suite(self):
        return BenchSuite(name="C2", defaults=BenchDefaults(fpga_bin="C4"), experiment=self.snapshot,
                          fpga_bins={"default": "C4", "by_app": {"sgemm_tcu": "C1", "fpint_gemm_ffn_hw_naive": "C3"}},
                          cases=[BenchCase("tcu", "sgemm_tcu", "-m 16 -n 128 -k 128"),
                                 BenchCase("naive", "fpint_gemm_ffn_hw_naive", "-m 16 -n 128 -k 128 -q 32"),
                                 BenchCase("vector", "eladd", "-n 128")])

    def test_yaml_pkl_generation_merge_and_relocation_preserve_routing(self):
        source = self.root / "source.yaml"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        groups = []
        for fmt in ("yaml", "pkl"):
            out = self.root / fmt
            generated = generate_suites(GenerateSuitesOptions(source, out, output_format=fmt, candidate_map=self.mapping))
            self.assertEqual({"C1", "C3", "C4"}, {e["fpga_bin"] for e in generated["generated"]})
            result = merge_suites(MergeSuitesOptions((str(out / "index.yaml"),), out / "merged", group_by_fpga_bin=True, output_format=fmt))
            suites = [load_suite(path) for _, path in indexed_suites(result["index"])]
            groups.append([(s.defaults, s.cases, s.experiment) for s in suites])
            moved = self.root / f"moved_{fmt}"
            (out / "merged").rename(moved)
            self.assertEqual(3, len(indexed_suites(moved / "index.yaml")))
        # Source filenames differ; merge's source bookkeeping is not serialized.
        self.assertEqual(groups[0], groups[1])

    def test_snapshot_overrides_and_filters_remain_pkl(self):
        source = self.root / "source.pkl"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        suite = apply_case_filters(load_suite(source, warmup_override=0, iterations_override=7), ("app=eladd",))
        out = self.root / "run"
        out.mkdir()
        self.assertEqual("serialized_pkl", write_suite_snapshots(suite, out))
        restored = load_suite(out / "suite.expanded.pkl")
        self.assertEqual(1, len(restored.cases))
        self.assertEqual((0, 7), (restored.cases[0].warmup, restored.cases[0].iterations))
        self.assertFalse(list(out.glob("*.yaml")))
        self.assertEqual(self.snapshot, restored.experiment)

    def test_changed_image_and_config_rejected(self):
        validate_run_selection(self.snapshot)
        config = Path(self.snapshot["candidates"]["C3"]["config"])
        config.write_text("changed config")
        with self.assertRaisesRegex(ValueError, "selection changed"):
            validate_run_selection(self.snapshot)
        refreshed = resolve_candidate_map(self.mapping)
        Path(refreshed["candidates"]["C4"]["xclbin"]).write_text("changed image")
        with self.assertRaisesRegex(ValueError, "selection changed"):
            validate_run_selection(refreshed)

    def test_partial_selection_ignores_unavailable_candidates_but_validates_selected_image(self):
        self.mapping.write_text(safe_dump({"schema_version": 1, "candidates": {
            "C1": "new_C1", "C2": "none", "C3": None, "C4": "none",
        }}))
        snapshot = resolve_candidate_map(self.mapping, ("C1",))
        self.assertEqual(2, snapshot["schema_version"])
        self.assertEqual({"C1"}, set(snapshot["candidates"]))
        validate_snapshot(snapshot)
        validate_run_selection(snapshot)
        with self.assertRaisesRegex(ValueError, "alias"):
            resolve_candidate_map(self.mapping, ("C4",))
        # Filling unrelated entries later does not invalidate this run.
        self.mapping.write_text(safe_dump({"schema_version": 1, "candidates": {
            "C1": "new_C1", "C3": "new_C3", "C4": "new_C4",
        }}))
        validate_run_selection(snapshot)
        Path(snapshot["candidates"]["C1"]["config"]).write_text("changed")
        with self.assertRaisesRegex(ValueError, "selection changed"):
            validate_run_selection(snapshot)

    def test_subset_generation_and_merge_preserve_shared_workloads(self):
        source = self.root / "source.yaml"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        for selected in (("C1",), ("C3", "C4"), ("C1", "C3", "C4")):
            with self.subTest(selected=selected):
                out = self.root / "_".join(selected)
                index = generate_suites(GenerateSuitesOptions(
                    source, out, candidate_map=self.mapping, candidates=selected,
                    output_format="pkl"))
                self.assertEqual(set(selected), {entry["fpga_bin"] for entry in index["generated"]})
                merged = merge_suites(MergeSuitesOptions(
                    (str(out / "index.yaml"),), out / "merged", group_by_fpga_bin=True))
                self.assertEqual(set(selected), {label for label, _ in indexed_suites(merged["index"])})
                for label, path in indexed_suites(merged["index"]):
                    suite = load_suite(path)
                    validate_run_selection(suite.experiment)
                    self.assertTrue(all(resolve_case_fpga_bin(suite, case) == label for case in suite.cases))

    def test_additive_selection_can_extend_existing_suites_without_rebinding_images(self):
        source = self.root / "source.yaml"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        options = GenerateSuitesOptions(source, self.root / "generated",
                                       candidate_map=self.mapping, candidates=("C1",))
        original = generate_suites(options)
        expanded_options = replace(options, candidates=("C1", "C3", "C4"), overwrite=True)
        expanded = generate_suites(expanded_options)
        self.assertEqual({"C1", "C3", "C4"}, {entry["fpga_bin"] for entry in expanded["generated"]})
        self.assertEqual(original["experiment"]["candidates"]["C1"], expanded["experiment"]["candidates"]["C1"])
        validate_run_selection(original["experiment"])
        with self.assertRaisesRegex(ValueError, "different FPGA selection"):
            generate_suites(replace(options, overwrite=True))
        Path(expanded["experiment"]["candidates"]["C1"]["xclbin"]).write_text("changed")
        with self.assertRaisesRegex(ValueError, "different FPGA selection"):
            generate_suites(expanded_options)

    def test_expanded_selection_composes_existing_c1_raw_rows(self):
        partial = resolve_candidate_map(self.mapping, ("C1",))
        expanded = resolve_candidate_map(self.mapping, ("C1", "C3", "C4"))
        target = partial["candidates"]["C1"]
        case = BenchCase("gemm", "sgemm_tcu", "-m 16 -n 128 -k 128")
        suite = BenchSuite("C1", BenchDefaults(fpga_bin="C1"), [case], experiment=expanded)
        raw = self.root / "raw.csv"
        pd.DataFrame([dict(
            run_id="partial-run", timestamp_utc="2026-09-30", fpga_bin_label="C1",
            xclbin_sha256=target["xclbin_sha256"], fpga_bin_alias=target["alias"],
            selection_digest=partial["selection_digest"], app=case.app, args=case.args,
            exec_key="old-exec", status="pass", p50_us=12, power_avg_w=50, power_dynamic_avg_w=10,
        )]).to_csv(raw, index=False)
        composed = compose_latency(suite, ComposeOptions((raw,), self.root / "out", metric="p50_us"))
        self.assertEqual(12, composed.iloc[0]["latency_us"])
        self.assertEqual(50, composed.iloc[0]["power_avg_w"])

    def test_merge_skips_only_intentionally_empty_subset_indexes(self):
        source = self.root / "source.yaml"
        suite = self._suite()
        selected = GenerateSuitesOptions(source, self.root / "nonempty",
                                        candidate_map=self.mapping, candidates=("C1",))
        write_suite_payload(source, suite_to_expanded_yaml(suite))
        generate_suites(selected)
        write_suite_payload(source, suite_to_expanded_yaml(replace(suite, cases=[suite.cases[-1]])))
        empty = self.root / "empty"
        generate_suites(replace(selected, out_dir=empty))
        with self.assertRaisesRegex(ValueError, "empty"):
            indexed_suites(empty / "index.yaml")
        merged = merge_suites(MergeSuitesOptions(
            (str(selected.out_dir / "index.yaml"), str(empty / "index.yaml")),
            self.root / "merged", group_by_fpga_bin=True))
        self.assertEqual(["C1"], [label for label, _ in indexed_suites(merged["index"])])
        write_suite_payload(empty / "index.yaml", {"generated": []})
        with self.assertRaisesRegex(ValueError, "empty"):
            merge_suites(MergeSuitesOptions(
                (str(selected.out_dir / "index.yaml"), str(empty / "index.yaml")),
                self.root / "bad", group_by_fpga_bin=True))

    def test_candidate_selection_rejects_composed_unknown_and_empty_names(self):
        self.assertEqual(("C1", "C4"), parse_execution_candidates("C4,C1,C1"))
        for text in ("", "C2", "C5"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_execution_candidates(text)
        with self.assertRaisesRegex(ValueError, "schema"):
            validate_snapshot({**self.snapshot, "candidates": {"C1": self.snapshot["candidates"]["C1"]}})

    def _check_make_cases_selected_source(self, selected):
        repo = Path(__file__).resolve().parents[2]
        workspace = repo / "analysis_workspace/latency_on_hw"
        self.mapping.write_text(safe_dump({"schema_version": 1, "candidates": {
            **{label: "none" for label in ("C1", "C2", "C3", "C4")}, selected: f"new_{selected}",
        }}))
        for model in ("llama2_7b", "llama3_8b"):
            out = self.root / model
            result = subprocess.run([
                "bash", str(workspace / "make_cases.sh"),
                "--input", str(workspace / "suites" / model), "--output", str(out),
                "--candidate-map", str(self.mapping), "--candidates", selected,
                "--batches", "1", "--seq-lens", "128", "--generation-out-tokens", "3",
                "--decode-measurement", "sampled", "--decode-sample-interval", "2",
            ], env={**os.environ, "PYTHON": sys.executable}, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout[-2000:] + result.stderr[-2000:])
            for stage in ("prefill", "generation"):
                entries = indexed_suites(out / f"{stage}_merged/index.yaml")
                self.assertEqual([selected], [label for label, _ in entries])
                suite = load_suite(entries[0][1])
                self.assertEqual({selected}, set(suite.experiment["candidates"]))
                self.assertTrue(suite.cases)
                validate_run_selection(suite.experiment)
                if selected == "C1":
                    apps = {case.app for case in suite.cases}
                    self.assertTrue({"sgemm_tcu", "rmsnorm", "eladd", "rms_norm_layout_fused", "kv_cache_quant_layout_fused_w4a16"} <= apps, apps)
                else:
                    self.assertTrue(all(case.kind == "gemm" and case.app == "fpint_gemm_ffn_hw" for case in suite.cases))

    def test_make_cases_generates_c1_with_unavailable_other_images(self):
        self._check_make_cases_selected_source("C1")

    def test_make_cases_generates_c4_without_vector_images(self):
        self._check_make_cases_selected_source("C4")

    def test_all_model_suites_route_non_gemm_to_c1_and_preserve_gemm_sources(self):
        repo = Path(__file__).resolve().parents[2]
        sources = sorted((repo / "analysis_workspace/latency_on_hw/suites").glob("llama*/*.yaml"))
        self.assertTrue(sources)
        overrides = SuiteMatrixOverrides(batch_values=(1,), seq_len_values=(128,),
                                         generation_out_token_values=(3,),
                                         generation_decode_measurement="sampled",
                                         generation_decode_sample_interval=2)
        gemm_sources = {"sgemm_tcu": "C1", "fpint_gemm_ffn_hw_naive": "C3", "fpint_gemm_ffn_hw": "C4"}
        kinds = set()
        for source in sources:
            with self.subTest(source=source.name):
                suite = load_suite(source, matrix_overrides=overrides)
                self.assertTrue(suite.cases)
                for case in suite.cases:
                    kinds.add(case.kind)
                    expected = gemm_sources[case.app] if case.kind == "gemm" else "C1"
                    self.assertEqual(expected, resolve_case_fpga_bin(suite, case), case.case_id)
        self.assertTrue({"gemm", "rmsnorm", "eladd", "layout", "dequantization", "quantization"} <= kinds)

    def test_c1_vector_composition_does_not_relabel_old_c4_measurements(self):
        case = BenchCase("vector", "eladd", "-n 128")
        suite = BenchSuite("C1_vector", BenchDefaults(fpga_bin="C1"), [case], experiment=self.snapshot)
        rows = []
        for label, timestamp, latency in (("C1", "2026-09-29", 12), ("C4", "2026-09-30", 999)):
            target = self.snapshot["candidates"][label]
            rows.append(dict(run_id=label, timestamp_utc=timestamp, fpga_bin_label=label,
                             xclbin_sha256=target["xclbin_sha256"], fpga_bin_alias=target["alias"],
                             exec_key=label, app=case.app, args=case.args, status="pass", p50_us=latency))
        raw = self.root / "raw.csv"
        pd.DataFrame(rows).to_csv(raw, index=False)
        composed = compose_latency(suite, ComposeOptions((raw,), self.root / "out", metric="p50_us", select="latest"))
        self.assertEqual(12, composed.iloc[0]["latency_us"])
        self.assertEqual("C1", composed.iloc[0]["source_fpga_bin_labels"])

    def test_existing_experiment_cannot_be_rebound_by_overwrite(self):
        source = self.root / "source.yaml"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        options = GenerateSuitesOptions(source, self.root / "generated", candidate_map=self.mapping, output_format="pkl")
        generate_suites(options)
        Path(self.snapshot["candidates"]["C1"]["xclbin"]).write_text("replacement")
        with self.assertRaisesRegex(ValueError, "different FPGA selection"):
            generate_suites(replace(options, overwrite=True))

    def test_model_c2_suites_share_c1_vectors_and_c3_naive_gemm(self):
        repo = Path(__file__).resolve().parents[2]
        for model in ("llama2_7b", "llama3_8b"):
            for stage in ("prefill", "generation"):
                source = repo / "analysis_workspace/latency_on_hw/suites" / model / f"{model}_{stage}_C2.yaml"
                index = generate_suites(GenerateSuitesOptions(
                    source, self.root / f"{model}_{stage}", candidate_map=self.mapping,
                    output_format="pkl", batch_values=(1,), seq_len_values=(128,),
                    generation_out_token_values=(3,), generation_decode_measurement="sampled",
                    generation_decode_sample_interval=2))
                self.assertEqual({"C1", "C3"}, {entry["fpga_bin"] for entry in index["generated"]})
                for entry in index["generated"]:
                    suite = load_suite(Path(entry["suite"]))
                    self.assertTrue(all(resolve_case_fpga_bin(suite, case) == entry["fpga_bin"] for case in suite.cases))

    def test_plot_combination_retains_snapshot_and_rejects_mixed_revisions(self):
        from tools.latency_bench.plot import _combine_suites
        suite = self._suite()
        combined, _ = _combine_suites([suite, suite])
        self.assertEqual(self.snapshot, combined.experiment)
        with self.assertRaisesRegex(ValueError, "different FPGA selections"):
            _combine_suites([suite, replace(suite, experiment={})])

    def test_estimate_groups_include_hardware_identity_even_with_custom_columns(self):
        from tools.latency_bench.estimate import _group_key
        row = pd.Series({"app": "eladd", "selection_digest": "one", "expected_xclbin_sha256": "sha1"})
        other = row.copy()
        other["selection_digest"] = "two"
        self.assertNotEqual(_group_key(row, ("app",)), _group_key(other, ("app",)))

    def test_corrupt_schema_and_failed_write(self):
        path = self.root / "suite.pkl"
        payload = suite_to_expanded_yaml(self._suite())
        write_suite_payload(path, payload)
        before = path.read_bytes()
        with patch("tools.latency_bench.suite_io.pickle.dump", side_effect=OSError("full")):
            with self.assertRaises(OSError):
                write_suite_payload(path, payload)
        self.assertEqual(before, path.read_bytes())
        path.write_bytes(pickle.dumps({"format": "vortex-latency-suite", "schema_version": 999}))
        with self.assertRaisesRegex(ValueError, "schema"):
            read_suite_payload(path)

    def test_compose_uses_snapshot_even_after_live_map_changes(self):
        case = BenchCase("vector", "eladd", "-n 128")
        suite = BenchSuite("C1_vector", BenchDefaults(fpga_bin="C4"), [case], experiment=self.snapshot)
        target = self.snapshot["candidates"]["C4"]
        raw = self.root / "raw.csv"
        good = dict(run_id="old", timestamp_utc="2026-01-01", fpga_bin_label="C4", xclbin_sha256=target["xclbin_sha256"],
                    fpga_bin_alias=target["alias"], fpga_bin_dir=target["bin_dir"], exec_key="unused", app=case.app, args=case.args,
                    status="pass", p50_us=12, fpga_period_s=target["fpga_period_s"])
        pd.DataFrame([good, {**good, "run_id": "new", "timestamp_utc": "2026-02-01", "xclbin_sha256": "wrong", "p50_us": 999}]).to_csv(raw, index=False)
        self.mapping.write_text("invalid live mapping")
        composed = compose_latency(suite, ComposeOptions((raw,), self.root / "out", metric="p50_us", select="latest"))
        self.assertEqual(12, composed.iloc[0]["latency_us"])
        self.assertEqual("new_C4", composed.iloc[0]["source_fpga_bin_aliases"])
        self.assertEqual(target["xclbin_sha256"], composed.iloc[0]["expected_xclbin_sha256"])

    def test_power_rejects_other_experiments_in_exact_and_fallback_sources(self):
        from analysis_workspace.latency_on_hw.energy_per_token import PowerResolver, _power_candidates
        target = self.snapshot["candidates"]["C4"]
        row = {"fpga_bin_label": "C4", "app": "eladd", "args": "-n 128", "power_samples": 10,
               "power_avg_w": 50, "xclbin_sha256": "wrong", "selection_digest": "old"}
        resolver = PowerResolver(_power_candidates([row]))
        request = {**row, "selection_digest": self.snapshot["selection_digest"], "expected_xclbin_sha256": target["xclbin_sha256"]}
        self.assertIsNone(resolver.resolve(request).candidate)


if __name__ == "__main__":
    unittest.main()
