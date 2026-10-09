"""Numeric regressions for quant reference precision and zero groups (TH16)."""
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


class QuantReferenceTests(unittest.TestCase):
    def test_padded_append_source_pitch_and_head_offset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VX_config.h").write_text("")
            header = REPO / "tests/regression/kv_cache_quant_layout_fused_w4a16/host_common.h"
            source = root / "padded.cpp"
            source.write_text(f'''#include "{header}"
#include <cassert>
int main() {{
  const uint32_t width = 4 * 128;
  for (uint32_t rows : {{1u, 8u, 16u, 128u}}) {{
    for (uint32_t layout : {{SRC_LAYOUT_GEMM_A_TILED, SRC_LAYOUT_GEMM_C_TILED}}) {{
      std::vector<fp16_t> row(width), packed(rows * width);
      for (uint32_t i = 0; i < width; ++i) row[i] = float_to_fp16(float(i % 17) - 8);
      pack_src_for_layout(row, packed, 1, width, layout, 128, rows);
      kernel_arg_t arg{{}}; arg.src_total_K = rows;
      std::vector<bool> visited(packed.size(), false);
      for (uint32_t head = 0; head < 4; ++head) {{
        arg.src_col_offset = head * 128;
        for (uint32_t n = 0; n < 128; ++n) {{
          uint32_t index = kv_fused_padded_append_offset(&arg, n);
          assert(index < packed.size());
          assert(!visited[index]); visited[index] = true;
          assert(packed[index] == row[head * 128 + n]);
        }}
      }}
      for (uint32_t i = 0; i < packed.size(); ++i)
        if (!visited[i]) assert(packed[i] == 0x7e00);
    }}
  }}
}}
''')
            binary = root / "padded"
            command = ["/usr/bin/g++", "-std=c++17", "-O2", "-I" + directory,
                       "-DMXU_ROW=16", "-DMXU_COL=16", "-DNUM_THREADS=16",
                       str(source), "-o", str(binary)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(0, result.returncode, result.stderr)

    def test_fp16_fp32_rounding_and_zero_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "VX_config.h").write_text("")
            source = root / "reference.cpp"
            host = REPO / "tests/regression/kv_cache_quant_layout_fused_w4a16/main.cpp"
            source.write_text(f'''#define main unused_quant_host_main
#include "{host}"
#undef main
#include <cassert>
int main() {{
  std::vector<fp16_t> src(128);
  init_src(src);
  // n=74 straddles a half-even rounding boundary only in FP16 arithmetic.
  assert(quant_cpu(src, 1, 128, 128, 1,
                  KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC, 0, 74)
         == (reference_fp32 ? 2 : 3));
  assert(round_half_even_cpu(-2.5f) == -2);
  assert(round_half_even_cpu(2.5f) == 2);
  assert(round_half_even_cpu(3.5f) == 4);
  assert(kv_spinquant_ratio_fp16((_Float16)0, (_Float16)0) == 0);
  assert(kv_spinquant_ratio_fp16((_Float16)1, (_Float16)2) == (_Float16)0.5f);
  std::vector<fp16_t> zeros(33 * 64, 0);
  assert(quant_cpu(zeros, 33, 64, 32, 0,
                  KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC, 32, 3) == 0);
  assert(quant_cpu(zeros, 33, 64, 32, 0,
                  KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC, 32, 3) == 8);
  assert(quant_cpu(zeros, 33, 64, 32, 0,
                  KV_QUANT_LEGACY_UINT4_ASYMMETRIC, 32, 3) == 0);
}}
''')
            for tag in (9, 12, 13):
                binary = root / f"reference_{tag}"
                command = ["/usr/bin/g++", "-std=c++17", "-O2",
                           "-ffunction-sections", "-fdata-sections", "-Wl,--gc-sections",
                           "-I" + directory, "-I" + str(REPO / "runtime/include"),
                           "-DMXU_ROW=16", "-DMXU_COL=16", "-DNUM_THREADS=16",
                           f"-DKV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG={tag}",
                           str(source), "-o", str(binary)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertEqual(0, result.returncode, result.stderr)
                result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
                self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
