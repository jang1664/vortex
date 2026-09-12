# Confirmed scope

Set the naive weight response capacity to eight, matching improve for TH16/MXU16/WLOAD4. The user explicitly authorized this change. Preserve improve's active RTL and latency/cost at RTL level; no synthesis. Keep unrelated parameters unchanged and audit their effective values and semantic equivalence.

Validate ordinary xrt-vcs-sim fpint_gemm_ffn_hw_naive at M4 and M256, K=N512, QCOL, WTRANS0. Use default PSUM16 for the updated default-cycle comparison; the previous default reference is19981/676378 GEMM cycles. No fine reset tests or new unit tests. Report parameter differences separately from the cycle-only fpint_gemm_latency.md document.

Audit command queues, response slots, outstanding requests, transport buffering, pipeline cuts and memory/DMA geometry. Distinguish tunable asymmetries from structural LMEM/TMEM differences. Do not change additional settings without a concrete authorized follow-up.
