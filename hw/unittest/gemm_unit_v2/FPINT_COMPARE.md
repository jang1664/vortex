# Versioned C4 numerical comparison

`compare_fpint.py` requires an explicit arithmetic version for both `run` and
`check`. The compute RTL is unchanged. Models always consume original inputs;
they never use DUT outputs to construct their predictions.

| Version | SV reference | Python | CUDA | Verdict |
| --- | --- | --- | --- | --- |
| `legacy` | Existing `fpint_emul::fpint_gemm_ref` | Existing `fpint_gemm_{qcol,qrow}_real_2scomp` | Not applicable | Original three-way rules below |
| `rtl-c4-v1` | `fpint_emul_rtl_c4::gemm` | `fpint_versions.gemm(..., version="rtl-c4-v1")` | `fpint_rtl_c4.cu`, actual GPU execution | All six pairs: exact FP16 output and FP32 tile-psum bits |
| `qrow-fp32-scale-v1` | Same package, explicit version argument | `fpint_versions.gemm(..., version="qrow-fp32-scale-v1")` | Not used | Exact RTL/SV/new Python/C4 Python comparison, plus scaling-only checks |

`rtl-c4-v1` freezes **current C4 behavior**, including its QCOL zero/subnormal
scale rebias. It is not an ideal-real-arithmetic reference. Future RTL numerical
changes should receive a new version instead of silently changing this contract.

## QROW FP32-prescaling variant

`qrow-fp32-scale-v1` changes only QROW input scaling:

```text
input_fp16 -> IEEE FP32 widening ---+
                                    FP32 multiply -> FP16 RNE -> C4 prealign/dot/accumulate
scale_fp16 -> IEEE FP32 widening ---+
```

Both source operands remain FP16. Widening preserves signed zero and subnormals.
QCOL and the remaining C4 pipeline are unchanged. No compute RTL or CUDA kernel
changes are needed for this variant. Run it without nvcc/GPU requirements:

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version qrow-fp32-scale-v1 \
  --build build_fpint_qrow_fp32_scale_c4 \
  --output build_fpint_threeway_results/qrow_fp32_scale_NEW
```

The SV `gemm` function accepts a final `input string version` argument, defaulting
to `rtl-c4-v1` for existing callers. Its `qrow_input_scale(a, scale, version)`
helper and Python's `qrow_input_scale(a, scale, version=...)` expose the scaling
operation independently. Python GEMM still requires explicit `version`.

Finite FP16 operands have at most 11 significant bits each. Their exact product
needs at most 22 bits, fits FP32's 24-bit precision, and lies within its normal
exponent range (apart from exact zero). Consequently, FP32 multiplication then
FP16 RNE gives the same result as correctly rounded FP16 multiplication. This
version does not retain FP32 values past the input-scaling stage.

In addition to GEMM comparisons, the runner crosses all 63,488 finite FP16 bit
patterns with 18 signed boundary scales. It excludes 69,636 FP16-overflow pairs
and checks 1,073,148 remaining pairs in Python and VCS, including both versions
and signed-zero bits. Extra artifacts are `scaling_vectors.hex`,
`scaling_python.json`, and `scaling_sv.json`. GEMM vectors store the existing
C4 Python baseline in `python_c4_bits`/`python_c4_psums`; no CUDA result is
generated or relabeled as this new version.

C4 is resolved through `analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml`
and `ci/fpga_bin_alias_map.yaml`. Its improve backend uses `VX_gemm_unit_v2`,
with MXU 16x16 and quantization blocks of 16 for this unit-level test.
This tests current source RTL under C4's configuration, not the historical
FPGA binary listed in the alias map.

## Run

From the source root, with VCS, NumPy/PyYAML, nvcc and a CUDA GPU available:

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version rtl-c4-v1 --output build_fpint_threeway_results/full
```

The runner sources the mapped configuration, configures an isolated
`build_fpint_threeway_c4` directory with XLEN=64, and builds/runs the existing
v2 unit testbench there. It uses system gcc/g++ and the existing unittest's
FPNEW simulation arithmetic. FPGA vendor-IP behavior is not covered.
The cvfpu `src/common_cells` submodule and the built SoftFloat library must
be available, as required by the existing v2 unittest.

Output directories must be new. The saved stimulus and results remain
available after numerical failure. Exit codes: 0 = all comparisons pass,
1 = numerical mismatch, 2 = execution/integrity error.

For a short run, or to reproduce a failing pattern/seed/K size:

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version rtl-c4-v1 \
  --patterns exact --tiles 1 2 --seeds 20261021 \
  --output build_fpint_threeway_results/exact
python3 hw/unittest/gemm_unit_v2/compare_fpint.py check \
  --version rtl-c4-v1 build_fpint_threeway_results/full

# Preserve the original SV/Python comparison (does not require CUDA):
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version legacy --output build_fpint_threeway_results/legacy
```

`--tiles` accepts 1, 2, 4, 8, 32 (K=16,32,64,128,512); default: 1,2,4,32. Both directions and both
initial-psum modes always run. The default has twelve directed patterns plus
three random seeds: 240 cases, each with M=2 and N=16 (7,680 output values).
Additional patterns `zero_point_limits` and `bit_random` exercise large signed
zero points without overflowing intermediates, and uniform finite FP16 input
bit patterns with signed small scales. `bit_random` runs every supplied seed.

## rtl-c4-v1 arithmetic and API

1. QROW multiplies each input by its row scale and rounds to FP16 RNE first.
   QCOL uses the original FP16 input.
2. Groups of 16 align to their maximum effective exponent (subnormal exponent
   treated as 1), retaining 19 extra bits. Magnitude shifts precede sign application.
3. Dot and zero correction use the **same** aligned integers. Zero-point negation
   has the RTL's 16-bit register width; the merged integer has its 40-bit width.
4. Convert the merged integer times `2**(max_exp - 44)` to FP32 RNE.
5. QCOL widens scale by sign/fraction placement and exponent `exp16 + 112`,
   including exponent zero, then multiplies in FP32 RNE. For example half `0x0000`
   becomes FP32 `0x38000000`, not zero. QROW has no post-dot scale.
6. A first load bypasses addition. Subsequent tiles add to the stored FP32 psum
   with RNE after **each tile**. An explicit initial psum participates in addition.
7. Final output narrows to FP16 RNE, including gradual underflow and signed zero.

Supported geometry: N=16, K a positive multiple of 16, BLOCK_SIZE=1,
SEL_BLOCK_WIDTH=12, EXTRA_BIT_WIDTH=19, INT4 weights, signed INT16 zero points,
FP32 QCOL output scaling. The runner checks C4 configuration and records the
selected version in metadata, cases and the SV-produced configuration.
NaN/Inf/overflow are outside the test domain; signed zero and subnormals are included.

Python API (put `hw/unittest/fpint_emul/py` on `PYTHONPATH`):

```python
from fpint_versions import gemm
output_bits, tile_psum_bits = gemm(
    a, w, s, z, qdir=0, version="rtl-c4-v1", initial_psum=None)
```

Inputs: `a` uint16[M,K] FP16 bits, `w` int8[K,16] with values -8..7,
`s` uint16 FP16 bits, `z` int16. QCOL parameter shape is [K/16,16]; QROW
shape is [K,1]. An optional initial psum is uint32[M,16] FP32 bits; `None`
means load and differs from an explicit +0 when the first tile is -0.
Outputs are uint16[M,16] and uint32[K/16,M,16].

`fpint_cuda.CudaModel(library, version="rtl-c4-v1").gemm(...)` has the same
array contract. The runner builds the shared library using nvcc with FMA and
FTZ disabled. The kernel uses explicit round-to-nearest CUDA arithmetic; errors
are fatal and there is no CPU fallback. It is a numerical emulator, not a tuned
GPU GEMM benchmark. The SV model reuses the existing `prealign` and RTL FP16
arithmetic helpers; Python and CUDA provide independently implemented floating
point operations. No model receives DUT psums.

## Legacy independence and precision

- The three paths consume identical FP16 input/scale bits, signed INT4
  weights, and signed zero points. Inputs, outputs, seeds, and configuration
  are saved. The SV loader explicitly sign-extends INT4 to the reference's
  wider weight field.
- The SV reference computes the entire K from the original inputs and a
  specified FP32 initial psum. It never receives intermediate DUT results.
  Its existing FP32 arithmetic and FP16 conversion helper are unchanged.
- The Python adapter sets only MXU_K=16, MXU_N=16, QBLOCK=16, and main
  EXTRA_BIT=19. Both reduce precisions remain at the model's original 10.
  QROW accumulation and all rounding points remain unchanged.
- Initial psum is either zero or exactly +0.25 in every output. For +0.25,
  an exact one-hot prefix tile initializes the RTL accumulator; its FP32
  writeback is checked against the specified value. Because Python has no
  initial-psum argument, the same exact tile is prepended to its inputs.
  The SV reference instead receives the specified +0.25 directly. The
  prefix is not counted in the requested K size.
- Each tile/row is drained before the next packet. This is a numerical
  test; existing unit tests retain responsibility for overlap/forwarding
  and throughput coverage.

## Stimulus and verdict

Directed cases cover exact arithmetic, +/-0, subnormal and minimum-normal
boundaries, zero/subnormal/negative/maximum-finite scales, maximum finite FP16 mixed with tiny values, cancellation,
signed INT4 endpoints, zero-point correction, and rounding-sensitive values.
Two directed tests specifically expose precision assumptions: `w == z` with
wide input exponent gaps (dot/reduce precision), and the tile sequence
`512, 2^-16, -512` (FP32 vs FP64 accumulation after cancellation).
The `tiny_scale` pattern uses unit inputs and zero/subnormal scales so that
incorrect scale widening remains visible in the final FP16 output.
Three reproducible random seeds supplement these cases. Conservative
magnitude bounds exclude NaN/Inf/overflow workloads while preserving
underflow and subnormal cases. Nonfinite results on accepted workloads are
reported as failures, not silently removed.

For `rtl-c4-v1`, every pair among RTL/SV/Python/CUDA must match all 16 output
bits and all 32 intermediate psum bits. There is no numerical tolerance, including
for signed zero. Final RTL narrowing is also checked independently with NumPy RNE.
The known initialization writebacks are checked separately against +0.25.

For `legacy`, the original rules remain unchanged:

1. RTL vs Python must match all 16 bits, including the sign of zero.
2. RTL vs SV reference must satisfy `abs(actual-ref) <= 0.01*abs(ref)`.
3. Python vs SV reference must satisfy the same rule.

When the reference is zero, the absolute tolerance is 0.01. ULP and absolute
errors are also recorded. ULP treats signed zeros as the same numerical point.
Missing/duplicate output coordinates and X/Z outputs are execution failures.
All numerical cases finish before a failing numerical verdict is returned.

## Artifacts

- `metadata.json`: version, C4 alias/config, commands, tool mode, model hashes,
  GPU/nvcc versions (when used) and status.
- `cases.json`, `vectors/*.npz`, `stimulus.hex`: reproducible original inputs
  and Python results; `rtl-c4-v1` also saves CUDA results and both FP32 traces.
- `rtl_config.json`: actual elaborated dimensions and precision parameters.
- `rtl_reference.csv`: RTL and SV reference FP16 bits plus final RTL FP32 psum.
- `rtl_psums.csv`: every tile/row FP32 writeback (tile -1 is initialization).
- `sv_psums.csv`: independent versioned SV tile psums; header only for legacy.
- `comparison.csv`: all selected models' output bits (legacy also includes errors).
- `summary.json`, `mismatches.json`: mismatch counts and failing coordinates;
  `rtl-c4-v1` reports all six pairs for both FP16 and FP32.
- `libfpint_cuda.so`, `cuda_build.log`: compiled CUDA implementation and build log.
- `build.log`, `simulation.log`, `simv.log`: complete compilation/simulation logs.

The numerical runner sets DEBUG_LEVEL=0 to keep logs compact; per-tile FP32
writebacks are always retained separately. Other v2 unittest runs retain
their existing DEBUG_LEVEL=3 default.

Host-side verdict regression tests:

```bash
python3 -m unittest discover -s hw/unittest/gemm_unit_v2 -p test_compare_fpint.py -v
```
