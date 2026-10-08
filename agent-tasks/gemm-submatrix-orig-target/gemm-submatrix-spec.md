# GEMM original storage and per-job execution extents

Status: confirmed by user instruction on 2026-10-07.

Implement generic C4 packed GEMM submatrix semantics, retaining original parent
matrix dimensions and per-core target extents. No LLM-specific RTL fields.
Original M/N/K define physical tiled A/W/scale/ZP/C storage. Target M/N/K and
existing DMA-tile-aligned M/N starts define the job computation. K starts at zero.
No split-K reduction or arbitrary intra-DMA-tile start support is requested.
K/N execution dimensions obey existing MXU and quantization alignment constraints.

Separate physical tile extents from compute tile extents throughout DRAM/TMEM
addressing, DMA loads, MXU iterations, and C stores. Preserve original packed-C
layout ABI3. Load physical operand tiles, compute only target microtiles, and
preserve all C elements outside the job. Preserve existing orig==target behavior
and existing multicore M/N tile partitioning. No naive changes or shared-runtime
backend muxes; no synthesis/PNR needed.

Affected scope: C4 GEMM FSM, scoped FSM tests, fpint_gemm_ffn_hw test app and generic
submatrix test CLI, plus reproducible blackbox regression cases. RTL unit checks
via tools/verify_rtl.py; blackbox must use configured build/ci/run_black.sh
xrt-vcs-sim, source configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh.

Tests: normal GEMM; original capacity 512/1024 vs target 256/288/320; original tail
320 vs target288; QK WTRANS1 QDIR0 QBLK128, K128 and variable N; PV WTRANS0 QDIR1
QBLK128, N128 and variable K; prefix target sequence with fixed parent buffers;
M tails and output sentinel preservation; nonzero M/N DMA-aligned starts as feasible.
Keep cases small enough for VCS, and report measured cycles and limitations.
