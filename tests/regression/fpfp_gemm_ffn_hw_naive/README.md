# FP16 x FP16 naive GEMM regression

This app defaults to FP16 A and FP16 B, FP32 products/reduction/accumulation,
and a final FP16 output. A `[M,K]`, B `[K,N]` and C `[M,N]` are row-major.
There is no quantization or transpose. It shares the existing naive MMIO
driver, scratch allocator, random/directed vectors and FPFP reference rather
than maintaining a second implementation. Mixed-format modes are rejected.

From an isolated, configured build directory:

```bash
source ../configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh
ci/run_black.sh xrt-vcs-sim --app fpfp_gemm_ffn_hw_naive --perf 3 \
  --args "-M 4 -K 256 -N 256"
```

Use M=1,4,256 with K=N=256 for the comparison suite. Lowercase shape options
also work. `--seed`, `--tagged`, `--subnormal`, `-r`, and `--lmem-offset` use
the shared driver's behavior. `-p` skips verification for power experiments;
omit it for functionality checks and cycle comparisons.

The config enables only the FPFP naive MXU capability, with ROW=8, COL=16,
WLOAD=1 and internal BRAM ACC. It explicitly lists memory/cache settings matching rev7 C3.
FPFP geometry remains configurable through `FPFP_MXU_ROW/COL/WLOAD_NUM`.
K must be divisible by ROW; N tails are supported. Native port and tile limits
are checked at compile time. Each output is compared bit-for-bit with the
FP32 tree/ACC reference (signed zeros compare equal); NaN-poisoned output
buffers detect missing stores. A separate FP64 reference reports rounding error.

Cycle comparison against rev7 C4 uses `fpint_gemm_ffn_hw` and its mapped
`improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh` config.
That path multiplies FP16 x INT4 with quantization metadata and a different
memory/layout architecture; equal M/K/N does not imply equal operand traffic
or equivalent weight precision. Report both core cycles and GEMM cycles.
