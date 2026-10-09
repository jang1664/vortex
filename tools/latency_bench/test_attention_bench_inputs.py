"""Host checks for the actual reorder kernels and finite TCU benchmark inputs."""
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


class AttentionBenchInputsTest(unittest.TestCase):
    def compile_and_run(self, root, source, name, extra=()):
        (root / "VX_config.h").write_text("#define ISA_EXT_TCU 0\n")
        path = root / f"{name}.cpp"
        path.write_text(source)
        binary = root / name
        command = [
            "/usr/bin/g++", "-std=c++17", "-O2", "-ffunction-sections",
            "-fdata-sections", "-Wl,--gc-sections", "-DNUM_THREADS=16",
            "-I" + str(root), "-I" + str(REPO / "runtime/include"),
            "-I" + str(REPO / "sim/common"), "-I" + str(REPO / "tests/common"),
            "-I" + str(REPO / "third_party/softfloat/source/include"),
            str(path), *map(str, extra), "-o", str(binary),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_reorder_and_transpose_match_reference_for_both_kernel_variants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "vx_spawn.h").write_text("""#pragma once
#include <stdint.h>
#define __UNIFORM__
struct Dim { uint32_t x = 1; };
inline Dim gridDim, blockDim, blockIdx, threadIdx;
using vx_kernel_func_cb = void (*)(void*);
inline int vx_spawn_threads(int, uint32_t*, uint32_t*, vx_kernel_func_cb, void*) { return 0; }
""")
            (root / "vx_intrinsics.h").write_text("""#pragma once
#define VX_CSR_MSCRATCH 0
inline unsigned long csr_read(int) { return 0; }
""")
            app = REPO / "tests/regression/head_concat"
            for variant in ("baseline", "chunk16_packed"):
                source = f'''#define main unused_host_main
#include "{app / 'main.cpp'}"
#undef main
#define main unused_kernel_main
#include "{app / f'kernel.{variant}.cpp'}"
#undef main
#include <cassert>
int main() {{
  for (uint32_t mode : {{0u, 1u, 2u}})
  for (uint32_t seq : {{1u, 3u, 17u}})
  for (uint32_t dim : {{5u, 16u, 33u, 128u}}) {{
    const uint32_t batch = 2, heads = 4, n = batch * seq * heads * dim;
    std::vector<uint16_t> input(n), expected(n), output(n, 0xffff);
    for (uint32_t i = 0; i < n; ++i) input[i] = uint16_t(i + 1);
    build_reference(input, expected, batch, seq, heads, dim, mode);
    kernel_arg_t arg = {{}};
    arg.kernel_id = mode; arg.batch = batch; arg.seq = seq;
    arg.heads = heads; arg.headdim = dim;
    arg.input_addr = reinterpret_cast<uintptr_t>(input.data());
    arg.output_addr = reinterpret_cast<uintptr_t>(output.data());
    gridDim.x = 3; blockDim.x = 16;
    for (blockIdx.x = 0; blockIdx.x < gridDim.x; ++blockIdx.x)
      for (threadIdx.x = 0; threadIdx.x < blockDim.x; ++threadIdx.x)
        kernel_dispatcher(&arg);
    assert(output == expected);
  }}
}}
'''
                with self.subTest(variant=variant):
                    self.compile_and_run(root, source, variant)

    def test_tcu_fp16_inputs_are_bounded_finite_and_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = REPO / "tests/regression/sgemm_tcu/bench_main.cpp"
            source = f'''#define main unused_bench_main
#include "{app}"
#undef main
#include <cassert>
int main() {{
  std::srand(50);
  std::vector<uint16_t> samples(32768);
  bool positive = false, negative = false;
  for (auto& bits : samples) {{
    bits = gen_value<vt::fp16>();
    const uint16_t magnitude = bits & 0x7fff;
    assert(magnitude <= 0x3400); // 0.25 in FP16
    assert(magnitude == 0 || magnitude >= 0x0400); // no subnormals
    positive |= bits > 0 && bits < 0x8000;
    negative |= bits > 0x8000;
  }}
  assert(positive && negative);
  std::srand(50);
  for (auto bits : samples) assert(bits == gen_value<vt::fp16>());
  // A QK dot product must exercise finite conversion, not NaN/Inf early return.
  float dot = 0;
  for (size_t i = 0; i < 128; ++i)
    dot += bit_cast<float>(rv_htof_s(samples[i], 0, nullptr))
         * bit_cast<float>(rv_htof_s(samples[i + 128], 0, nullptr));
  assert(std::isfinite(dot));
  assert((rv_ftoh_s(bit_cast<uint32_t>(dot), 0, nullptr) & 0x7c00) != 0x7c00);
}}
'''
            self.compile_and_run(root, source, "tcu_input", (
                REPO / "sim/common/rvfloats.cpp", REPO / "sim/common/softfloat_ext.cpp",
                REPO / "third_party/softfloat/build/Linux-x86_64-GCC/softfloat.a",
            ))


if __name__ == "__main__":
    unittest.main()
