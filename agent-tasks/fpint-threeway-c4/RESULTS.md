# C4 RTL / SV reference / Python FPINT comparison

Implemented and executed on 2026-10-21. Numerical discrepancies are reported;
no RTL, SV reference arithmetic, or Python emulator arithmetic was changed.

## Configuration and coverage

- Candidate: C4 in `analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml`.
- Alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm`.
- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`.
- DUT: current `VX_gemm_unit_v2`, the unit used by the improve backend.
- VCS W-2024.09-SP1; existing unittest FPNEW arithmetic; system gcc/g++.
- Actual elaboration: MXU 16x16, QBLOCK=16, main extra bits=19,
  block size=1, selected signed width=12, FP32 QCOL output scaling.
- Both QCOL/QROW, M=2, N=16, K=16/32/64/512 (1/2/4/32 tiles),
  initial psum 0/+0.25, 12 directed patterns and 3 random seeds.
- NaN/Inf/overflow workloads excluded. Zeros, signed zeros, underflow,
  subnormals, negative scales, maximum-finite values, cancellation, INT4
  extremes, and zero-point corrections included.
- The SV reference computes full K independently. It does not consume DUT
  partial sums. Python retains its original arithmetic and reduce precision.
  Only dimensional/main-extra-bit settings are aligned with C4.

This is current-source RTL simulation under the C4 configuration, not a
measurement of the historical FPGA image. FPGA vendor arithmetic IP is not
simulated by the existing FPNEW unittest flow.

## Results

Final run: `build_fpint_threeway_results/c4/`.

| Comparison | QCOL failures / 3,840 outputs | QROW failures / 3,840 outputs | Total failures / 7,680 outputs |
|---|---:|---:|---:|
| RTL vs Python, exact FP16 bits | 436 | 352 | 788 |
| RTL vs SV reference, existing tolerance | 76 | 169 | 245 |
| Python vs SV reference, existing tolerance | 236 | 361 | 597 |

All 240 cases executed. 183 cases passed all three criteria; 57 had at least
one discrepancy. No nonfinite output was produced. All 78,720 intermediate
FP32 writeback coordinates were checked for completeness/uniqueness, and
the final FP32 writebacks agreed with the output records. Every RTL final
FP16 result matched round-to-nearest-even conversion of its recorded FP32 psum.

The intended exit status is **1 (numerical mismatch)**. This is not a build,
timeout, transport, missing-output, or scoreboard failure.

Other validation:

- Exact arithmetic smoke: 8 cases / 256 outputs, all comparisons passed.
- Existing v2 unit regression: `VX_gemm_unit_v2 unittest PASSED`, using the
  same C4 configuration and numerical-test binary without `+FPINT_COMPARE`.
  Log: `build_fpint_threeway_results/final/existing_v2_console.log`.
- Six host-side verdict/integrity tests passed. They cover bit mismatch,
  reference-only failure, zero tolerance, signed-zero bit distinction,
  nonfinite rejection, missing/duplicate outputs, and missing tile traces.

## Findings with reproductions

### 1. Python's reduce precision does not match RTL

Python uses main extra=19 but reduce extra=10 for both directions. The RTL
reconstructs its correction from the selected prealigned input and its block
index, without Python's separate 10-extra-bit truncation.

Cases 128 (QCOL) and 136 (QROW), coordinate [0,0], K=16, initial psum=0:

| RTL | SV reference | Python |
|---|---|---|
| `0x0000` = 0 | `0x0000` = 0 | `0x1c00` = 0.00390625 |

The inputs in each tile are `[65504, -65504, 2^-6, 0, ...]`, with weight=1,
zero-point=1, scale=0.25. Because weight equals zero-point, the mathematical
answer is exactly zero. Python retains the tiny input in the main dot but
loses it in its lower-precision reduction, leaving a nonzero residual.

This pattern accounts for 512 exact-bit mismatches. Another 4 appear in the
QCOL wide-exponent case 64. In diagnostic-only recomputation, temporarily
setting both reduce extras to 19 in an isolated Python module made cases
64/128/136 match RTL (4/32/32 mismatches became zero). The source and final
test results retain extra=10; this diagnostic was not used to make tests pass.

Relevant code: `fpint_emul.py:689`, `fpint_emul.py:728`,
`fpint_emul.py:1068`, `fpint_emul.py:1094`, and
`VX_gemm_compute_core.sv:1573` / `VX_gemm_compute_core.sv:1630`.

### 2. Python QROW accumulates in FP64, RTL in FP32

Case 156, QROW, coordinate [0,0], K=64, initial psum=0:

| RTL | SV reference | Python |
|---|---|---|
| `0x0000` = 0 | `0x0000` = 0 | `0x0100` = 2^-16 |

The exact tile contributions are `512, 2^-16, -512, 0`. FP32 accumulation
loses the middle term; Python's ordinary `float` accumulation retains it.
Case 155 also demonstrates the effect on an FP16 halfway rounding decision:
with initial psum=0.25 and K=32, RTL is `0x6000` (512), Python is `0x6001`
(512.5). This pattern accounts for 96 exact-bit mismatches.

Relevant code: `fpint_emul.py:1099` through its `acc_fp +=` at line 1115.

### 3. RTL QCOL scale widening mishandles zero/subnormal scales

The FP16-to-FP32 scale construction in `VX_gemm_compute_core.sv:2224`
adds the exponent-bias difference even when the FP16 exponent is zero.
It neither preserves zero nor normalizes a subnormal significand. In
particular, FP16 +0 is supplied to the FP32 multiplier as 2^-15.

Case 224, QCOL, K=16, initial psum=0, unit inputs/weights and zero-point=0:

| Output coordinate / scale | RTL | SV reference | Python |
|---|---|---|---|
| [0,0], scale=0 | `0x1000` = 2^-11 | `0x0000` = 0 | `0x0000` = 0 |
| [0,2], scale=2^-24 | `0x1001` | `0x0000` | `0x0010` = 2^-20 |

For the first row the correct output is zero. For the second it is 16*2^-24,
and the SV conversion also fails (see finding 4). The `tiny_scale` pattern
accounts for 160 exact-bit mismatches. A separate small-input scale-boundary
pattern produces 16 signed-zero mismatches after the spurious RTL FP32
value underflows to FP16. These are caught by strict bit comparison even
when the ULP distance is zero.

### 4. The existing SV reference is not reliable for FP16 subnormal outputs

`cf_math_util_pkg.sv:93` clamps the converted exponent and copies mantissa
bits `[22:13]`. It does not perform IEEE RNE or shift the significand into
the FP16 subnormal range. This helper is used by the unchanged reference.

Case 32, QCOL, [0,10], K=16:

| RTL | SV reference | Python |
|---|---|---|
| `0x80f6` | `0x83ae` | `0x80f6` |

An independent diagnostic FP64 evaluation of the saved operands rounds to
`0x80f6`. The SV mismatch is therefore not evidence of a DUT failure.
Case 224 [0,2] above is another simple example: exact 2^-20 becomes zero in
the reference helper.

### 5. Some reference-tolerance failures are expected operation-order differences

QROW multiplies input by scale and rounds to FP16 before prealignment.
The SV reference evaluates the dequantized mathematical expression in FP32
without that FP16 rounding point. Under cancellation, a small absolute
rounding error can exceed the requested 1% relative threshold.

For example, case 88 (QROW), [0,0], K=16: RTL and Python both return `0x1500`
(0.001220703125); SV returns `0x16a4` (0.001621246337890625). Diagnostic FP64
evaluation rounds to the SV value here. This is a real accuracy difference
from the reference, but does not imply that RTL and Python disagree.

The accepted absolute tolerance of 0.01 when reference=0 also allows some
large-ULP errors near zero. It is preserved exactly as requested, with
strict RTL/Python comparison and reported ULP errors providing additional
visibility. No tolerance was relaxed to obtain a pass.

## Reproduction and artifacts

See `hw/unittest/gemm_unit_v2/FPINT_COMPARE.md` for the harness interface.
The current runner requires explicit `legacy` selection to reproduce this run.

```bash
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version legacy \
  --output build_fpint_threeway_results/new_run

# Reproduce the three primary discrepancy classes:
python3 hw/unittest/gemm_unit_v2/compare_fpint.py run \
  --version legacy \
  --patterns zero_correction_gap accumulation_cancellation tiny_scale \
  --tiles 1 2 4 32 --seeds 20261021 \
  --output build_fpint_threeway_results/reproduce

# Re-evaluate saved data without recompiling or rerunning simulation:
python3 hw/unittest/gemm_unit_v2/compare_fpint.py check \
  --version legacy \
  build_fpint_threeway_results/c4
```

`summary.json` contains all per-case counts. `comparison.csv` and
`mismatches.json` contain all three bit patterns, values, coordinates, ULP
and absolute errors. `vectors/`, `stimulus.hex`, `cases.json`, and
`metadata.json` preserve inputs, seeds, mapped configuration, commands, and
the unchanged Python model hash. `rtl_psums.csv` preserves every tile's
FP32 writeback, including initial-psum setup (tile=-1).

No discrepancy fixes were applied, per the requested report-only scope.
