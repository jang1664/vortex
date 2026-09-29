# QROW reference mismatch diagnosis

Current disposition: the user subsequently requested correcting the host
reference and rerunning tests. The temporary deferral below is historical.
Both hardware host apps now explicitly round QROW activation times scale to
FP16 RNE before weight and zero-point reduction. QCOL and the 1% tolerance
remain unchanged. See `verification/results.md` for rerun evidence.

## Observation

The improve kernel with M16/K256/N256/q32/t0/d1/r1 reports 30/4096
numerical mismatches with both SLR OFF and ON and no RTL assertion failure.
The printed mismatches are `0x2500` (0.01953125) versus reference `0x2519`
(0.0199127197265625). Both t0/d1 and t1/d1 reproduce on immutable baseline
commit `73664e653`. All six baseline/current OFF/ON logs have identical ten
emitted mismatch lines (SHA-256
`224a63f273e4bbf2854fbf717a6dee7f029a44353b4e58188c9512c7018bb037`).
Do not treat these cases as PASS. On 2026-09-29 the user explicitly deferred
the preexisting QROW issue to a follow-up task and requested completion of
the remaining SLR verification without changing arithmetic or tolerances.

Logs:
- `verification/results/final_improve_slr0/m16_t0_d1_r1.attempt1.app.log`
- `verification/results/final_improve_slr1/m16_t0_d1_r1.attempt1.app.log`

## Source evidence

Line numbers below refer to the working tree after MXU SLR transport and the
SLR-only external-PSUM reservation correction.

- `tests/regression/fpint_gemm_ffn_hw/main.cpp:47`: `FP16_TOL = 0.01f`.
- The same file at lines 227-259 creates FP16 activation/scale values from
  `1 + ((index) % 3)/100`, integer weights, and integer zero-points.
- The same file at lines 262-282 accumulates `a * (w - zp) * scale` in FP32,
  rounding only the final result to FP16. It does not first round `a * scale`
  to FP16 for QROW.
- The same file at lines 499-505 uses relative error for a nonzero reference;
  near-zero cancellation results receive no absolute-error allowance.
- `hw/rtl/core/gemm/VX_gemm_unit.sv:1136` selects the input scaler output for
  QROW. Lines 1184-1205 activate `VX_fp16_mul` on activation and scale; its
  result is FP16 before prealignment and integer reduction.
- `hw/rtl/core/gemm/VX_fp16_mul.sv:150` and `:310` select RNE rounding in
  the FPnew and DPI paths respectively.
- `hw/rtl/core/gemm/VX_gemm_unit.sv:1759` and `:1779` select the output
  scaler bypass for QROW, so there is no subsequent unrounded scale multiply
  that could recover those lost input-product bits.
- `git show 73664e653:hw/rtl/core/gemm/VX_gemm_unit.sv` shows the same
  input-selection expression at line 1068, FP16 input multiply at lines
  1122-1126, and QROW output bypass selection at line 1489. The arithmetic
  difference predates SLR transport.

## Arithmetic reconstruction

This read-only calculation recreates the deterministic input patterns and
inserts only the documented FP16 input-product rounding. It does not run RTL,
change the reference, or relax the acceptance threshold. Python binary64
arithmetic is exact for these short sums of small dyadic values, so the
reconstruction isolates the intermediate FP16 rounding difference.

```bash
python3 - <<'PYMODEL'
import struct
half = lambda x: struct.unpack('<e', struct.pack('<e', x))[0]
bits = lambda x: hex(struct.unpack('<H', struct.pack('<e', x))[0])
values = [half(1 + i / 100) for i in range(3)]
errors = []
for m in range(16):
    for n in range(256):
        reference = 0.0
        rounded_input = 0.0
        for k in range(256):
            a = values[(m + k) % 3]
            scale = values[(n // 32 + k) % 3]
            w_minus_zp = ((k * 256 + n) % 7 - 3) - ((n // 32 + k) % 7 - 3)
            reference += a * w_minus_zp * scale
            rounded_input += half(a * scale) * w_minus_zp
        reference = half(reference)
        rounded_input = half(rounded_input)
        relative = (abs((rounded_input - reference) / reference)
                    if reference else abs(rounded_input))
        if relative > 0.01:
            errors.append((m, n, bits(rounded_input), bits(reference), relative))
print('mismatches:', len(errors))
print('first ten:', errors[:10])
print('rows:', sorted({x[0] for x in errors}))
print('columns:', sorted({x[1] for x in errors}))
print('value pairs:', sorted({x[2:4] for x in errors}))
PYMODEL
```

Observed reconstruction output:
- Exactly 30 mismatches, matching the kernel reports.
- Rows: 0, 3, 6, 9, 12, 15; columns: 35, 42, 49, 56, 63.
- Every mismatch: actual-model `0x2500`, reference `0x2519`.
- Relative error: 0.019157088122605363 (1.9157%), above unchanged 1%.
- First ten coordinates and value pairs exactly match the printed kernel errors.

## Interpretation and boundary

The observed failures are fully explained by the preexisting QROW FP16
input-scaling precision versus FP32 host-reference arithmetic, amplified by
cancellation. They do not identify an SLR data-order or latency regression.
The immutable baseline simulation independently confirms the same failure.

This analysis cannot choose the desired numerical contract automatically:
requiring the ideal FP32 reference, modeling each hardware rounding stage,
or explicitly budgeting intermediate-rounding error are different product
requirements. Keep these cases reported as failures, preserve the original
threshold, and handle any arithmetic/reference policy change in a separately
agreed task. No RTL or test thresholds were modified during this diagnosis.
