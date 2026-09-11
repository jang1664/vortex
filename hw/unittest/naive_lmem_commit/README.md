# Naive physical commit and DMA fence directed suite

Use `test_type=new_tb`, `sim=vcs`, `tools/verify_rtl.py unittest --path` with an
absolute configured build path. Source the naive th16/MXU16 config first. Repeat
with MXU_ROW/MXU_COL/MXU_COL_TILE/LMEM_NUM_PORTS set to32 for compatibility. The
Makefile uses `/usr/bin/gcc` and `/usr/bin/g++`; no source-tree make invocation.

The test instantiates actual VX_local_mem and its production commit decoder,
and the production VX_naive_dma_write_fence. It checks CPU/ordinary-GEMM writes
are excluded, DMA/final/PSUM-set classifications, partial byte writes and
same-bank readback. A real DMA-origin write feeds actual bank commits into the
fence; modeled worker completion stays blocked between request acceptance and
bank commit, and the dependent read waits for that release.

Separate finite return stimuli test partial wide acceptance with no duplicate
reservation, same-edge reserve/commit, delayed worker completion, done-ready
backpressure, zero mask, exact4095-credit saturation, blocked admission,
reopened credit and complete drain at both lane geometries.

The fixture does not force internal DUT state. Worker completion and the
adversarial bank-return sequence are explicit fixture inputs to the same fence
helper used in VX_dma_node. It is not a complete CPU MMIO/DMA descriptor test or
GEMM-context terminal test. Full integration must separately verify existing
worker S_DONE ownership, mixed descriptor generations, shared-port stalls,
PSUM/final producer closure and improve structural/resource preservation.
