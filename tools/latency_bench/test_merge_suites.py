from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from tools.latency_bench.merge_suites import MergeSuitesOptions, merge_suites
from tools.latency_bench.suite import load_suite


class MergeSuitesTest(unittest.TestCase):
    def _write_suite(
        self,
        path: Path,
        *,
        name: str,
        fpga_bin: str,
        app: str,
        cases: list[dict[str, object]],
    ) -> None:
        path.write_text(
            yaml.safe_dump(
                {
                    "name": name,
                    "defaults": {
                        "warmup": 1,
                        "iterations": 2,
                        "app": app,
                        "fpga_bin": fpga_bin,
                        "blackbox_args": ["--cores=1", "--threads=8"],
                    },
                    "cases": cases,
                },
                sort_keys=False,
            )
        )

    def test_merges_single_fpga_suite_and_dedupes_identical_executions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            self._write_suite(
                tmp_path / "a.yaml",
                name="a",
                fpga_bin="naive_simd",
                app="sgemm_tcu",
                cases=[
                    {
                        "id": "q_proj_a",
                        "app": "sgemm_tcu",
                        "kind": "gemm",
                        "backend": "sgemm_tcu",
                        "args": "-m 1 -n 128 -k 128",
                    },
                    {
                        "id": "pv_a",
                        "app": "sgemm_tcu",
                        "kind": "gemm",
                        "backend": "sgemm_tcu",
                        "args": "-m 1 -n 64 -k 128",
                    },
                ],
            )
            self._write_suite(
                tmp_path / "b.yaml",
                name="b",
                fpga_bin="naive_simd",
                app="sgemm_tcu",
                cases=[
                    {
                        "id": "q_proj_duplicate",
                        "app": "sgemm_tcu",
                        "kind": "gemm",
                        "backend": "sgemm_tcu",
                        "args": "-m 1 -n 128 -k 128",
                    },
                    {
                        "id": "lm_head",
                        "app": "sgemm_tcu",
                        "kind": "gemm",
                        "backend": "sgemm_tcu",
                        "args": "-m 1 -n 32000 -k 4096",
                    },
                ],
            )
            (tmp_path / "index.yaml").write_text("generated: []\n")
            out = tmp_path / "merged.yaml"

            result = merge_suites(
                MergeSuitesOptions(
                    suite_globs=(str(tmp_path / "*.yaml"),),
                    out=out,
                    name="merged_naive_simd",
                    repo_root=Path.cwd(),
                )
            )

            self.assertEqual(out, result["suite"])
            self.assertEqual(3, result["case_count"])
            self.assertEqual(1, result["dropped_duplicate_count"])

            merged = load_suite(out, repo_root=Path.cwd())
            self.assertEqual("merged_naive_simd", merged.name)
            self.assertEqual("naive_simd", merged.defaults.fpga_bin)
            self.assertEqual(3, len(merged.cases))
            self.assertEqual(
                [
                    "-m 1 -n 128 -k 128",
                    "-m 1 -n 64 -k 128",
                    "-m 1 -n 32000 -k 4096",
                ],
                [case.args for case in merged.cases],
            )

    def test_single_output_rejects_multiple_fpga_bins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            self._write_suite(
                tmp_path / "a.yaml",
                name="a",
                fpga_bin="naive_simd",
                app="sgemm_tcu",
                cases=[{"id": "a", "app": "sgemm_tcu", "args": "-m 1 -n 128 -k 128"}],
            )
            self._write_suite(
                tmp_path / "b.yaml",
                name="b",
                fpga_bin="improve_tcol32",
                app="fpint_gemm_ffn_hw",
                cases=[{"id": "b", "app": "fpint_gemm_ffn_hw", "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"}],
            )

            with self.assertRaisesRegex(ValueError, "--group-by-fpga-bin"):
                merge_suites(
                    MergeSuitesOptions(
                        suite_globs=(str(tmp_path / "*.yaml"),),
                        out=tmp_path / "merged.yaml",
                        repo_root=Path.cwd(),
                    )
                )

    def test_group_by_fpga_bin_writes_one_suite_per_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            self._write_suite(
                tmp_path / "naive_a.yaml",
                name="naive_a",
                fpga_bin="naive_simd",
                app="sgemm_tcu",
                cases=[{"id": "same_id", "app": "sgemm_tcu", "args": "-m 1 -n 128 -k 128"}],
            )
            self._write_suite(
                tmp_path / "naive_b.yaml",
                name="naive_b",
                fpga_bin="naive_simd",
                app="sgemm_tcu",
                cases=[{"id": "same_id", "app": "sgemm_tcu", "args": "-m 2 -n 128 -k 128"}],
            )
            self._write_suite(
                tmp_path / "improve.yaml",
                name="improve",
                fpga_bin="improve_tcol32",
                app="fpint_gemm_ffn_hw",
                cases=[{"id": "gemm", "app": "fpint_gemm_ffn_hw", "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0"}],
            )
            out_dir = tmp_path / "merged"

            result = merge_suites(
                MergeSuitesOptions(
                    suite_globs=(str(tmp_path / "*.yaml"),),
                    out=out_dir,
                    name="merged",
                    group_by_fpga_bin=True,
                    repo_root=Path.cwd(),
                )
            )

            self.assertEqual(out_dir / "index.yaml", result["index"])
            index = yaml.safe_load((out_dir / "index.yaml").read_text())
            entries = {entry["fpga_bin"]: entry for entry in index["generated"]}
            self.assertEqual({"naive_simd", "improve_tcol32"}, set(entries))
            self.assertEqual(2, entries["naive_simd"]["case_count"])
            self.assertEqual(1, entries["improve_tcol32"]["case_count"])

            naive_suite = load_suite(Path(entries["naive_simd"]["suite"]), repo_root=Path.cwd())
            self.assertEqual("naive_simd", naive_suite.defaults.fpga_bin)
            self.assertEqual(2, len(naive_suite.cases))
            self.assertNotEqual(naive_suite.cases[0].case_id, naive_suite.cases[1].case_id)

            improve_suite = load_suite(Path(entries["improve_tcol32"]["suite"]), repo_root=Path.cwd())
            self.assertEqual("improve_tcol32", improve_suite.defaults.fpga_bin)
            self.assertEqual(1, len(improve_suite.cases))


if __name__ == "__main__":
    unittest.main()
