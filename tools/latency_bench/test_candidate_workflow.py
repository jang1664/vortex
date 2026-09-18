from __future__ import annotations

import json
import os
import pickle
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import pandas as pd

from tools.latency_bench.candidate_map import resolve_candidate_map, validate_run_selection
from tools.latency_bench.compose import ComposeOptions, compose_latency
from tools.latency_bench.generate_suites import GenerateSuitesOptions, generate_suites
from tools.latency_bench.merge_suites import MergeSuitesOptions, merge_suites
from tools.latency_bench.runner import write_suite_snapshots
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite, apply_case_filters, load_suite, resolve_case_fpga_bin, suite_to_expanded_yaml
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

    def test_existing_experiment_cannot_be_rebound_by_overwrite(self):
        source = self.root / "source.yaml"
        write_suite_payload(source, suite_to_expanded_yaml(self._suite()))
        options = GenerateSuitesOptions(source, self.root / "generated", candidate_map=self.mapping, output_format="pkl")
        generate_suites(options)
        Path(self.snapshot["candidates"]["C1"]["xclbin"]).write_text("replacement")
        with self.assertRaisesRegex(ValueError, "different FPGA selection"):
            generate_suites(replace(options, overwrite=True))

    def test_model_c2_suites_keep_all_existing_reuse(self):
        repo = Path(__file__).resolve().parents[2]
        for model in ("llama2_7b", "llama3_8b"):
            for stage in ("prefill", "generation"):
                source = repo / "analysis_workspace/latency_on_hw/suites" / model / f"{model}_{stage}_C2.yaml"
                index = generate_suites(GenerateSuitesOptions(
                    source, self.root / f"{model}_{stage}", candidate_map=self.mapping,
                    output_format="pkl", batch_values=(1,), seq_len_values=(128,),
                    generation_out_token_values=(3,), generation_decode_measurement="sampled",
                    generation_decode_sample_interval=2))
                self.assertEqual({"C1", "C3", "C4"}, {entry["fpga_bin"] for entry in index["generated"]})
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
