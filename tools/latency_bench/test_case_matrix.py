from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.suite import load_suite


class CaseMatrixTest(unittest.TestCase):
    def test_expands_pow2_matrix_into_cases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: gemm_sweep
defaults:
  warmup: 1
  iterations: 2
  app: fpint_gemm_ffn_hw
case_matrices:
  - id: gemm
    kind: gemm
    backend: fpint_gemm
    stage: sweep
    name: gemm_m{m}_n{n}_k{k}
    args: "-m {m} -n {n} -k {k} -q {qblk} -t {wtrans} -d {qdir}"
    matrix:
      m: {pow2: [1, 4]}
      n: {values: [128, 256]}
      k: 128
      qblk: 32
      wtrans: 0
      qdir: 0
    shape:
      M: "{m}"
      N: "{n}"
      K: "{k}"
      QBLK: "{qblk}"
      WTRANS: "{wtrans}"
      QDIR: "{qdir}"
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())

            self.assertEqual(6, len(suite.cases))
            self.assertEqual("gemm_m1_n128_k128", suite.cases[0].case_id)
            self.assertEqual("-m 1 -n 128 -k 128 -q 32 -t 0 -d 0", suite.cases[0].args)
            self.assertEqual({"M": 1, "N": 128, "K": 128, "QBLK": 32, "WTRANS": 0, "QDIR": 0}, suite.cases[0].shape)
            self.assertEqual("gemm_m4_n256_k128", suite.cases[-1].case_id)

    def test_expands_derived_matrix_values(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: rope_generation
case_matrices:
  - id: rope_generation
    app: rope
    kind: rope
    stage: generation
    name: rope_b{batch}_kv{kv_len}
    args: "-batch {batch} -seq 1 -offset {offset}"
    matrix:
      batch: {values: [1, 8]}
      kv_len: {values: [128, 512]}
    derived:
      offset: "kv_len - 1"
      tokens: "batch * kv_len"
    shape:
      batch: "{batch}"
      kv_len: "{kv_len}"
      offset: "{offset}"
      tokens: "{tokens}"
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())

            self.assertEqual(4, len(suite.cases))
            self.assertEqual("rope_b1_kv128", suite.cases[0].case_id)
            self.assertEqual("-batch 1 -seq 1 -offset 127", suite.cases[0].args)
            self.assertEqual({"batch": 1, "kv_len": 128, "offset": 127, "tokens": 128}, suite.cases[0].shape)
            self.assertEqual("-batch 8 -seq 1 -offset 511", suite.cases[-1].args)
            self.assertEqual(4096, suite.cases[-1].shape["tokens"])


if __name__ == "__main__":
    unittest.main()
