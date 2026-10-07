# GEMM-C packed output with minimum aligned stores

Status: confirmed by user on 2026-10-06.

Implement the approved plan in analysis_workspace/latency_on_hw/docs/gemm_c_to_a_layout_64b_store_plan.md. Baseline M=1,4,256 K=N=256 must finish before source changes. Use C4 spread_v4, TH16/MXU16, run_black.sh xrt-vcs-sim --perf 3 from build/. Pack C like current A; group whole output microtiles until MEM_BLOCK_SIZE alignment or tile tail. M=1 groups two 32-byte microtiles. Preserve DMA input/output scheduling opportunities, actual compute bounds, completion ordering, and unrelated worktree changes. Re-run identical performance cases and small directed layout/tail/repeated-job cases.
