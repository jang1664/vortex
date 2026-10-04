"""Tests for the regression gate, without allocating an FPGA."""
import json
import os
from dataclasses import asdict
import tempfile
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from ci import test_llm_regression as regression
from tools.latency_bench.fpga_bins import FpgaBinAlias


class RegressionTests(unittest.TestCase):
    def test_compile_contract_checks_equality_without_width_whitelist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VX_config.h").write_text("")
            source = root / "check.cpp"
            source.write_text('#include "' + str(regression.REPO / "tests/regression/vector_common/config_check.h") + '"\n')
            for threads, row, col in ((16, 16, 16), (16, 32, 16), (16, 16, 32)):
                command = ["/usr/bin/g++", "-std=c++17", "-fsyntax-only", "-I" + directory,
                           "-DENABLE_GEMM_ACCEL", f"-DNUM_THREADS={threads}",
                           f"-DMXU_ROW={row}", f"-DMXU_COL={col}", str(source)]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(threads == row == col, result.returncode == 0, result.stderr)

    def test_all_correctness_before_any_benchmark(self):
        selected = regression.cases()[:4]
        results = []
        stages = regression.execution_stages(selected, results, "both")
        self.assertEqual(("correctness", selected), next(stages))
        results.extend(dict(phase="correctness", status="PASS") for _ in selected)
        self.assertEqual(("benchmark", selected), next(stages))
        results[0]["status"] = "FAIL"
        stages = regression.execution_stages(selected, results, "both")
        next(stages)
        with self.assertRaises(StopIteration):
            next(stages)
        results.pop()
        results[0]["status"] = "PASS"
        stages = regression.execution_stages(selected, results, "both")
        next(stages)
        with self.assertRaises(StopIteration):
            next(stages)

    def test_routing_and_coverage(self):
        cases = regression.cases()
        apps = {case.app for case in cases}
        self.assertEqual(22, len(apps))
        self.assertEqual(78, len(cases))
        for app in apps:
            self.assertGreaterEqual(len([case for case in cases if case.app == app]), 3)
        for case in cases:
            expected = ("C3" if case.app == "fpint_gemm_ffn_hw_naive" else
                        "C4" if "layout_fused" in case.app or case.app == "fpint_gemm_ffn_hw" else "C1")
            self.assertEqual(expected, case.candidate)
        for pair in {case.pair for case in cases if case.pair}:
            self.assertEqual(2, len([case for case in cases if case.pair == pair]))

    def test_pipeline_case_file_preserves_routing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cases.json"
            row = dict(candidate="C4", app="kv_cache_quant_layout_fused_w4a16",
                       shape="actual", args="-k 1024 -n 128 --layout-from gemm_c_tiled")
            path.write_text(json.dumps([row]))
            self.assertEqual(row["args"], regression.load_cases(path)[0].args)
            path.write_text(json.dumps([{**row, "candidate": "C1"}]))
            with self.assertRaisesRegex(ValueError, "requires candidate C4"):
                regression.load_cases(path)
            path.write_text(json.dumps([row, row]))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                regression.load_cases(path)
            fused = {**row, "pair": "quant/actual"}
            plain = {**fused, "candidate": "C1", "app": "kv_cache_quant_w4a16"}
            path.write_text(json.dumps([plain, fused]))
            self.assertEqual(2, len(regression.load_cases(path)))
            path.write_text(json.dumps([plain, {**fused, "shape": "different"}]))
            with self.assertRaisesRegex(ValueError, "matched C1/C4"):
                regression.load_cases(path)

    def classify(self, text, code=2, app="softmax", small=0.001):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.log"
            path.write_text(text)
            return regression.correctness(path, code, app, small, 0.0001)[0]

    def test_pass_requires_exit_and_marker(self):
        self.assertEqual("PASS", self.classify("PASSED!\n", 0))
        self.assertEqual("PASS", self.classify("requested: PASS (0 errors)\n", 0))
        self.assertEqual("FAIL", self.classify("PASSED!\n", 2))
        self.assertEqual("FAIL", self.classify("benchmark complete\n", 0))
        rms = ("verify: max_diff=0 errors=0\nverify [2]      : max_diff=0 errors=0\n"
               "verify [3] fused: max_diff=0 errors=0\n")
        self.assertEqual("PASS", self.classify(rms, 0, "rms_norm_layout_fused"))
        self.assertEqual("FAIL", self.classify(rms.replace("errors=0", "errors=1", 1), 0, "rms_norm_layout_fused"))
        silu = "fused output (real rows only): max_diff=9e-4, errors=0 (tol=1e-03)\n"
        self.assertEqual("PASS", self.classify(silu, 0, "silu_layout_fused"))
        self.assertEqual("FAIL", self.classify(silu.replace("errors=0", "errors=1"), 0, "silu_layout_fused"))

    def test_small_value_exception_is_bounded_and_explicit(self):
        text = ("Error at [0,0,0,0]: GPU=0.000060, CPU=0.000020, diff=0.000040\n"
                "  Max absolute diff: 0.000040\nFAILED! (1 errors)\n")
        self.assertEqual("PASS_FP16_EXCEPTION", self.classify(text))
        self.assertEqual("PASS_FP16_EXCEPTION", self.classify(text.replace("diff: 0.000040", "diff: 0.000977")))
        self.assertEqual("FAIL", self.classify(text, small=0))
        self.assertEqual("FAIL", self.classify(text, code=124))
        self.assertEqual("FAIL", self.classify(text, app="kv_cache_quant_w4a16"))
        self.assertEqual("FAIL", self.classify(text.replace("(1 errors)", "(11 errors)")))
        self.assertEqual("FAIL", self.classify(text + "Row sum error at [0]: GPU sum=0\n"))
        self.assertEqual("FAIL", self.classify(text.replace("0.000060", "nan")))
        self.assertEqual("FAIL", self.classify(text.replace("0.000020", "1.000020")))
        self.assertEqual("FAIL", self.classify(text + "Modified padding at k=17\n"))

    def test_extended_mismatch_log_requires_every_failed_value(self):
        records = [f"Error at {i}: GPU=0.000000, CPU=0.000040, diff=0.000040\n"
                   for i in range(18)]
        summary = "FAILED! (18 errors)\n"
        self.assertEqual("PASS_FP16_EXCEPTION", self.classify("".join(records) + summary))
        self.assertEqual("FAIL", self.classify("".join(records[:-1]) + summary))
        records[-1] = "Error at 17: GPU=0.000000, CPU=1.000000, diff=1.000000\n"
        self.assertEqual("FAIL", self.classify("".join(records) + summary))

    def test_config_paths_require_unambiguous_hardware_image(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "test.sh"
            config.write_text('export CONFIGS="-DGEMM_NAIVE"\n')
            aliases = {"one": FpgaBinAlias("/image/one", str(config)),
                       "same": FpgaBinAlias("/image/one", str(config))}
            self.assertEqual(config, regression.resolve_selection(str(config), "xrt-vcs-sim", {}).config)
            with patch.object(regression, "resolve_fpga_bin_artifacts"):
                self.assertIn(regression.resolve_selection(str(config), "hw", aliases).alias, aliases)
                aliases["other"] = FpgaBinAlias("/image/two", str(config))
                with self.assertRaisesRegex(ValueError, "explicit FPGA alias"):
                    regression.resolve_selection(str(config), "hw", aliases)
                self.assertEqual("one", regression.resolve_selection("one", "hw", aliases).alias)
            self.assertEqual("C3", regression.infer_candidate(regression.Selection(config, None)))

    def test_per_kernel_inclusive_overhead_limits(self):
        for name, limit in (("elmul", 50), ("softmax", 30), ("kv_cache_quant_w4a16", 30)):
            cases = [case for case in regression.cases() if case.pair == name + "/decode"]
            rows = []
            for case, cycle in zip(cases, (100, 100 + limit)):
                rows.extend([dict(app=case.app, shape=case.shape, phase="correctness", status="PASS"),
                             dict(app=case.app, shape=case.shape, phase="benchmark", status="PASS", cycle=cycle)])
            pair = regression.comparisons(cases, rows, 50)[0]
            self.assertEqual(limit, pair["limit_pct"])
            self.assertEqual("PASS", pair["status"])
            rows[-1]["cycle"] += 1
            self.assertEqual("FAIL", regression.comparisons(cases, rows, 50)[0]["status"])
        args = regression.parser().parse_args(["hw"])
        self.assertEqual((50, 30, 30), (args.max_overhead_pct,
                                      args.softmax_max_overhead_pct, args.quant_max_overhead_pct))

    def test_reuse_requires_matching_source_variant_config_and_case(self):
        case = regression.cases()[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.sh"
            config.write_text("# config\n")
            log = root / "passed.log"
            log.write_text("PASSED!\n")
            metadata = dict(mode="hw", fp16_small_value=0.001, fp16_abs_tol=0.0001,
                            configs={case.candidate: dict(config=str(config), alias="image")},
                            source_identities={case.app: "source-a"},
                            kernel_variants={case.app: dict(selected="default")},
                            cases=[asdict(case)])
            row = dict(candidate=case.candidate, app=case.app, shape=case.shape,
                       phase="correctness", status="PASS", config=str(config), log=str(log))
            report = root / "results.json"
            report.write_text(json.dumps(dict(metadata=metadata, results=[row])))
            self.assertEqual(1, len(regression.reuse_correctness(report, [case], metadata)))
            for key, value in (("source_identities", {case.app: "source-b"}),
                               ("kernel_variants", {case.app: dict(selected="other")}),
                               ("configs", {case.candidate: dict(config=str(config), alias="other")})):
                changed = dict(metadata, **{key: value})
                self.assertEqual([], regression.reuse_correctness(report, [case], changed))
            with self.assertRaisesRegex(ValueError, "different mode"):
                regression.reuse_correctness(report, [case], dict(metadata, mode="xrt-vcs-sim"))
            newer = log.stat().st_mtime_ns + 1_000_000_000
            os.utime(config, ns=(newer, newer))
            self.assertEqual([], regression.reuse_correctness(report, [case], metadata))

    def test_speed_never_approves_failed_or_unmeasured_correctness(self):
        cases = [case for case in regression.cases() if case.pair == "softmax/prefill"]
        rows = []
        for case, cycle in zip(cases, (100, 130)):
            rows.extend([dict(app=case.app, shape=case.shape, phase="correctness", status="PASS"),
                         dict(app=case.app, shape=case.shape, phase="benchmark", status="PASS", cycle=cycle)])
        self.assertEqual("PASS", regression.comparisons(cases, rows, 50)[0]["status"])
        rows[-1]["cycle"] = 131
        self.assertEqual("FAIL", regression.comparisons(cases, rows, 50)[0]["status"])
        rows[-1]["cycle"] = 100
        rows[0]["status"] = "FAIL"
        self.assertEqual("FAIL", regression.comparisons(cases, rows, 50)[0]["status"])
        self.assertEqual("NOT_CHECKED", regression.comparisons(cases[:1], rows, 50)[0]["status"])


if __name__ == "__main__":
    unittest.main()
