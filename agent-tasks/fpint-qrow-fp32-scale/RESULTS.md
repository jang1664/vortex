# QROW FP32-prescaling version

Added `qrow-fp32-scale-v1` to the SV reference and Python emulator. The new QROW
path is IEEE FP16-to-FP32 widening of both operands, FP32 multiplication, then
FP16 round-to-nearest-even. The rest of the C4 computation, including QCOL,
is shared with `rtl-c4-v1`. Compute RTL and the CUDA kernel/adapter are unchanged.

## Result

All tested outputs are identical to `rtl-c4-v1` and current C4 RTL:

| Check | Coverage | Mismatches |
| --- | ---: | ---: |
| Python old/new input scaling | 1,073,148 finite non-overflow operand pairs | 0 |
| SV old/new input scaling vs Python expected bits | Same 1,073,148 pairs for each version | 0 |
| GEMM final FP16 outputs | 380 cases, 12,160 outputs | 0 across all six pairings |
| GEMM FP32 tile psums | 114,304 values | 0 across all six pairings |
| RTL initialization psums | 6,080 values | All exactly +0.25 |
| Python old/new large QROW matrix | M=N=16, K=32768; outputs and all tile psums | 0 |

The four paths in GEMM comparisons are unchanged RTL, new SV, new Python, and
existing C4 Python. CUDA is neither extended nor executed for this version.
QCOL and QROW each have 190 cases; K=16,32,64,128,512, M=2,N=16, with load and
initial +0.25 modes. The existing directed and random patterns are retained.

The scaling test crosses every one of the 63,488 finite FP16 bit patterns with
18 scales: both signs of zero, minimum subnormal, largest subnormal, minimum
normal, 0.5, 1, nextafter(1,+infinity), 2, and maximum finite FP16. It excludes
69,636 FP16-overflow pairs. Signed zero and underflow/subnormals are included.
This is not an exhaustive enumeration of all finite input/scale pairs.

## Why the results agree

An FP16 operand has at most 11 significant binary digits. Its product with
another FP16 operand needs at most 22 significant digits, fitting exactly in
FP32's 24-bit precision. Nonzero finite products range from 2^-48 to below 2^32,
inside FP32's normal exponent range. Thus FP32 multiplication introduces no
rounding error before the final FP16 narrowing:

```text
RN16(RN32(FP32(input_fp16) * FP32(scale_fp16)))
    = RN16(exact(input_fp16 * scale_fp16))
```

The final FP16 RNE operation is the same as direct correctly rounded FP16
multiplication. Widening already-quantized FP16 operands and immediately
narrowing their product therefore does not improve the matrix error under this
contract. No new 100-seed FP64-error sweep was needed to establish the operation's
equivalence; this task runs SV/Python scaling and GEMM comparisons instead.

## Code and API

- `hw/unittest/fpint_emul/py/fpint_versions.py`: new version constant and
  `qrow_input_scale`; `gemm(..., version="qrow-fp32-scale-v1")` selects it.
- `hw/rtl/verification/fpint_emul_rtl_c4.sv`: versioned `qrow_input_scale` and
  an optional final input string argument to `gemm`. Its default remains
  `rtl-c4-v1` for existing callers.
- `hw/unittest/gemm_unit_v2/compare_fpint.py` and `fpint_compare.svh`: version
  dispatch, scaling vectors, and exact comparisons without a CUDA dependency.
- `hw/unittest/gemm_unit_v2/test_compare_fpint.py`: 14 passing tests, including
  the long matrix, boundary products, and detection of a scaling-result mismatch.

The current VCS/FPNEW unittest configuration is used; this is not an FPGA run.
The standard `VX_gemm_unit_v2` regression and saved-result replay also passed.
The final 380-case RTL/SV CSVs and stimulus are byte-identical to the earlier
`rtl_c4_v1_final` run. All corresponding input arrays, Python output bits and
Python psum bits are identical. Tested model hashes match metadata; CUDA source
and adapter hashes still match the earlier frozen C4 artifacts.

## Reproduction and artifacts

The completed run is in `build_fpint_threeway_results/qrow_fp32_scale_v1/`.
Key files: `summary.json`, `scaling_python.json`, `scaling_sv.json`,
`scaling_vectors.hex`, `rtl_reference.csv`, `rtl_psums.csv`, `sv_psums.csv`, and
`vectors/*.npz`. The NPZ files retain both `python_*` and `python_c4_*` results.

Use a new output directory to repeat the complete run:

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version qrow-fp32-scale-v1 --build build_fpint_qrow_fp32_scale_c4 \
  --output build_fpint_threeway_results/qrow_fp32_scale_NEW \
  --patterns exact signed_zero subnormal scale_boundaries exponent_gap \
    cancellation weight_extremes zero_correction zero_correction_gap \
    accumulation_cancellation rounding random tiny_scale zero_point_limits bit_random \
  --tiles 1 2 4 8 32
python3 hw/unittest/gemm_unit_v2/compare_fpint.py check \
  --version qrow-fp32-scale-v1 build_fpint_threeway_results/qrow_fp32_scale_v1
```
