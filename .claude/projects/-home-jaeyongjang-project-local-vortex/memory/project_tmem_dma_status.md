---
name: TMEM/DMA implementation status
description: Current state of the TMEM+DMA data feeding architecture implementation. All RTL done, compile-verified. Blackbox blocked by pre-existing xrt_vcs bug.
type: project
---

TMEM+DMA data feeding architecture is implemented and compile-verified through all hierarchy levels (Phases 1-8). 

**Why:** Increase GEMM data feeding bandwidth via dedicated tensor memory + 8-channel DMA.

**How to apply:** When continuing this work, refer to:
- Spec: `docs/rtl-improve/tmem-dma-spec.md`
- Iteration log: `docs/rtl-improve/tmem-dma-log.md`
- Test plan: `harness/rules/testing-tmem-dma.md`

**Key finding:** `vecadd` xrt_vcs blackbox test fails with X on status register even on the ORIGINAL codebase (pre-TMEM). This is a pre-existing bug unrelated to our changes. Needs separate investigation before Level 2 blackbox tests can run.

**Remaining work:**
1. Fix pre-existing xrt_vcs bug OR use alternative driver (simx/rtlsim)
2. Update fpint_gemm_ffn_hw kernel for new cmd flow
3. Re-enable interleaved LSU demux routing (currently forced to bank 0)
4. Re-connect DMA AXI ports to axi_mux (currently disconnected for diagnostic)
