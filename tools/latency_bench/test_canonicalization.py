from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.canonicalization import (
    canonicalize_args,
    load_canonicalization_policies,
)
from tools.latency_bench.suite import BenchCase, load_suite


class CanonicalizationTest(unittest.TestCase):
    def test_exec_key_uses_only_xclbin_app_and_measurement_args(self) -> None:
        base = {
            "case_id": "same_kernel",
            "app": "softmax",
            "args": "-batch 1 -heads 32 -seqq 1 -seqk 33",
            "xclbin_sha256": "abc123",
        }
        first = BenchCase(**base, warmup=0, iterations=1)
        different_environment = BenchCase(**base, warmup=7, iterations=99)
        different_xclbin = BenchCase(
            **{**base, "xclbin_sha256": "def456"},
            warmup=0,
            iterations=1,
        )

        self.assertEqual(first.exec_key, different_environment.exec_key)
        self.assertNotEqual(first.exec_key, different_xclbin.exec_key)

    def test_fpint_gemm_aligns_m_n_k_for_supported_fpga_bins(self) -> None:
        policies = load_canonicalization_policies()
        for fpga_bin in ("C1", "C2", "C3", "C4", "C4_2"):
            for app in ("fpint_gemm_ffn_hw", "fpint_gemm_ffn_hw_naive"):
                with self.subTest(fpga_bin=fpga_bin, app=app):
                    result = canonicalize_args(
                        app=app,
                        args="-m 1 -n 33 -k 34 -q 32 -t 0 -d 0",
                        fpga_bin_label=fpga_bin,
                        policies=policies,
                    )
                    self.assertEqual(
                        "-m 8 -n 64 -k 64 -q 32 -t 0 -d 0",
                        result.measurement_args,
                    )

    def test_default_policy_handles_unknown_bin_and_app(self) -> None:
        policies = load_canonicalization_policies()
        args = "-m 1 -n 33 -k 34"
        self.assertEqual(
            "-m 16 -n 48 -k 64",
            canonicalize_args(
                app="sgemm_tcu",
                args=args,
                fpga_bin_label="C4",
                policies=policies,
            ).measurement_args,
        )
        self.assertEqual(
            "-m 8 -n 64 -k 64",
            canonicalize_args(
                app="fpint_gemm_ffn_hw",
                args=args,
                fpga_bin_label="other",
                policies=policies,
            ).measurement_args,
        )
        unknown_app = canonicalize_args(
            app="other",
            args=args,
            fpga_bin_label="other",
            policies=policies,
        )
        self.assertEqual(args, unknown_app.measurement_args)
        self.assertEqual({}, unknown_app.latency_shape)

    def test_sgemm_padded_args_match_physical_measurement_args(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "suite.yaml"
            path.write_text(
                """
name: sgemm_physical_shape
defaults:
  fpga_bin: C1
cases:
  - id: qk
    app: sgemm_tcu
    args: "-m 1 -n 17 -k 17"
    padded_args: "-m 1 -n 32 -k 17"
""".lstrip()
            )
            case = load_suite(path, repo_root=Path.cwd()).cases[0]
            self.assertEqual("-m 16 -n 32 -k 32", case.measurement_args)
            self.assertEqual(case.measurement_args, case.padded_args)

    def test_default_policy_preserves_actual_fpga_bin_label(self) -> None:
        result = canonicalize_args(
            app="fpint_gemm_ffn_hw_naive",
            args="-m 1 -n 33 -k 34 -q 32 -t 0 -d 0",
            fpga_bin_label="C3_v2",
            policies=load_canonicalization_policies(),
        )
        self.assertEqual(
            "-m 8 -n 64 -k 64 -q 32 -t 0 -d 0",
            result.measurement_args,
        )
        self.assertEqual("C3_v2", result.latency_shape["fpga_bin_label"])
        self.assertEqual("aligned", result.latency_shape["mode"])

    def test_vector_policies_distinguish_padded_and_valid_work(self) -> None:
        policies = load_canonicalization_policies()
        tiled = canonicalize_args(
            app="tile_input_a",
            args="-m 1 -k 33 --layout-to gemm_a_tiled",
            fpga_bin_label="C4",
            policies=policies,
        )
        self.assertEqual(
            "-m 8 -k 64 --layout-to gemm_a_tiled",
            tiled.measurement_args,
        )
        exact = canonicalize_args(
            app="softmax",
            args="-batch 1 -heads 32 -seqq 1 -seqk 33 -seqk-stride 64 -mask 0",
            fpga_bin_label="C4",
            policies=policies,
        )
        self.assertEqual(
            "-batch 1 -heads 32 -seqq 1 -seqk 33 -seqk-stride 64 -mask 0",
            exact.measurement_args,
        )
        self.assertEqual("exact", exact.latency_shape["mode"])

    def test_logical_cases_share_exec_key_by_measurement_args(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "suite.yaml"
            path.write_text(
                """
name: canonical
defaults:
  warmup: 1
  iterations: 2
  fpga_bin: C4
cases:
  - id: k33
    app: fpint_gemm_ffn_hw
    args: "-m 1 -n 128 -k 33 -q 32 -t 0 -d 0"
  - id: k34
    app: fpint_gemm_ffn_hw
    args: "-m 1 -n 128 -k 34 -q 32 -t 0 -d 0"
""".lstrip()
            )
            suite = load_suite(path, repo_root=Path.cwd())
            first, second = suite.cases
            self.assertNotEqual(first.args, second.args)
            self.assertEqual(first.measurement_args, second.measurement_args)
            self.assertEqual(first.exec_key, second.exec_key)
            self.assertEqual(
                "-m 8 -n 128 -k 64 -q 32 -t 0 -d 0",
                first.measurement_args,
            )


if __name__ == "__main__":
    unittest.main()
