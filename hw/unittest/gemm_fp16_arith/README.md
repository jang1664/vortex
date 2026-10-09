# GEMM FP16 arithmetic regression

`VX_fp16_arith.vh` provides module-local synthesizable widening, RNE narrowing,
and exact FP16 multiplication helpers. `VX_f32_to_f16` uses the narrowing helper
for both combinational and registered output. The Xilinx branch of
`VX_fp16_mul` retains the native IP and corrects subnormal operands/results
using a transaction-aligned side queue. The DPI branch uses the same conversion
helpers. TCU RTL is outside this change.

The VCS unittest uses the actual Xilinx FP16 multiplier IP, not a behavioral
replacement. SoftFloat supplies independent expected values. NaN payloads are
not compared; a NaN result must still be a NaN.

Coverage:

- Every FP16 bit pattern multiplied by 1 and 0.5, plus 20,000 deterministic
  random pairs: 151,072 comparisons per IP latency (1, 2, and 7).
- Continuous one-result-per-cycle throughput, independently delayed operands,
  output backpressure, output stability while stalled, and result ordering.
- 173,728 FP32-to-FP16 inputs: every half value widened to FP32, positive and
  negative subnormal rounding boundaries, and random FP32 bit patterns.
  Both `OUT_REG=0` and `OUT_REG=1` data/valid interfaces are checked.

Run from an isolated configured build:

```bash
mkdir -p build_gemm_fp16_check
cd build_gemm_fp16_check
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
cd hw/unittest/gemm_fp16_arith
make compile
make run
```

The two GEMM host apps accept `--subnormal`. This opt-in fixture exercises
subnormal A, subnormal scale, normal products that underflow, signed results,
and sparse/dense output columns. It requires **bit-exact** output comparison;
the default vectors and verification tolerance are unchanged. Example from the
configured build root, after sourcing the appropriate config:

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args '-m 4 -k 128 -n 32 -q 32 -d 1 --subnormal'
```

## Validation on 2026-10-09

All unittest checks above passed. Blackbox runs used TH16/MXU16 and separate
build directories:

- C3: `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh`,
  app `fpint_gemm_ffn_hw_naive`, build `build_gemm_fp16_fix_c3_20261009`.
- C4: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`,
  app `fpint_gemm_ffn_hw`, build `build_gemm_fp16_fix_c4_20261009`.

| Inputs | M / K / N | QBLK | Direction | C3 | C4 | Log in each build |
|---|---|---|---|---|---|---|
| Subnormal | 4 / 128 / 32 | 32 | QROW | PASS, bit-exact | PASS, bit-exact | `subnormal_qrow.log` |
| Default | 4 / 256 / 32 | 32 | QROW | PASS | PASS | `qrow.log` |
| Default | 4 / 256 / 32 | 32 | QCOL | PASS | PASS | `qcol.log` |
| Subnormal | 4 / 256 / 32 | 32 | QCOL | PASS, bit-exact | PASS, bit-exact | `subnormal_qcol.log` |

The unit log is under the C4 build at
`hw/unittest/gemm_fp16_arith/unit_run.log`. These checks validate GEMM arithmetic
and integration, not whole-decoder functionality. FPGA timing/resource cost
has not been measured: the multiplier correction adds an 11x11 significand
product, normalization/rounding logic, input matching, and correction storage.
