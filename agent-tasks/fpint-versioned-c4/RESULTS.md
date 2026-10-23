# Versioned C4 arithmetic validation

## Implemented contract

Added `rtl-c4-v1` without changing compute RTL or legacy arithmetic entry points:

- SV: `hw/rtl/verification/fpint_emul_rtl_c4.sv`, `fpint_emul_rtl_c4::gemm`.
- Python: `hw/unittest/fpint_emul/py/fpint_versions.py`, `gemm(..., version=...)`.
- CUDA: `hw/unittest/fpint_emul/cuda/fpint_rtl_c4.cu`, with checked Python host
  adapter `fpint_cuda.CudaModel`. This executes on the GPU; no CPU fallback.
- Runner: `hw/unittest/gemm_unit_v2/compare_fpint.py`. Both run and check require
  `--version legacy` or `--version rtl-c4-v1`. Version is saved with each run.

The frozen version implements FP16 QROW input scaling, identical 19-bit alignment
for dot and zero correction, 16-bit stored zero negation, 40-bit integer merge,
FP32 conversion/scaling and per-tile accumulation, load bypass, and FP16 RNE output.
It deliberately preserves the current QCOL zero/subnormal scale rebias; it does
not silently repair that RTL behavior. The legacy Python prealign helper gained
an optional tile-size keyword; its default behavior is unchanged.

SV reuses existing prealignment and FP16 arithmetic helpers. Python uses NumPy;
CUDA uses native explicit RNE operations, with FMA and FTZ disabled. References
consume original inputs and specified initial psums, never DUT intermediate values.

## Final four-way result

Artifacts: `build_fpint_threeway_results/rtl_c4_v1_final/`.
Current source C4 `VX_gemm_unit_v2`, XLEN=64, 16x16, 19 extra bits,
BLOCK_SIZE=1, SEL_BLOCK_WIDTH=12, FP32 output scaling.
VCS W-2024.09-SP1 / unittest FPNEW arithmetic; CUDA 12.8, RTX 3090 (SM 8.6),
driver 570.211.01. Source hashes are saved and match the final model files.

| Coverage | Count |
| --- | ---: |
| Cases | 380 |
| Final FP16 outputs per implementation | 12,160 |
| FP32 tile writebacks per implementation | 114,304 |
| Additional RTL initialization writebacks checked against +0.25 | 6,080 |
| FP16 mismatches in each of the six model pairs | 0 |
| FP32 mismatches in each of the six model pairs | 0 |
| Nonfinite outputs | 0 |
| RTL final output vs independent FP32-to-FP16 RNE mismatches | 0 |

Every pair among RTL, SV, Python and CUDA is compared exactly, including signed
zero. QCOL and QROW each contribute 190 cases and 6,080 final outputs.
K=16,32,64,128,512; M=2, N=16; load and initial +0.25 modes.

Patterns cover exact arithmetic, signed zero, subnormal/normal boundaries,
signed and zero/subnormal scales, exponent gaps, cancellation, INT4 endpoints,
zero correction, differing dot/reduce precision, FP32 accumulation loss,
rounding, tiny scales, large signed zero points with bounded intermediates,
uniform finite FP16 input bit patterns, and random values. Random patterns use
seeds 20261021, 20261022, 20261023. NaN, Inf and overflow workloads are excluded;
underflow and subnormals remain in scope. This is sampled validation, not an
exhaustive proof over all finite inputs.

The initial default 240-case run also passed: 7,680 outputs and 74,880 tile sums
(`build_fpint_threeway_results/rtl_c4_v1_full/`). The final expanded run additionally
contains the explicit integer-width model and K=128/extended patterns.

## Reproduction

Use a new output directory:

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version rtl-c4-v1 --build build_fpint_versions_c4 \
  --output build_fpint_threeway_results/rtl_c4_v1_reproduce \
  --patterns exact signed_zero subnormal scale_boundaries exponent_gap \
    cancellation weight_extremes zero_correction zero_correction_gap \
    accumulation_cancellation rounding random tiny_scale zero_point_limits bit_random \
  --tiles 1 2 4 8 32

python3 hw/unittest/gemm_unit_v2/compare_fpint.py check \
  --version rtl-c4-v1 build_fpint_threeway_results/rtl_c4_v1_final
```

The runner sources the C4 alias config, configures the isolated build directory,
builds CUDA and VCS, generates shared inputs, and checks all outputs/writebacks.
It rejects incomplete coordinate sets and version mismatches.

## Other checks and limits

- Eleven host regression tests passed, including one-bit perturbations in each
  predicted output/trace, version mismatch and missing CUDA results, QCOL scale
  rebias, signed-zero load behavior, FP16 prescaling and FP32 tile accumulation.
- Existing `VX_gemm_unit_v2` normal unittest passed with the final package built
  in. Log: `rtl_c4_v1_final/existing_v2_console.log`.
- Explicit `legacy` rerun reproduced the original 240-case run byte-for-byte
  for `stimulus.hex`, `rtl_reference.csv` and `rtl_psums.csv`; all input and
  Python result arrays also matched exactly. Its expected numerical failures
  remain 788 RTL/Python bit mismatches, 245 RTL/SV tolerance failures and 597
  Python/SV tolerance failures. Exit 1 is expected for this compatibility check.
  Artifacts: `build_fpint_threeway_results/legacy_version_regression/`.
- No compute RTL changes, synthesis or FPGA execution. The simulation uses the
  unittest's FPNEW arithmetic; FPGA vendor-IP behavior is not independently
  validated here. The CUDA implementation is for numerical validation, not speed.
- The first attempt's VCS compile failure (implicit ref DEBUG argument in the
  reused prealign helper) was resolved by passing an explicit bit variable.
