# FPFP naive GEMM versus rev7 C4 FPINT improve

Status: complete. All six VCS runs passed (M=1,4,256 for each app).

These are historical FPFP ROW=16, COL=16, WLOAD=4 measurements. The editable
config now selects ROW=8, COL=16, WLOAD=1; its new measurements are recorded in
`row8_wload1/RESULTS.md`. Original resolved flags are preserved in `configs.json`.

## Implemented app and configuration

- App: `tests/regression/fpfp_gemm_ffn_hw_naive`.
- FPFP-only config: `configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh`.
- Comparison: rev7 C4 alias
  `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm`,
  mapped by `ci/fpga_bin_alias_map.yaml` to
  `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`.

The FPFP app shares the existing naive descriptor ABI, MMIO driver and FPFP
reference. Its default is FP16 A/B with FP32 products and accumulation, final
FP16 C. It rejects mixed-format modes and a build lacking FPFP capability.
Uppercase and lowercase shape options are supported. The hardware config has
FPFP naive enabled and FPINT/TCU disabled, verified by preprocessing. It uses
rev7 C3 memory/cache settings with a 16x16 FPFP array, WLOAD4 and internal BRAM ACC.

No RTL changes were made for this app task; previously implemented RTL remains
in the worktree. The existing FPINT driver keeps its default format.

## Measurement

VCS runs use separate configured builds, sourced configs, `--perf 3`, and one
verified invocation per shape. K=N=256; M=1,4,256. FPFP uses random seed 1.
FPINT improve uses its existing corrected vectors, QCOL/QBLK32, WTRANS0.
Neither run uses power mode or skips output verification. These compare each
kernel against its own numerical reference, not FPFP output against quantized
FPINT output. Improved C4 reserves padded M storage but computes the requested
real M in these current tests. The reported input transaction counts are 256
for M1 and 1,024 for M4 on both paths, consistent with real M rather than
executing eight padded rows.

GEMM cycles measure the active accelerator invocation, including its memory
work. Core cycles also include the device-side MMIO setup and polling code.
Host packing, upload/download and CPU reference wall time are not these cycle
counters. The simulator's wall-clock duration is not FPGA latency.

| M | FPFP core cycles | C4 core cycles | FPFP GEMM cycles | C4 GEMM cycles | FPFP/C4 GEMM | GEMM difference | Functionality |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 13,158 | 9,535 | 5,262 | 2,233 | 2.356x | +135.65% | Both PASS |
| 4 | 13,533 | 9,760 | 5,626 | 2,446 | 2.300x | +130.01% | Both PASS |
| 256 | 91,233 | 79,660 | 83,317 | 72,375 | 1.151x | +15.12% | Both PASS |

The two paths differ in weight precision and architecture: FPFP carries 2-byte
weights, versus packed 0.5-byte INT4 weights plus quantization metadata. FPFP
uses naive row-major operand DMA, while C4 uses the improve TMEM/layout path.
Therefore the ratio includes those differences and is not an isolated datatype
or area-normalized comparison. No measured performance cause is asserted from
cycle ratios alone.

## Reproduce

In `build_fpfp_gemm_compare` (configured XLEN64):

```bash
source ../configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh
# Restore the geometry/bandwidth used for these historical measurements.
CONFIGS="${CONFIGS/-DFPFP_MXU_ROW=8/-DFPFP_MXU_ROW=16}"
CONFIGS="${CONFIGS/-DMXU_WLOAD_NUM=1/-DMXU_WLOAD_NUM=4}"
CONFIGS="${CONFIGS/-DFPFP_MXU_WLOAD_NUM=1/-DFPFP_MXU_WLOAD_NUM=4}"
ci/run_black.sh xrt-vcs-sim --app fpfp_gemm_ffn_hw_naive --perf 3 \
  --args "-M 4 -K 256 -N 256"
```

In `build_fpint_rev7_compare` (configured XLEN64):

```bash
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --perf 3 \
  --args "-m 4 -k 256 -n 256 -q 32 -d 0 -t 0"
```

Repeat with M=1 and M=256. Actual runs also disable FSDB and use inert
`FPFP_VERIFY_ITERATION=31` to force a clean RTL build. Full configurations are
in `configs.json`; individual JSON reports link the build logs and record
PASS/FAIL, numerical diagnostics, performance counters and elapsed wall time.
Kernel conversion is serialized to avoid the existing `vxbin.py` shared
`/tmp/temp_kernel.bin` race.

## Validation and runtime provenance

FPFP outputs match the FP32 tree/ACC reference bit-for-bit for all three shapes.
M=256 verified all 65,536 outputs with zero mismatches and no NaN/Inf.
Its separate FP64 diagnostic has maximum absolute error 0.0154215; this is
rounding relative to FP64, not a failure against the specified FP32/FP16 path.
The three C4 runs also passed their existing reference checks. CLI validation,
wrong-capability rejection, and ELF/vxbin payload consistency checks passed.

The native FP32 IP M=256 simulation took 6,125 seconds (about 102 minutes).
To preserve the running simulation beyond the original one-hour timeout, only
the timeout controller was paused, with a separate bounded watcher. The actual
run_black.sh child exited 0 after printing PASSED. Resuming the expired controller
then returned 124; that controller-only report is preserved in
`m256_timeout_controller_report.json`. The final case report uses the captured
actual test exit status, documented in `m256_timeout_extension.json`. No test
or simulator was restarted or paused.

Machine-readable comparison: `comparison.csv` and `comparison.json`.
