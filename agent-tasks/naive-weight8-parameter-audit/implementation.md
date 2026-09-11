# Naive weight capacity implementation

The only RTL change for this task is in `hw/rtl/VX_config.vh`: when `GEMM_NAIVE` is selected, the default `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` now aliases `W_LMEM_DMA_RESPONSE_SLOTS`. At TH16/MXU16/WLOAD4, this increases the production naive weight response capacity from four to eight beats, matching improve's default capacity.

The existing outer `ifndef` preserves explicit `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` overrides. Explicit node parameter overrides also remain supported. A `W_LMEM_DMA_RESPONSE_SLOTS` override now controls the naive default as well. Other backends retain the original `W_LMEM_DMA_CMD_BEATS` definition. No interfaces, pipelines, or ready/valid logic changed.

The production connection is `VX_gemm_node_naive.W_RD_OUTSTANDING` to `VX_naive_weight_executor.RESPONSE_SLOTS`, then its DMA queue's `RD_PREFETCH_DEPTH`. This sizes both weight response ownership and payload capacity. The standalone executor parameter default remains one command; the production node explicitly overrides it with the configured value. Existing uncommitted PSUM capacity hooks are untouched, and their defaults remain 16.

## Static evidence

Verilator was used only as a preprocessor (`-E --dump-defines`), not as a simulator. Under the existing improve TH16/MXU16 configuration, the complete selected `VX_config.vh` output and macro definitions were identical to HEAD before this change, with PERF disabled and enabled. Normalization removed blank and source-location lines only. This proves the edited config contributes no improve macro or selected-RTL change. All other RTL changes already present in the worktree belong to earlier work.

Naive preprocessing probes confirmed the default expands to `2 * (16 / 4)`, an explicit outstanding-slot override remains four, and a response-slot override of 16 becomes 16. Evidence is under ignored `runs/config-identity/`. No synthesis or fine reset tests were performed.

## Verification request

Run ordinary `xrt-vcs-sim` using the configured build and required wrapper for `fpint_gemm_ffn_hw_naive`, TH16/MXU16/WLOAD4, default PSUM16, M4 and M256, K=N512, arguments `-q 32 -t 0 -d 0 -r 1`. Require application PASS and capture GEMM/core cycles. Compare against the previous default naive GEMM cycles 19,981 and 676,378, respectively. Preserve the improve reference through RTL identity and confirm any repeated improve measurement has zero GEMM/core-cycle delta.
