# Independent DMA workload compatibility audit

2026-09-09 read-only inspection. No new workload was executed and no xclbin or
RTL changed. This distinguishes available module definitions from the archived
core's actual connections.

Repository softmax variants `opt`, `opt_align`, `dma_row`, and `dma_serial`
contain a separate software DMA descriptor interface. `kernel.opt_align.cpp`
uses base0x1480,18 registers,8-byte MMIO beats,72-byte entry stride. The explicit
DMA variants include that implementation. The Makefile's default is instead
`rev2_shuffle_grouped`; the `kernel.cpp` symlink alone does not select the build.

Archived `VX_dma_node.sv` also defines an18-register frontend at0x1480, but
that matching definition is not enough. The selected archived `VX_core.sv`
lines142–150 connect every CPU `dma_ctrl_if` to `VX_lsu_mem_zero_rsp`, under
`g_disabled_dma_ctrl`. Lines153–160 tie CPU DMA local/global request interfaces
inactive. `VX_lsu_mem_zero_rsp.sv:19` drives response data to zero. The memory
unit still decodes the0x1480 MMIO window, so address decoding alone is likewise
not proof of an operational DMA engine.

Softmax's `dma_alloc` loop (`kernel.opt_align.cpp:103`) exits only when the
allocation-success bit is1. On this zero-response connection it cannot succeed.
This is a source-grounded incompatibility, not a measured runtime hang. Do not
launch this known-incompatible variant just to obtain a timeout, substitute a
current core with enabled DMA, or label the default non-DMA variant as DMA
coverage. `VX_gemm_dma_ctrl_with_dma` appears as a definition but not an
instantiation in the selected archived source search.

The GEMM node remains separately instantiated and uses its own TMEM DMA path,
which the existing correctness-passing long-K workload demonstrably exercises.
That gives integrated DMA/GEMM evidence, not isolated CPU-programmed DMA
coverage or a direct memory-bandwidth measurement. Native backend stream tests
provide model-contract evidence only.

Coverage disposition for the existing selected image:

- Keep integrated GEMM DMA coverage and explicitly report this disabled
  independent-DMA interface.
- No claim that all repository applications or all possible DMA paths were
  exhaustively classified; this audit identifies the concrete softmax DMA path.
- If independent CPU-programmed DMA hardware measurements are required, choose
  another already-existing xclbin with a proven enabled path and archived
  source provenance. That is a separate candidate/profile decision, not license
  to rebuild RTL or synthesize a new image under the current plan.

All archived paths above are resolved through
`build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-add/rtl-library`.
The artifact's source provenance and actual compiler path audits are recorded
separately; current repository RTL was not used to infer this disabled path.
