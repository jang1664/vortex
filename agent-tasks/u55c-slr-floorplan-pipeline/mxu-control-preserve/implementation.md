# Macro-conditional local/TX FF separation

The change is confined to `hw/rtl/core/gemm/VX_gemm_compute_core.sv`.

Under `GEMM_SLR_PIPELINE`, `g_local_prealign_blk_idx.data_q` replaces the
local always-ready, depth-one `VX_pipe_buffer` data state. It is 160 bits
for MXU_ROW32/BLOCK_IDX_WIDTH5 and has `DONT_TOUCH` and `SHREG_EXTRACT=NO`,
but no `USER_SLL_REG`. Its data still updates every clock, including invalid
and reset cycles; its separate valid FF synchronously resets to zero and
otherwise captures `compute_fire`. A static assertion rejects future drift
of `BLK_IDX_DLY` away from one.

The existing `g_slr_mxu_input_tx.control_q` also receives `DONT_TOUCH`,
retaining its original `USER_SLL_REG` and `SHREG_EXTRACT=NO` attributes.
Preserving both local and TX state prevents merging in either direction.
The RX assignment remains directly from the existing TX control register.

The TX packed vector is **162 bits**, not 163: 160 block-index bits,
one valid bit and one `gemm_wreg_idx_t` bit. Preserving the small existing
vector avoids changing its field layout, hierarchy and direct RX connection.
This is not whole-module or generic-library preservation.

Non-SLR compilation retains the original `VX_pipe_buffer` instance verbatim.
There is no new pipeline stage or logical storage requirement. Relative to
the old synthesized netlist that shared 160 data FFs, roughly 160 additional
physical FFs are expected to survive. Final utilization and separation must
be checked in the new source synthesis, not inferred from this RTL estimate.

Seven existing/extended Tcl hook regression suites pass with the current
source; logs are in ignored `build_slr_hook_check/mxu-preserve-hooks/`.
Directed VCS, end-to-end GEMM and physical results are recorded separately.
