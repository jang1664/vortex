# FPFP naive 8x16 / WLOAD1 regression

Status: complete. All three VCS cases passed with return code 0.

## Configuration

- Config: `configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh` (existing filename retained).
- FPFP ROW=8, COL=16, WLOAD=1. The generic MXU_WLOAD_NUM is also 1.
- FPFP-only capability; FPINT MXU and TCU disabled. All settings are explicitly listed in the config.
- App: `fpfp_gemm_ffn_hw_naive`; random seed 1; FP16 inputs/weights, FP32 tree/ACC, final FP16 output.
- K=N=256. Separate configured build: `build_fpfp_gemm_8x16_w1`.
- VCS, perf class 3, FSDB disabled, inert iteration stamp 32 to force a fresh RTL build.
- Per-case timeout is 4 hours because the previous 16x16 large case took 102 minutes.

## Measured results

| M | Core cycles | GEMM cycles | Previous FPFP 16x16/WLOAD4 GEMM | Change | Functionality |
|---:|---:|---:|---:|---:|---|
| 1 | 14,433 | 6,547 | 5,262 | +24.42% | PASS, 0/256 mismatches |
| 4 | 14,958 | 7,080 | 5,626 | +25.84% | PASS, 0/1,024 mismatches |
| 256 | 158,808 | 150,873 | 83,317 | +81.08% | PASS, 0/65,536 mismatches |

The previous measurements are historical results in the parent directory.
ROW and WLOAD both changed; this is not an isolated WLOAD sensitivity test.
GEMM cycles include accelerator memory work; core cycles also include device
setup/polling. Host transfer/reference time and VCS wall time are excluded.
All three FPFP cases match the FP32 tree/ACC reference bit-for-bit with
no NaN/Inf outputs. The reference uses the configured FPFP reduction width.

## Reproduce

From the configured `build_fpfp_gemm_8x16_w1` directory:

```bash
source ../configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh
ci/run_black.sh xrt-vcs-sim --app fpfp_gemm_ffn_hw_naive --perf 3 \
  --args "-M 1 -K 256 -N 256"
```

Repeat for M=4 and M=256. Exact config content and flags are saved in
`config_snapshot.sh` and `config.json`. Source hashes are in `source_sha256.json`.

## Comparison with rev7 C4 FPINT improve

C4 values reuse the previous verified VCS measurements in the parent directory;
C4 was not rerun for this FPFP-only config change. The reference config is
`configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`,
mapped from the rev7 C4 alias. FPFP now has an 8x16 array and WLOAD1; C4 has
a 16x16 FPINT improve array and WLOAD4. Precision, array geometry and DMA/memory
architecture differ, so these are full-path comparisons.

| M | FPFP 8x16/WLOAD1 GEMM cycles | Rev7 C4 FPINT GEMM cycles | Difference |
|---:|---:|---:|---:|
| 1 | 6,547 | 2,233 | +193.19% |
| 4 | 7,080 | 2,446 | +189.45% |
| 256 | 150,873 | 72,375 | +108.46% |

## Validation details

All output elements passed with zero bit mismatches, zero maximum absolute/relative
error against the configured FP32 tree/ACC reference, and no NaN/Inf. M=256
checked 65,536 elements; its separate FP64 diagnostic maximum absolute error
was 0.0154215. The kernel.vxbin payload/header match the built ELF, and all
recorded source/config hashes remained unchanged during the runs.

M=256 took 5143.1 seconds (85.7 minutes) of simulator wall time and exited normally within the 4-hour timeout.

Machine-readable results: `comparison.csv` and `comparison.json`. Individual
`*_iter32.json` reports contain log paths, verification lines and raw counters.
